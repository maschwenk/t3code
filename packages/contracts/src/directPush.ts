import * as Schema from "effect/Schema";

import { TrimmedNonEmptyString } from "./baseSchemas.ts";

/**
 * Direct push lets an environment send APNs alerts itself, with an APNs key from the
 * operator's own Apple team, to apps signed by that team. T3 Connect's relay can only
 * reach T3's own bundle, so builds signed by another team register here instead.
 */
export const DirectPushRegistrationResult = Schema.Struct({
  // False until `t3 push key` stores an APNs key on this environment.
  apnsConfigured: Schema.Boolean,
});
export type DirectPushRegistrationResult = typeof DirectPushRegistrationResult.Type;

export const DirectPushDeviceUnregisterRequest = Schema.Struct({
  deviceId: TrimmedNonEmptyString,
});
export type DirectPushDeviceUnregisterRequest = typeof DirectPushDeviceUnregisterRequest.Type;
