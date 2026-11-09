import {
  BrowserNavigationTarget,
  OrchestratorMcpFailure,
  BrowserExecutorInput,
  BrowserExecutorResult,
  ToolActivityIcon,
  PreviewAutomationActInput,
  PreviewAutomationDialogInput,
  PreviewAutomationError,
  PreviewAutomationEvaluateInput,
  PreviewAutomationNavigateInput,
  PreviewAutomationOpenInput,
  PreviewAutomationRecordingArtifact,
  PreviewAutomationRecordingStatus,
  PreviewAutomationResizeInput,
  PreviewAutomationResizeResult,
  PreviewAutomationSelectResult,
  PreviewAutomationSetColorSchemeInput,
  PreviewAutomationSetColorSchemeResult,
  PreviewAutomationSnapshot,
  PreviewAutomationObserveInput,
  PreviewAutomationObservation,
  PreviewAutomationStatus,
  PreviewAutomationTabTargetInput,
  PreviewAutomationWaitForInput,
} from "@t3tools/contracts";
import * as Schema from "effect/Schema";
import * as FileSystem from "effect/FileSystem";
import { Tool, Toolkit } from "effect/ai";

import * as McpInvocationContext from "../../McpInvocationContext.ts";
import * as PreviewAutomationBroker from "../../PreviewAutomationBroker.ts";
import * as BrowserExecutor from "../../../preview/BrowserExecutor.ts";
import * as ServerConfig from "../../../config.ts";
import * as ThreadManagementService from "../../../orchestration-v2/ThreadManagementService.ts";

const dependencies = [
  McpInvocationContext.McpInvocationContext,
  ThreadManagementService.ThreadManagementService,
  PreviewAutomationBroker.PreviewAutomationBroker,
];

const PreviewToolFailure = Schema.Union([PreviewAutomationError, OrchestratorMcpFailure]);

const presentationFields = { toolIcon: Schema.optional(ToolActivityIcon) };

const PreviewActionResult = Schema.Struct(presentationFields);

const browserTool = <T extends Tool.Any>(tool: T): T =>
  tool.annotate(Tool.OpenWorld, true).annotate(Tool.Destructive, true) as T;

const safeBrowserTool = <T extends Tool.Any>(tool: T): T =>
  tool.annotate(Tool.OpenWorld, true).annotate(Tool.Destructive, false) as T;

const readonlyBrowserTool = <T extends Tool.Any>(tool: T): T =>
  safeBrowserTool(tool).annotate(Tool.Readonly, true).annotate(Tool.Idempotent, true) as T;

const PreviewStatusTool = Tool.make("preview_status", {
  description:
    "Report preview tab state: owner, pending dialog, URL, title, loading, viewport, and size. `tabs` lists this thread's tabs. `profiles` lists logins for `preview_open`. Read any listed tab. Act only on your tab, or an unclaimed tab with no human in control.",
  parameters: PreviewAutomationTabTargetInput,
  success: PreviewAutomationStatus,
  failure: PreviewToolFailure,
  dependencies,
})
  .annotate(Tool.Title, "Get preview status")
  .annotate(Tool.Readonly, true)
  .annotate(Tool.Destructive, false)
  .annotate(Tool.Idempotent, true);

// `url` already covers websites, so open only adds the dev-server target.
const EnvironmentPortTarget = BrowserNavigationTarget.members[1];

const PreviewOpenTool = browserTool(
  Tool.make("preview_open", {
    description:
      "Open a preview tab in this thread and show it. For a dev server, pass `target` instead of `url`. `open=false` keeps it in the background. Reuses your current tab unless `tabId` or `reuseExistingTab=false` says otherwise. Parallel subagents in one session must each use `reuseExistingTab=false`, then their own returned `tabId`.",
    parameters: PreviewAutomationOpenInput.mapFields(
      (fields) => ({ ...fields, target: Schema.optional(EnvironmentPortTarget) }),
      { unsafePreserveChecks: true },
    ),
    success: PreviewAutomationStatus,
    failure: PreviewToolFailure,
    dependencies,
  })
    .annotate(Tool.Title, "Open browser preview")
    .annotate(Tool.Destructive, false),
);

const PreviewDialogTool = browserTool(
  Tool.make("preview_dialog", {
    description:
      "Accept or dismiss the dialog `preview_status` reports. Pass `promptText` to accept a prompt. Needs your own tab, or an unclaimed one. Desktop hosts may not support this.",
    parameters: PreviewAutomationDialogInput,
    success: PreviewAutomationStatus,
    failure: PreviewToolFailure,
    dependencies,
  }).annotate(Tool.Title, "Resolve browser dialog"),
);

const PreviewNavigateTool = safeBrowserTool(
  Tool.make("preview_navigate", {
    description:
      "Navigate the chosen tab. Pass `url` for a website, or `target:{kind:'environment-port',port}` for a dev server. Exactly one of `url` and `target`.",
    parameters: PreviewAutomationNavigateInput,
    success: PreviewAutomationStatus,
    failure: PreviewToolFailure,
    dependencies,
  }).annotate(Tool.Title, "Navigate browser preview"),
);

