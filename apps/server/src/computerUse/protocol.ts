import * as Schema from "effect/Schema";

const BoundedText = Schema.String.check(Schema.isMaxLength(16_384));
const ScrollDelta = Schema.Number.check(
  Schema.isFinite(),
  Schema.isBetween({ minimum: -2000, maximum: 2000 }),
);
export const ComputerAction = Schema.Union([
  Schema.Struct({ kind: Schema.Literal("press") }),
  Schema.Struct({ kind: Schema.Literal("move") }),
  Schema.Struct({
    kind: Schema.Literal("click"),
    button: Schema.Literals(["left", "right"]),
    count: Schema.Literals([1, 2]),
  }),
  Schema.Struct({ kind: Schema.Literal("scroll"), dx: ScrollDelta, dy: ScrollDelta }),
  Schema.Struct({ kind: Schema.Literal("type"), text: BoundedText, replace: Schema.Boolean }),
  Schema.Struct({
    kind: Schema.Literal("perform"),
    action: Schema.String.check(Schema.isMaxLength(128)),
  }),
]);
export type ComputerAction = typeof ComputerAction.Type;

const Bounds = Schema.Struct({
  x: Schema.Number,
  y: Schema.Number,
  width: Schema.Number,
  height: Schema.Number,
});
export const ComputerElement = Schema.Struct({
  ref: Schema.Int,
  role: Schema.String,
  name: Schema.NullOr(Schema.String),
  value: Schema.NullOr(Schema.String),
  enabled: Schema.Boolean,
  editable: Schema.Boolean,
  actions: Schema.Array(Schema.String),
  bounds: Schema.NullOr(Bounds),
});

const ElementTarget = Schema.Struct({
  ...ComputerElement.fields,
  path: Schema.Array(Schema.Int),
  stableId: Schema.NullOr(Schema.String),
});
export type ElementTarget = typeof ElementTarget.Type;

export const WorkerRequest = Schema.Union([
  Schema.Struct({
    kind: Schema.Literal("snapshot"),
    app: Schema.String,
    includeImage: Schema.Boolean,
  }),
  Schema.Struct({
    kind: Schema.Literal("action"),
    app: Schema.String,
    pid: Schema.Int,
    target: ElementTarget,
    action: ComputerAction,
  }),
]);
export type WorkerRequest = typeof WorkerRequest.Type;

export const NativeSnapshot = Schema.Struct({
  app: Schema.String,
  pid: Schema.Int,
  truncated: Schema.Boolean,
  elements: Schema.Array(ElementTarget),
  image: Schema.optionalKey(
    Schema.Struct({
      data: Schema.String,
      mimeType: Schema.Literal("image/png"),
      width: Schema.Int,
      height: Schema.Int,
    }),
  ),
});
export type NativeSnapshot = typeof NativeSnapshot.Type;

export const FailureStage = Schema.Literals([
  "request",
  "load",
  "app_lookup",
  "element_tree",
  "action",
  "capture",
  "worker_start",
  "worker_exit",
  "worker_response",
]);
export type FailureStage = typeof FailureStage.Type;
export const FailureDetail = Schema.Struct({
  stage: FailureStage,
  reason: Schema.Literals([
    "type_error",
    "invalid_argument",
    "timeout",
    "native_error",
    "unknown",
    "accessibility_permission",
    "screen_recording_permission",
  ]),
});

export const WorkerResponse = Schema.Union([
  Schema.Struct({ ok: Schema.Literal(true), snapshot: Schema.optionalKey(NativeSnapshot) }),
  Schema.Struct({
    ok: Schema.Literal(false),
    code: Schema.Literals([
      "unavailable",
      "permissions",
      "app_not_running",
      "target_changed",
      "unsupported_action",
      "capture_requires_foreground",
      "input_requires_foreground",
      "failed",
    ]),
    detail: Schema.optionalKey(FailureDetail),
  }),
]);
export type WorkerResponse = typeof WorkerResponse.Type;

export class ComputerUseError extends Schema.TaggedError<ComputerUseError>()("ComputerUseError", {
  code: Schema.Literals([
    "disabled",
    "app_denied",
    "capture_denied",
    "snapshot_expired",
    "invalid_ref",
    "invalid_input",
    "unavailable",
    "permissions",
    "app_not_running",
    "target_changed",
    "unsupported_action",
    "capture_requires_foreground",
    "input_requires_foreground",
    "failed",
  ]),
  cause: Schema.optional(Schema.Defect()),
  detail: Schema.optionalKey(FailureDetail),
}) {
  override get message(): string {
    switch (this.code) {
      case "disabled":
        return "Computer use is off. Enable it in Settings > Integrations > Computer use on the environment you want to control.";
      case "app_denied":
        return "This app is not in the environment's computer-use allowlist. Ask the user to add it in Settings > Integrations.";
      case "capture_denied":
        return "Screen capture is off. Ask the user to enable it in Settings > Integrations, or request a text-only snapshot.";
      case "snapshot_expired":
        return "Take a fresh computer_snapshot before acting. Snapshots expire after two minutes and are consumed by an action.";
      case "invalid_ref":
        return "That element was not present in the snapshot. Take a fresh computer_snapshot.";
      case "invalid_input":
        return "Invalid computer snapshot request. Supply an app name and an optional includeImage boolean.";
      case "permissions":
        if (this.detail?.reason === "screen_recording_permission")
          return "The native accessibility library requires macOS Screen & System Audio Recording permission even for text-only snapshots. Ask the user to grant it to the T3 host on that machine. T3's separate screenshot setting remains off unless enabled.";
        if (this.detail?.reason === "accessibility_permission")
          return "macOS has not granted Accessibility permission to the process running the T3 native helper. Ask the user to grant it to the T3 host on that machine.";
        return "The environment needs operating-system Accessibility or Screen Recording permission. Ask the user to grant it on that machine.";
      case "target_changed":
        return "The app or element changed. Take a fresh computer_snapshot before acting.";
      case "app_not_running":
        return "That app is not running on the environment machine. Ask the user to open it, then take a fresh computer_snapshot.";
      case "unsupported_action":
        return "This element does not support that accessibility action. Use an action listed in a fresh snapshot.";
      case "capture_requires_foreground":
        return "Bring the target app to the foreground on the environment machine before capturing it, or use includeImage=false.";
      case "input_requires_foreground":
        return "Bring the target app window to the foreground before acting. Pointer input requires a visible element inside that window; take a fresh snapshot.";
      case "unavailable":
        return "Native computer use is currently supported on macOS environments only.";
      default:
        return `Computer use did not complete${this.detail ? ` (${this.detail.stage}: ${this.detail.reason})` : ""}. An action may already have happened; inspect a fresh snapshot before trying again.`;
    }
  }
}
