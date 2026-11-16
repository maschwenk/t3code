import { assert, describe, it } from "@effect/vitest";
import { EnvironmentId, ThreadId } from "@t3tools/contracts";
import type {
  RelayAgentActivityState,
  RelayDeviceRegistrationRequest,
} from "@t3tools/contracts/relay";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";

import * as ServerSecretStore from "../auth/ServerSecretStore.ts";
import * as Apns from "./apns.ts";
import * as DirectPush from "./DirectPush.ts";

const STARTED_AT_MS = Date.parse("2026-11-16T12:00:00.000Z");
const THREAD_ID = ThreadId.make("thread-1");

function activity(
  phase: RelayAgentActivityState["phase"],
  updatedAt = "2026-11-16T12:01:00.000Z",
  threadId = THREAD_ID,
): RelayAgentActivityState {
  return {
    environmentId: EnvironmentId.make("env-1"),
    threadId,
    projectTitle: "t3code",
    threadTitle: "Fix the flaky test",
    phase,
    headline: "Agent update",
    modelTitle: "claude-opus-5-5",
    updatedAt,
    deepLink: `/threads/env-1/${threadId}`,
  };
}

const alerts = (
  previous: RelayAgentActivityState["phase"] | undefined,
  state: RelayAgentActivityState,
  nowMs = Date.parse("2026-11-16T12:01:30.000Z"),
) => DirectPush.shouldAlertForState({ previous, state, startedAtMs: STARTED_AT_MS, nowMs });

describe("shouldAlertForState", () => {
  it("alerts when a thread starts waiting on the user, and not again while it keeps waiting", () => {
    assert.isTrue(alerts("running", activity("waiting_for_approval")));
    assert.isTrue(alerts("waiting_for_approval", activity("waiting_for_input")));
    assert.isFalse(alerts("waiting_for_approval", activity("waiting_for_approval")));
  });

  it("does not replay a request raised before this server started", () => {
    assert.isFalse(alerts(undefined, activity("waiting_for_approval", "2026-11-16T11:59:00.000Z")));
    assert.isTrue(alerts(undefined, activity("waiting_for_approval", "2026-11-16T12:00:30.000Z")));
  });

  it("alerts a fresh completion or failure but not one older than two minutes", () => {
    assert.isTrue(alerts("running", activity("completed")));
    assert.isTrue(alerts("running", activity("failed")));
    assert.isFalse(
      alerts("running", activity("completed"), Date.parse("2026-11-16T12:04:00.000Z")),
    );
  });

  it("never alerts for work that is still running", () => {
    assert.isFalse(alerts(undefined, activity("starting")));
    assert.isFalse(alerts("starting", activity("running")));
    assert.isFalse(alerts("running", activity("stale")));
  });
});

const phone = (
  overrides: Partial<RelayDeviceRegistrationRequest> = {},
): RelayDeviceRegistrationRequest => ({
  deviceId: "phone-1",
  label: "iPhone",
  platform: "ios",
  iosMajorVersion: 26,
  bundleId: "com.example.t3fork",
  apsEnvironment: "production",
  pushToken: "token-1",
  preferences: {
    liveActivitiesEnabled: false,
    notificationsEnabled: true,
    notifyOnApproval: true,
    notifyOnInput: true,
    notifyOnCompletion: true,
    notifyOnFailure: true,
  },
  ...overrides,
});

const makeDirectPush = Effect.fnUntraced(function* (
  respond: (request: Apns.ApnsAlertRequest) => Apns.ApnsResponse = () => ({
    status: 200,
    reason: null,
  }),
) {
  const values = new Map<string, Uint8Array>([
    [
      DirectPush.DIRECT_PUSH_APNS_CREDENTIALS_SECRET,
      new TextEncoder().encode(
        DirectPush.encodeStoredApnsCredentials({
          teamId: "ABCDE12345",
          keyId: "KEY1234567",
          privateKey: "unused by the recording sender",
        }),
      ),
    ],
  ]);
  const secrets = ServerSecretStore.ServerSecretStore.of({
    get: (name) => Effect.sync(() => Option.fromUndefinedOr(values.get(name))),
    create: (name, value) => Effect.sync(() => void values.set(name, value)),
    set: (name, value) => Effect.sync(() => void values.set(name, value)),
    remove: (name) => Effect.sync(() => void values.delete(name)),
    getOrCreateRandom: () => Effect.die("unused"),
  });
  const requests: Array<Apns.ApnsAlertRequest> = [];
  const push = yield* DirectPush.make.pipe(
    Effect.provideService(ServerSecretStore.ServerSecretStore, secrets),
    Effect.provideService(
      Apns.ApnsSender,
      Apns.ApnsSender.of({
        sendAlert: (_credentials, request) =>
          Effect.sync(() => {
            requests.push(request);
            return respond(request);
          }),
      }),
    ),
  );
  return { push, secrets, requests };
});

describe("DirectPush", () => {
  it.effect(
    "drops a phone Apple reports as unregistered and keeps one that hit a server error",
    () =>
      Effect.gen(function* () {
        const { push, secrets, requests } = yield* makeDirectPush((request) =>
          request.token === "gone"
            ? { status: 410, reason: "Unregistered" }
            : { status: 500, reason: "InternalServerError" },
        );
        yield* push.registerDevice(phone({ deviceId: "old-phone", pushToken: "gone" }));
        yield* push.registerDevice(phone({ deviceId: "phone-1", pushToken: "flaky" }));

        yield* push.publish({ threadId: THREAD_ID, state: activity("waiting_for_approval") });

        assert.equal(requests.length, 2);
        const stored = yield* DirectPush.readDirectPushDevices(secrets);
        assert.deepStrictEqual(
          stored.map((device) => device.deviceId),
          ["phone-1"],
        );
      }),
  );

  it.effect("keeps one entry per push token when the app is reinstalled", () =>
    Effect.gen(function* () {
      const { push, requests } = yield* makeDirectPush();
      yield* push.registerDevice(phone({ deviceId: "before-reinstall" }));
      yield* push.registerDevice(phone({ deviceId: "after-reinstall" }));

      yield* push.publish({ threadId: THREAD_ID, state: activity("waiting_for_input") });

      assert.equal(requests.length, 1);
    }),
  );

  it.effect("skips phases the phone turned off and forgets a phone that turns alerts off", () =>
    Effect.gen(function* () {
      const { push, secrets, requests } = yield* makeDirectPush();
      const preferences = { ...phone().preferences, notifyOnCompletion: false };
      yield* push.registerDevice(phone({ preferences }));

      yield* push.publish({ threadId: THREAD_ID, state: activity("completed") });
      assert.equal(requests.length, 0);
      const otherThread = ThreadId.make("thread-2");
      yield* push.publish({
        threadId: otherThread,
        state: activity("waiting_for_approval", undefined, otherThread),
      });
      assert.deepStrictEqual(
        requests.map((request) => request.alert.body),
        ["Approval: t3code"],
      );

      yield* push.registerDevice(
        phone({ preferences: { ...preferences, notificationsEnabled: false } }),
      );
      assert.isFalse(yield* push.hasDevices);
      assert.deepStrictEqual(yield* DirectPush.readDirectPushDevices(secrets), []);
    }),
  );
});
