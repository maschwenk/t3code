import type { RelayDeviceRegistrationRequest } from "@t3tools/contracts/relay";
import * as Effect from "effect/Effect";

import * as RemoteEnvironmentAuthorization from "./authorization/service.ts";
import type { PreparedConnection } from "./connection/model.ts";
import * as ManagedRelay from "./relay/managedRelay.ts";
import { executeAuthenticatedEnvironmentHttpRequest } from "./state/environmentHttpAuth.ts";

/** Registers this device for alerts the environment sends itself with its own APNs key. */
export const registerDirectPushDevice = Effect.fn("clientRuntime.directPush.registerDevice")(
  function* (prepared: PreparedConnection, payload: RelayDeviceRegistrationRequest) {
    return yield* executeAuthenticatedEnvironmentHttpRequest({
      group: "push",
      prepared,
      signer: yield* Effect.serviceOption(ManagedRelay.ManagedRelayDpopSigner),
      remoteAuthorization: yield* Effect.serviceOption(
        RemoteEnvironmentAuthorization.RemoteEnvironmentAuthorization,
      ),
      method: "POST",
      url: (urls) => urls.registerDevice(),
      timeoutMs: 15_000,
      // The push token never follows a redirect to another host.
      requestInit: { redirect: "error" },
      request: ({ client, headers }) => client.registerDevice({ headers, payload }),
    });
  },
);
