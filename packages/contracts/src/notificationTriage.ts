import * as Schema from "effect/Schema";

import { RunId, ThreadId } from "./baseSchemas.ts";

export const CompletionNotificationTriageInput = Schema.Struct({
  threadId: ThreadId,
  runId: RunId,
});
export type CompletionNotificationTriageInput = typeof CompletionNotificationTriageInput.Type;

export const CompletionNotificationTriageResult = Schema.Struct({
  notify: Schema.Boolean,
});
export type CompletionNotificationTriageResult = typeof CompletionNotificationTriageResult.Type;
