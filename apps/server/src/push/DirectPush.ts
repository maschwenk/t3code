import type { DirectPushRegistrationResult, ThreadId } from "@t3tools/contracts";
import {
  RelayAgentAwarenessPreferences,
  RelayApnsEnvironment,
  type RelayAgentActivityState,
  type RelayDeviceRegistrationRequest,
} from "@t3tools/contracts/relay";
import * as Context from "effect/Context";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Ref from "effect/Ref";
import * as Schema from "effect/Schema";

import * as ServerSecretStore from "../auth/ServerSecretStore.ts";
import * as Apns from "./apns.ts";

const DIRECT_PUSH_DEVICES_SECRET = "direct-push-devices";
export const DIRECT_PUSH_APNS_CREDENTIALS_SECRET = "direct-push-apns-credentials";

const MAX_DEVICES = 20;
const MAX_ALERT_TEXT_LENGTH = 120;
// Matches the relay: a completion older than this is a replay, not news.
const TERMINAL_ALERT_FRESHNESS_MS = 2 * 60 * 1_000;
// Apple's answers for a token that will never work again.
const PERMANENT_TOKEN_REASONS = new Set([
  "BadDeviceToken",
  "DeviceTokenNotForTopic",
  "Unregistered",
]);

const AppleId = Schema.String.check(
  Schema.makeFilter((value) => /^[A-Z0-9]{10}$/.test(value), {
    expected: "a 10-character Apple identifier",
  }),
);

export const StoredApnsCredentials = Schema.Struct({
  teamId: AppleId,
  keyId: AppleId,
  privateKey: Schema.String,
});
export type StoredApnsCredentials = typeof StoredApnsCredentials.Type;

const StoredDevice = Schema.Struct({
  deviceId: Schema.String,
  label: Schema.String,
  bundleId: Schema.String,
  apsEnvironment: RelayApnsEnvironment,
  pushToken: Schema.String,
  preferences: RelayAgentAwarenessPreferences,
  registeredAt: Schema.String,
});
export type StoredDevice = typeof StoredDevice.Type;

const StoredDevices = Schema.Struct({ devices: Schema.Array(StoredDevice) });

const decodeStoredDevices = Schema.decodeUnknownOption(Schema.fromJsonString(StoredDevices));
const encodeStoredDevices = Schema.encodeSync(Schema.fromJsonString(StoredDevices));
const decodeStoredCredentials = Schema.decodeUnknownOption(
  Schema.fromJsonString(StoredApnsCredentials),
);
export const encodeStoredApnsCredentials = Schema.encodeSync(
  Schema.fromJsonString(StoredApnsCredentials),
);

export const readDirectPushDevices = (secrets: ServerSecretStore.ServerSecretStore["Service"]) =>
  secrets.get(DIRECT_PUSH_DEVICES_SECRET).pipe(
    Effect.map((bytes) =>
      Option.isNone(bytes)
        ? []
        : Option.match(decodeStoredDevices(new TextDecoder().decode(bytes.value)), {
            onNone: () => [],
            onSome: (stored) => stored.devices,
          }),
    ),
  );

export const readApnsCredentials = (secrets: ServerSecretStore.ServerSecretStore["Service"]) =>
  secrets
    .get(DIRECT_PUSH_APNS_CREDENTIALS_SECRET)
    .pipe(
      Effect.map((bytes) =>
        Option.isNone(bytes)
          ? null
          : Option.getOrNull(decodeStoredCredentials(new TextDecoder().decode(bytes.value))),
      ),
    );

type Phase = RelayAgentActivityState["phase"];

function isTerminal(phase: Phase): boolean {
  return phase === "completed" || phase === "failed";
}

function isAttention(phase: Phase): boolean {
  return phase === "waiting_for_approval" || phase === "waiting_for_input";
}

/**
 * Whether a published state is news worth an alert. `previous` is the phase this process last
 * published for the thread, or undefined when it has published none since the thread went quiet.
 */
