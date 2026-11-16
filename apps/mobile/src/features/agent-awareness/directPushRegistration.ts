import type { PreparedConnection } from "@t3tools/client-runtime/connection";
import { registerDirectPushDevice } from "@t3tools/client-runtime/direct-push";
import { AuthOrchestrationReadScope, type EnvironmentId } from "@t3tools/contracts";
import type { RelayDeviceRegistrationRequest } from "@t3tools/contracts/relay";
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Option from "effect/Option";
import { FetchHttpClient, type HttpClient } from "effect/http";
import { Atom, AtomRegistry } from "effect/reactivity";
import * as Application from "expo-application";
import Constants from "expo-constants";
import * as Notifications from "expo-notifications";
import { fetch as expoFetch } from "expo/fetch";
import { AppState, Platform } from "react-native";

import { connectionAtomRuntime } from "../../connection/runtime";
import { loadOrCreateAgentAwarenessDeviceId, loadPreferences } from "../../persistence/imperative";
import { appAtomRegistry } from "../../state/atom-registry";
import { connectedEnvironmentIdsAtom, environmentPresentations } from "../../state/presentation";
import { environmentSession, sessionHasScope } from "../../state/session";
import { makeRelayDeviceRegistrationRequest, resolveApsEnvironment } from "./registrationPayload";

/**
 * A build signed by your own Apple team sits outside T3's APNs topic, so T3 Connect's relay
 * cannot alert it. Each connected computer sends its alerts itself with your APNs key instead.
 */
export function isDirectPushBuild(): boolean {
  return Platform.OS === "ios" && Constants.expoConfig?.extra?.directPush === true;
}

export type DirectPushComputerStatus =
  | "registering"
  | "sending"
  | "ready"
  | "needs-key"
  | "unsupported"
  | "failed";

export interface DirectPushComputer {
  readonly label: string;
  readonly status: DirectPushComputerStatus;
}

const directPushConnectionsAtom = Atom.make((get) => {
  const connections = new Map<EnvironmentId, PreparedConnection>();
  for (const environmentId of get(connectedEnvironmentIdsAtom)) {
    if (
      !sessionHasScope(
        get(environmentSession.sessionStateAtom(environmentId)),
        AuthOrchestrationReadScope,
      )
    ) {
      continue;
    }
    const prepared = Option.getOrNull(
      get(environmentSession.preparedConnectionValueAtom(environmentId)),
    );
    if (prepared !== null) connections.set(environmentId, prepared);
  }
  return connections;
});

let computers: ReadonlyMap<EnvironmentId, DirectPushComputer> = new Map();
const computerListeners = new Set<() => void>();

export function getDirectPushComputers(): ReadonlyMap<EnvironmentId, DirectPushComputer> {
  return computers;
}

export function subscribeDirectPushComputers(listener: () => void): () => void {
  computerListeners.add(listener);
  return () => {
    computerListeners.delete(listener);
  };
}

function setComputer(environmentId: EnvironmentId, computer: DirectPushComputer): void {
  computers = new Map(computers).set(environmentId, computer);
  for (const listener of computerListeners) listener();
}

function environmentLabel(environmentId: EnvironmentId): string {
  return (
    appAtomRegistry.get(environmentPresentations.presentationAtom(environmentId))?.entry.target
      .label ?? "Computer"
  );
}

function iosMajorVersion(): number {
  const version = Platform.Version;
  if (typeof version === "number") return Math.floor(version);
  const major = Number.parseInt(version.split(".")[0] ?? "", 10);
  return Number.isFinite(major) ? major : 18;
}

async function readPushToken(): Promise<string | undefined> {
  const permissions = await Notifications.getPermissionsAsync();
  if (!permissions.granted) return undefined;
  const token = await Notifications.getDevicePushTokenAsync().catch(() => null);
  return token?.type === "ios" && typeof token.data === "string" && token.data.trim().length > 0
    ? token.data.trim()
    : undefined;
}

// A Release build installed straight to a device is development-signed, so its token is a sandbox
// token even though the variant says production. The embedded profile is the source of truth.
async function readApsEnvironment(): Promise<"sandbox" | "production"> {
  const fromProfile = await Application.getIosPushNotificationServiceEnvironmentAsync().catch(
    () => null,
  );
  if (fromProfile === "development") return "sandbox";
  if (fromProfile === "production") return "production";
  return resolveApsEnvironment(Constants.expoConfig?.extra?.appVariant);
}

