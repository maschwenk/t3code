import { AuthOrchestrationReadScope, EnvironmentHttpApi } from "@t3tools/contracts";
import * as Effect from "effect/Effect";
import * as HttpApiBuilder from "effect/http-api/HttpApiBuilder";

import {
  annotateEnvironmentRequest,
  failEnvironmentInternal,
  requireEnvironmentScope,
} from "../auth/http.ts";
import * as DirectPush from "./DirectPush.ts";

// Alerts carry thread titles and status, which any client that can read orchestration already sees.
export const pushHttpApiLayer = HttpApiBuilder.group(
  EnvironmentHttpApi,
  "push",
  Effect.fnUntraced(function* (handlers) {
    const push = yield* DirectPush.DirectPush;
    const guard = Effect.fnUntraced(function* (endpoint: string) {
      yield* annotateEnvironmentRequest(endpoint);
      yield* requireEnvironmentScope(AuthOrchestrationReadScope);
    });
    return handlers
      .handle(
        "registerDevice",
        Effect.fn("environment.push.registerDevice")(function* (args) {
          yield* guard(args.endpoint.name);
          return yield* push
            .registerDevice(args.payload)
            .pipe(Effect.catch((error) => failEnvironmentInternal("internal_error", error)));
        }),
      )
      .handle(
        "unregisterDevice",
        Effect.fn("environment.push.unregisterDevice")(function* (args) {
          yield* guard(args.endpoint.name);
          yield* push
            .unregisterDevice(args.payload.deviceId)
            .pipe(Effect.catch((error) => failEnvironmentInternal("internal_error", error)));
        }),
      );
  }),
);