export function shouldAlertForState(input: {
  readonly previous: Phase | undefined;
  readonly state: RelayAgentActivityState;
  readonly startedAtMs: number;
  readonly nowMs: number;
}): boolean {
  const { phase } = input.state;
  if (!isTerminal(phase) && !isAttention(phase)) return false;
  if (input.previous === phase) return false;
  const updatedAtMs = Option.match(DateTime.make(input.state.updatedAt), {
    onNone: () => Number.NaN,
    onSome: (dateTime) => dateTime.epochMilliseconds,
  });
  if (Number.isNaN(updatedAtMs)) return false;
  if (isTerminal(phase)) return input.nowMs - updatedAtMs <= TERMINAL_ALERT_FRESHNESS_MS;
  // With no baseline, only a request raised after startup is new; older ones replay on restart.
  return input.previous !== undefined || updatedAtMs > input.startedAtMs;
}

function deviceWantsAlert(device: StoredDevice, phase: Phase): boolean {
  const preferences = device.preferences;
  if (!preferences.notificationsEnabled) return false;
  switch (phase) {
    case "waiting_for_approval":
      return preferences.notifyOnApproval;
    case "waiting_for_input":
      return preferences.notifyOnInput;
    case "completed":
      return preferences.notifyOnCompletion;
    case "failed":
      return preferences.notifyOnFailure;
    default:
      return false;
  }
}

function truncate(value: string): string {
  const trimmed = value.trim();
  return trimmed.length <= MAX_ALERT_TEXT_LENGTH
    ? trimmed
    : `${trimmed.slice(0, MAX_ALERT_TEXT_LENGTH - 3).trimEnd()}...`;
}

const STATUS_BY_PHASE: Partial<Record<Phase, string>> = {
  waiting_for_approval: "Approval",
  waiting_for_input: "Input",
  completed: "Done",
  failed: "Failed",
};

function alertForState(state: RelayAgentActivityState): Apns.ApnsAlert {
  return {
    title: truncate(state.threadTitle),
    body: truncate(`${STATUS_BY_PHASE[state.phase] ?? state.headline}: ${state.projectTitle}`),
    environmentId: state.environmentId,
    threadId: state.threadId,
    deepLink: state.deepLink,
  };
}

export class DirectPush extends Context.Service<
  DirectPush,
  {
    readonly registerDevice: (
      request: RelayDeviceRegistrationRequest,
    ) => Effect.Effect<DirectPushRegistrationResult, ServerSecretStore.SecretStoreError>;
    readonly unregisterDevice: (
      deviceId: string,
    ) => Effect.Effect<void, ServerSecretStore.SecretStoreError>;
    readonly hasDevices: Effect.Effect<boolean>;
    /** Alerts registered devices when a confirmed thread state is news. Never fails. */
    readonly publish: (input: {
      readonly threadId: ThreadId;
      readonly state: RelayAgentActivityState | null;
    }) => Effect.Effect<void>;
  }
>()("t3/push/DirectPush") {}