const PreviewResizeTool = safeBrowserTool(
  Tool.make("preview_resize", {
    description:
      "Resize the chosen tab: {mode:'fill'}, {mode:'freeform',width,height}, or {mode:'preset',preset,orientation}. Changes CSS size only, not the user agent. A non-fill size stays on the tab and shows the user a responsive toolbar, so resize only when the user asks for a device or breakpoint, not for screenshots or ordinary browsing, and restore {mode:'fill'} when done.",
    parameters: PreviewAutomationResizeInput,
    success: Schema.Struct({ ...PreviewAutomationResizeResult.fields, ...presentationFields }),
    failure: PreviewToolFailure,
    dependencies,
  })
    .annotate(Tool.Title, "Resize browser viewport")
    .annotate(Tool.Idempotent, true),
);

const PreviewSetAppearanceTool = safeBrowserTool(
  Tool.make("preview_set_appearance", {
    description:
      "Set `prefers-color-scheme` for the chosen tab: 'dark', 'light', or 'system' to clear the override.",
    parameters: PreviewAutomationSetColorSchemeInput,
    success: Schema.Struct({
      ...PreviewAutomationSetColorSchemeResult.fields,
      ...presentationFields,
    }),
    failure: PreviewToolFailure,
    dependencies,
  })
    .annotate(Tool.Title, "Set preview appearance")
    .annotate(Tool.Idempotent, true),
);

const PreviewObserveTool = readonlyBrowserTool(
  Tool.make("preview_observe", {
    description:
      "Read a compact, text-only page view. Starts with a full tree; pass baselineId=revision only while you retain that tree to receive a zero-based line splice patch. Apply patch by deleting deleteCount lines at startLine and inserting lines. Every response has a fresh refPrefix: use locator=aria-ref=<refPrefix><ref> for refs in the reconstructed tree. Old locators expire. Omit baselineId after compaction or uncertainty. Navigation, takeover or an expired baseline returns a full view. Waits up to 750ms for 100ms of main-document DOM quiet; budget_exhausted means still changing, and dom_quiet is not proof the task finished. Use preview_wait_for for a specific outcome. Use preview_snapshot for screenshots or diagnostics.",
    parameters: PreviewAutomationObserveInput,
    success: PreviewAutomationObservation,
    failure: PreviewToolFailure,
    dependencies,
  }).annotate(Tool.Title, "Observe browser changes"),
);

const PreviewExecuteTool = browserTool(
  Tool.make("preview_execute", {
    description:
      "Run up to 20 browser steps with persistent named tabs, stopping at the first failure and returning one final compact observation. Omit sessionId to create a session; reuse the returned id later. Each step is {op,tab,input}; input uses the matching tool's fields, except tabId: open creates a new named tab; bind uses {tabId} to attach an existing tab; close takes {}. navigate, dialog and waitFor take the fields of preview_navigate, preview_dialog and preview_wait_for; click, type, press, scroll, hover and select take preview_act's fields for that action, without action. Example steps: [{op:'open',tab:'app',input:{url:'https://example.com'}},{op:'type',tab:'app',input:{locator:'#name',text:'Ada'}}]. Known locators only; inspect before planning actions that depend on new page content. Final observation targets observeTab or the last tab used. Pass baselineId only if you retain that tab's previous tree; otherwise it returns a full view. Error reports completed count and whether the failed action may have run: inspect before continuing and never replay a batch blindly. Empty steps refresh the view. reset=true with sessionId and empty steps forgets the session but leaves tabs open. Sessions expire after 30 minutes idle. Each run has a 60-second execution budget. Use individual tools for screenshots, diagnostics, evaluate, uploads or recording.",
    parameters: BrowserExecutorInput,
    success: BrowserExecutorResult,
    failure: PreviewToolFailure,
    dependencies: [
      McpInvocationContext.McpInvocationContext,
      ThreadManagementService.ThreadManagementService,
      BrowserExecutor.BrowserExecutor,
    ],
  }).annotate(Tool.Title, "Execute browser steps"),
);

// Not read-only: save=true writes the screenshot to disk.
export const PreviewSnapshotTool = safeBrowserTool(
  Tool.make("preview_snapshot", {
    description:
      "Use it only when the current request asks for browser work, including checking an edit in the browser. Never use it unasked to verify your own edit, or to repeat a snapshot from an earlier turn. Works on a tab the user is driving. Returns page state, elements, and diagnostics; it captures a screenshot only with `includeImage=true` or `save=true`. Target one element with `locator='aria-ref=<ref>'` from `accessibilityTree`, even in frames. Refs die on navigation, a new snapshot, or handoff. Text caps near 20 KB; on your own or an unclaimed tab, `preview_evaluate` reads more. To show a screenshot when asked: `save=true`, then embed ![alt](screenshotPath).",
    parameters: Schema.Struct({
      ...PreviewAutomationTabTargetInput.fields,
      includeImage: Schema.optional(
        Schema.Boolean.annotate({
          description: "Default false. True only to see the page.",
        }),
      ),
      save: Schema.optional(
        Schema.Boolean.annotate({
          description: "Write PNG, return `screenshotPath`.",
        }),
      ),
    }),
    success: PreviewAutomationSnapshot,
    failure: PreviewToolFailure,
    dependencies,
  }).annotate(Tool.Title, "Inspect browser page"),
);