async function makeRegistration(): Promise<RelayDeviceRegistrationRequest> {
  const [deviceId, preferences, pushToken, apsEnvironment] = await Promise.all([
    loadOrCreateAgentAwarenessDeviceId(),
    loadPreferences(),
    readPushToken(),
    readApsEnvironment(),
  ]);
  const bundleId = Constants.expoConfig?.ios?.bundleIdentifier?.trim();
  return makeRelayDeviceRegistrationRequest({
    deviceId,
    label: Constants.deviceName?.trim() || "iOS device",
    platform: "ios",
    iosMajorVersion: iosMajorVersion(),
    appVersion: Constants.expoConfig?.version,
    ...(bundleId ? { bundleId } : {}),
    apsEnvironment,
    ...(pushToken ? { pushToken } : {}),
    notificationsEnabled: pushToken !== undefined,
    preferences,
  });
}

// Expo's native fetch honors redirect: "error"; React Native's XMLHttpRequest fetch follows redirects.
function runEnvironmentRequest<A, E>(effect: Effect.Effect<A, E, HttpClient.HttpClient>) {
  return Effect.runPromiseExit(
    AtomRegistry.getResult(appAtomRegistry, connectionAtomRuntime).pipe(
      Effect.flatMap((context) =>
        effect.pipe(
          Effect.provideService(FetchHttpClient.Fetch, async (url, options) =>
            expoFetch(url, { ...options, redirect: "error" }),
          ),
          Effect.provide(context),
        ),
      ),
    ),
  );
}

function statusForFailure(cause: Cause.Cause<unknown>): DirectPushComputerStatus {
  const error = Cause.squash(cause);
  // A computer without direct push (an older or non-fork T3 Code) has no such route.
  return typeof error === "object" &&
    error !== null &&
    "_tag" in error &&
    error._tag === "RemoteEnvironmentAuthUndeclaredStatusError" &&
    "status" in error &&
    error.status === 404
    ? "unsupported"
    : "failed";
}

// Signature of the registration each computer last accepted, so unchanged state is not re-sent.
const acceptedRegistrations = new Map<EnvironmentId, string>();
let activeSync: Promise<void> | null = null;
let syncRequested = false;

async function syncOnce(): Promise<void> {
  const connections = appAtomRegistry.get(directPushConnectionsAtom);
  if (connections.size === 0) return;
  const registration = await makeRegistration();
  const signature = JSON.stringify(registration);
  await Promise.all(
    [...connections].map(async ([environmentId, prepared]) => {
      if (acceptedRegistrations.get(environmentId) === signature) return;
      const label = environmentLabel(environmentId);
      if (!computers.has(environmentId))
        setComputer(environmentId, { label, status: "registering" });
      const exit = await runEnvironmentRequest(registerDirectPushDevice(prepared, registration));
      if (Exit.isSuccess(exit)) {
        acceptedRegistrations.set(environmentId, signature);
        setComputer(environmentId, {
          label,
          status: !exit.value.apnsConfigured
            ? "needs-key"
            : registration.preferences.notificationsEnabled
              ? "sending"
              : "ready",
        });
        return;
      }
      setComputer(environmentId, { label, status: statusForFailure(exit.cause) });
    }),
  );
}

/** Registers this phone with every connected computer whose copy is stale. Calls coalesce. */
export function syncDirectPushRegistrations(options?: { readonly force?: boolean }): Promise<void> {
  if (options?.force) acceptedRegistrations.clear();
  if (activeSync !== null) {
    syncRequested = true;
    return activeSync;
  }
  activeSync = (async () => {
    do {
      syncRequested = false;
      await syncOnce().catch((error: unknown) => {
        if (__DEV__) console.warn("[direct-push] registration failed", error);
      });
    } while (syncRequested);
  })().finally(() => {
    activeSync = null;
  });
  return activeSync;
}

/** App-lifetime registration for direct push builds; a no-op in builds T3's relay can reach. */
export function installDirectPushRegistration(): () => void {
  if (!isDirectPushBuild()) return () => {};
  const unsubscribe = appAtomRegistry.subscribe(
    directPushConnectionsAtom,
    () => void syncDirectPushRegistrations(),
    { immediate: true },
  );
  const tokenSubscription = Notifications.addPushTokenListener(
    () => void syncDirectPushRegistrations({ force: true }),
  );
  // Re-register on return: a computer may have gained a key or dropped this phone meanwhile.
  const appStateSubscription = AppState.addEventListener("change", (state) => {
    if (state === "active") void syncDirectPushRegistrations({ force: true });
  });
  return () => {
    unsubscribe();
    tokenSubscription.remove();
    appStateSubscription.remove();
  };
}