export const make = Effect.gen(function* () {
  const secrets = yield* ServerSecretStore.ServerSecretStore;
  const apns = yield* Apns.ApnsSender;
  const startedAtMs = (yield* DateTime.now).epochMilliseconds;
  const lastPhaseByThread = new Map<ThreadId, Phase>();
  // This process is the only writer, so the stored list is read once and written through.
  const devicesRef = yield* Ref.make<ReadonlyArray<StoredDevice> | null>(null);

  const loadDevices = Effect.gen(function* () {
    const cached = yield* Ref.get(devicesRef);
    if (cached !== null) return cached;
    const stored = yield* readDirectPushDevices(secrets);
    yield* Ref.set(devicesRef, stored);
    return stored;
  });

  const saveDevices = Effect.fnUntraced(function* (devices: ReadonlyArray<StoredDevice>) {
    yield* secrets.set(
      DIRECT_PUSH_DEVICES_SECRET,
      new TextEncoder().encode(encodeStoredDevices({ devices })),
    );
    yield* Ref.set(devicesRef, devices);
  });

  const removeDevices = Effect.fnUntraced(function* (deviceIds: ReadonlySet<string>) {
    if (deviceIds.size === 0) return;
    const devices = yield* loadDevices;
    yield* saveDevices(devices.filter((device) => !deviceIds.has(device.deviceId)));
  });

  const registerDevice: DirectPush["Service"]["registerDevice"] = Effect.fn(
    "DirectPush.registerDevice",
  )(function* (request) {
    const apnsConfigured = (yield* readApnsCredentials(secrets)) !== null;
    const devices = yield* loadDevices;
    // A reinstall keeps the APNs token but makes a new device id; one entry per token avoids double alerts.
    const others = devices.filter(
      (device) => device.deviceId !== request.deviceId && device.pushToken !== request.pushToken,
    );
    const { pushToken, bundleId, apsEnvironment } = request;
    // Android would need FCM; a device without a token or with alerts off only clears its entry.
    if (
      request.platform !== "ios" ||
      !pushToken ||
      !bundleId ||
      !apsEnvironment ||
      !request.preferences.notificationsEnabled
    ) {
      if (others.length !== devices.length) yield* saveDevices(others);
      return { apnsConfigured };
    }
    const registeredAt = DateTime.formatIso(yield* DateTime.now);
    const next = [
      ...others,
      {
        deviceId: request.deviceId,
        label: request.label,
        bundleId,
        apsEnvironment,
        pushToken,
        preferences: request.preferences,
        registeredAt,
      },
    ]
      .toSorted((a, b) => b.registeredAt.localeCompare(a.registeredAt))
      .slice(0, MAX_DEVICES);
    yield* saveDevices(next);
    return { apnsConfigured };
  });

  const sendToDevices = Effect.fnUntraced(function* (state: RelayAgentActivityState) {
    const devices = (yield* loadDevices).filter((device) => deviceWantsAlert(device, state.phase));
    if (devices.length === 0) return;
    const credentials = yield* readApnsCredentials(secrets);
    if (credentials === null) {
      yield* Effect.logWarning("direct push skipped; no APNs key. Run `t3 push key`.", {
        devices: devices.length,
      });
      return;
    }
    const alert = alertForState(state);
    const results = yield* Effect.forEach(
      devices,
      (device) =>
        apns
          .sendAlert(credentials, {
            token: device.pushToken,
            topic: device.bundleId,
            environment: device.apsEnvironment,
            alert,
          })
          .pipe(
            Effect.map((response) => ({ device, response })),
            Effect.catch((error) =>
              Effect.logWarning("direct push send failed", {
                deviceId: device.deviceId,
                error: error.message,
              }).pipe(Effect.as(null)),
            ),
          ),
      { concurrency: 4 },
    );
    const dead = new Set<string>();
    for (const result of results) {
      if (result === null || (result.response.status >= 200 && result.response.status < 300)) {
        continue;
      }
      if (result.response.reason !== null && PERMANENT_TOKEN_REASONS.has(result.response.reason)) {
        dead.add(result.device.deviceId);
      }
      yield* Effect.logWarning("APNs rejected a direct push", {
        deviceId: result.device.deviceId,
        status: result.response.status,
        reason: result.response.reason,
        droppingDevice: dead.has(result.device.deviceId),
      });
    }
    yield* removeDevices(dead);
    yield* Effect.logInfo("direct push sent", {
      threadId: state.threadId,
      phase: state.phase,
      delivered: results.filter(
        (result) =>
          result !== null && result.response.status >= 200 && result.response.status < 300,
      ).length,
      attempted: devices.length,
    });
  });

  return DirectPush.of({
    registerDevice,
    unregisterDevice: Effect.fn("DirectPush.unregisterDevice")(function* (deviceId) {
      yield* removeDevices(new Set([deviceId]));
    }),
    hasDevices: loadDevices.pipe(
      Effect.map((devices) => devices.length > 0),
      Effect.orElseSucceed(() => false),
    ),
    publish: Effect.fn("DirectPush.publish")(
      function* (input) {
        const previous = lastPhaseByThread.get(input.threadId);
        if (input.state === null) {
          lastPhaseByThread.delete(input.threadId);
          return;
        }
        lastPhaseByThread.set(input.threadId, input.state.phase);
        const nowMs = (yield* DateTime.now).epochMilliseconds;
        if (!shouldAlertForState({ previous, state: input.state, startedAtMs, nowMs })) return;
        yield* sendToDevices(input.state);
      },
      Effect.catchCause((cause) => Effect.logWarning("direct push failed", { cause })),
    ),
  });
});

export const layer = Layer.effect(DirectPush, make).pipe(Layer.provide(Apns.layer));