const PreviewActTool = browserTool(
  Tool.make("preview_act", {
    description:
      "Act on the chosen tab. Target with `locator='aria-ref=<ref>'` from `preview_snapshot`; `x` and `y` go together. `timeoutMs` defaults to 15000. click: `button`, `clickCount` 1 to 3. type: literal `text`, `clear=true` replaces it. hover: shows menus or tooltips. select: `values` in one native <select>, by value or label; for a custom dropdown, click it open, then click the option. drag: `source` onto `target`. upload: absolute `paths` answer the file picker `preview_status` reports, [] cancels it, or a `locator` sets an <input type=file>. press: one `key`, such as 'Enter', with `modifiers`, to the focused element; click a field first to focus it. scroll: the tab, or one container with a locator; positive `deltaY` scrolls down, positive `deltaX` right.",
    parameters: PreviewAutomationActInput,
    success: Schema.Union([
      Schema.Struct({ ...PreviewAutomationSelectResult.fields, ...presentationFields }),
      PreviewActionResult,
    ]),
    failure: PreviewToolFailure,
    dependencies,
  }).annotate(Tool.Title, "Act in preview page"),
);

/** Wrap non-objects: MCP requires object structuredContent, and Claude Code rejects invalid results entirely. */
export const PreviewEvaluateResult = Schema.Struct({
  ...presentationFields,
  value: Schema.Unknown.annotate({
    description: "The JSON-serializable value the expression produced, or null.",
  }),
});

const PreviewEvaluateTool = browserTool(
  Tool.make("preview_evaluate", {
    description:
      "Run JavaScript in the page. It can change page state. Returns `{value}`, up to 64 KB. Needs your tab, or an unclaimed one. To read a tab the user drives, use `preview_snapshot`. Page tools reached here: read data only, never create, save, or display. Show results with `html_render`.",
    parameters: PreviewAutomationEvaluateInput,
    success: PreviewEvaluateResult,
    failure: PreviewToolFailure,
    dependencies,
  }).annotate(Tool.Title, "Evaluate JavaScript in preview"),
);

const PreviewWaitForTool = readonlyBrowserTool(
  Tool.make("preview_wait_for", {
    description:
      "Wait until all given locator, selector, text, and URL conditions match in the chosen tab.",
    parameters: PreviewAutomationWaitForInput,
    success: PreviewActionResult,
    failure: PreviewToolFailure,
    dependencies,
  }).annotate(Tool.Title, "Wait for preview page condition"),
);

const PreviewRecordingStartTool = safeBrowserTool(
  Tool.make("preview_recording_start", {
    description: "Start recording the chosen tab.",
    parameters: PreviewAutomationTabTargetInput,
    success: Schema.Struct({ ...PreviewAutomationRecordingStatus.fields, ...presentationFields }),
    failure: PreviewToolFailure,
    dependencies,
  }).annotate(Tool.Title, "Start browser recording"),
);

const PreviewRecordingStopTool = safeBrowserTool(
  Tool.make("preview_recording_stop", {
    description:
      "Stop recording the chosen tab. Returns a local path to the recording file (max 50 MiB).",
    parameters: PreviewAutomationTabTargetInput,
    success: Schema.Struct({ ...PreviewAutomationRecordingArtifact.fields, ...presentationFields }),
    failure: PreviewToolFailure,
    dependencies: [...dependencies, FileSystem.FileSystem, ServerConfig.ServerConfig],
  }).annotate(Tool.Title, "Stop browser recording"),
);

export const PreviewToolkit = Toolkit.make(
  PreviewDialogTool,
  PreviewStatusTool,
  PreviewObserveTool,
  PreviewExecuteTool,
  PreviewOpenTool,
  PreviewNavigateTool,
  PreviewResizeTool,
  PreviewSetAppearanceTool,
  PreviewSnapshotTool,
  PreviewActTool,
  PreviewEvaluateTool,
  PreviewWaitForTool,
  PreviewRecordingStartTool,
  PreviewRecordingStopTool,
);

export const PreviewStandardToolkit = Toolkit.make(
  PreviewDialogTool,
  PreviewStatusTool,
  PreviewObserveTool,
  PreviewExecuteTool,
  PreviewOpenTool,
  PreviewNavigateTool,
  PreviewResizeTool,
  PreviewSetAppearanceTool,
  PreviewActTool,
  PreviewEvaluateTool,
  PreviewWaitForTool,
  PreviewRecordingStartTool,
  PreviewRecordingStopTool,
);

export const PreviewSnapshotToolkit = Toolkit.make(PreviewSnapshotTool);
