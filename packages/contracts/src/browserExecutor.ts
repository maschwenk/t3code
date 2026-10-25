import * as Schema from "effect/Schema";
import { PreviewTabId } from "./preview.ts";
import { PreviewAutomationObservation } from "./previewAutomation.ts";

const TabName = Schema.String.check(Schema.isPattern(/^[a-zA-Z][a-zA-Z0-9_-]{0,39}$/));
export const BrowserExecutorInput = Schema.Struct({
  sessionId: Schema.optional(Schema.String.check(Schema.isMaxLength(128))).annotate({
    description: "Session id returned by a previous execution. Omit to start a new session.",
  }),
  steps: Schema.Array(
    Schema.Struct({
      op: Schema.Literals([
        "open",
        "bind",
        "navigate",
        "click",
        "type",
        "press",
        "scroll",
        "hover",
        "select",
        "dialog",
        "waitFor",
        "close",
      ]),
      tab: TabName,
      input: Schema.optional(Schema.Record(Schema.String, Schema.Unknown)),
    }),
  )
    .check(Schema.isMaxLength(20))
    .annotate({
      description:
        "Up to 20 ordered {op,tab,input} steps. Input uses the matching preview tool fields. Empty steps refresh the current tab.",
    }),
  observeTab: Schema.optional(TabName).annotate({
    description: "Named tab to observe after the steps. Defaults to the last tab used.",
  }),
  baselineId: Schema.optional(Schema.String.check(Schema.isMaxLength(128))).annotate({
    description:
      "Revision of the observation tree you still retain for the final tab. Omit for a full view.",
  }),
  reset: Schema.optional(Schema.Boolean).annotate({
    description:
      "Forget this session with an empty steps array. Tabs stay open; close them with a close step first if desired.",
  }),
});
export type BrowserExecutorInput = typeof BrowserExecutorInput.Type;

export const BrowserExecutorResult = Schema.Struct({
  sessionId: Schema.String,
  tabs: Schema.Array(Schema.Struct({ name: Schema.String, tabId: PreviewTabId })),
  completed: Schema.Int,
  error: Schema.optional(
    Schema.Struct({ step: Schema.Int, code: Schema.String, actionMayHaveRun: Schema.Boolean }),
  ),
  observation: Schema.optional(
    Schema.Struct({ tab: Schema.String, state: PreviewAutomationObservation }),
  ),
  observationError: Schema.optional(Schema.Struct({ tab: Schema.String, code: Schema.String })),
  reset: Schema.optional(Schema.Boolean),
});
export type BrowserExecutorResult = typeof BrowserExecutorResult.Type;
