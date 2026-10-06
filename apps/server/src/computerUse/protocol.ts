import * as Schema from "effect/Schema";

const BoundedText = Schema.String.check(Schema.isMaxLength(16_384));
const ScrollDelta = Schema.Number.check(
  Schema.isFinite(),
  Schema.isBetween({ minimum: -2000, maximum: 2000 }),
);
const PixelCoordinate = Schema.Number.check(
  Schema.isFinite(),
  Schema.isBetween({ minimum: 0, maximum: 100_000 }),
);
/** A pixel in the latest window capture of the app (includeImage=true). */
const ImagePoint = Schema.Struct({ x: PixelCoordinate, y: PixelCoordinate });
/** An element of the same snapshot, by ref or exact name (plus role when names repeat). */
const ElementRef = Schema.Union([
  Schema.Struct({ ref: Schema.Int }),
  Schema.Struct({
    name: Schema.String.check(Schema.isMaxLength(500)),
    role: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(64))),
  }),
]);
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
  // A key or shortcut such as "Return", "Escape", "Down" or "cmd+shift+t".
  Schema.Struct({
    kind: Schema.Literal("key"),
    key: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(64)),
    repeat: Schema.optionalKey(Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 50 }))),
  }),
  // A menu bar command by titles, such as ["File", "New Window"].
  Schema.Struct({
    kind: Schema.Literal("menu"),
    path: Schema.Array(Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(200))).check(
      Schema.isMinLength(1),
      Schema.isMaxLength(6),
    ),
  }),
  Schema.Struct({
    kind: Schema.Literal("wait"),
    ms: Schema.Int.check(Schema.isBetween({ minimum: 0, maximum: 5000 })),
  }),
  // Pointer input at a pixel of the latest window capture, for content
  // without usable accessibility controls (canvases, games, custom views).
  Schema.Struct({
    kind: Schema.Literal("click_at"),
    ...ImagePoint.fields,
    button: Schema.Literals(["left", "right"]),
    count: Schema.Literals([1, 2]),
  }),
  Schema.Struct({ kind: Schema.Literal("move_at"), ...ImagePoint.fields }),
  // Drags from the step's element, or from a capture pixel, to an element or a capture pixel.
  Schema.Struct({
    kind: Schema.Literal("drag"),
    from: Schema.optionalKey(ImagePoint),
    to: Schema.Union([ImagePoint, ElementRef]),
  }),
]);
/** Actions that need no element target. A key may optionally focus one first. Drag needs one
 * unless it starts from a capture pixel. */
export const ELEMENTLESS_ACTIONS: ReadonlySet<ComputerAction["kind"]> = new Set([
  "key",
  "menu",
  "wait",
  "click_at",
  "move_at",
]);
/** Actions positioned by capture pixels, which never take an element target. */
export const COORDINATE_ACTIONS: ReadonlySet<ComputerAction["kind"]> = new Set([
  "click_at",
  "move_at",
]);
export type ComputerAction = typeof ComputerAction.Type;

const Bounds = Schema.Struct({
  x: Schema.Number,
  y: Schema.Number,
  width: Schema.Number,
  height: Schema.Number,
});
/** The window an image shows, in the screen's logical points. */
export const CaptureWindow = Schema.Struct({ id: Schema.Int, bounds: Bounds });
export type CaptureWindow = typeof CaptureWindow.Type;
const ScreenPoint = Schema.Struct({ x: Schema.Number, y: Schema.Number });
export type ScreenPoint = typeof ScreenPoint.Type;
export const ComputerElement = Schema.Struct({
  ref: Schema.Int,
  role: Schema.String,
  name: Schema.NullOr(Schema.String),
  value: Schema.NullOr(Schema.String),
  enabled: Schema.Boolean,
  editable: Schema.Boolean,
  actions: Schema.Array(Schema.String),
  bounds: Schema.NullOr(Bounds),
  description: Schema.NullOr(Schema.String),
  /** Notable states: focused, selected, checked, mixed, expanded, collapsed, offscreen. */
  states: Schema.Array(Schema.String),
  /** Nesting among returned elements; anonymous containers are not counted. */
  depth: Schema.Int,
  /** Names of the nearest named ancestors, outermost first, for query results. */
  context: Schema.optionalKey(Schema.Array(Schema.String)),
});

const ElementTarget = Schema.Struct({
  ...ComputerElement.fields,
  path: Schema.Array(Schema.Int),
  stableId: Schema.NullOr(Schema.String),
});
export type ElementTarget = typeof ElementTarget.Type;

export const SnapshotOptions = Schema.Struct({
  /** Case-insensitive words that must all appear in an element's name, value or description. */
  query: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(200))),
  roles: Schema.optionalKey(Schema.Array(Schema.String.check(Schema.isMaxLength(64)))),
  /** Walk only this element's subtree. */
  root: Schema.optionalKey(ElementTarget),
  offset: Schema.Int.check(Schema.isBetween({ minimum: 0, maximum: 100_000 })),
  limit: Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 1000 })),
  includeOffscreen: Schema.Boolean,
});
export type SnapshotOptions = typeof SnapshotOptions.Type;

export const WorkerRequest = Schema.Union([
  Schema.Struct({
    kind: Schema.Literal("snapshot"),
    app: Schema.String,
    includeImage: Schema.Boolean,
    options: SnapshotOptions,
  }),
  Schema.Struct({
    kind: Schema.Literal("action"),
    app: Schema.String,
    pid: Schema.Int,
    target: Schema.NullOr(ElementTarget),
    action: ComputerAction,
    /** Where an element drag drops. */
    drop: Schema.optionalKey(ElementTarget),
    /** Capture pixels mapped to screen points: `to` is where click_at, move_at or a drag ends. */
    screen: Schema.optionalKey(
      Schema.Struct({
        window: CaptureWindow,
        from: Schema.optionalKey(ScreenPoint),
        to: Schema.optionalKey(ScreenPoint),
      }),
    ),
    /** Whether pointer input may briefly bring a background app forward while the user is idle. */
    takeover: Schema.Boolean,
    /** When the agent's previous pointer gesture ended (epoch ms), for the idle check. */
    ownInputAt: Schema.optionalKey(Schema.Number),
  }),
  Schema.Struct({ kind: Schema.Literal("open"), app: Schema.String, activate: Schema.Boolean }),
]);
export type WorkerRequest = typeof WorkerRequest.Type;

export const NativeSnapshot = Schema.Struct({
  app: Schema.String,
  pid: Schema.Int,
  truncated: Schema.Boolean,
  /** Pass as offset to read the elements after this page. */
  nextOffset: Schema.optionalKey(Schema.Int),
  /** Elements skipped because they lie outside their window or scroll area. */
  offscreen: Schema.Int,
  /** Top-level menu bar titles, for menu actions. */
  menus: Schema.optionalKey(Schema.Array(Schema.String)),
  frontmost: Schema.Boolean,
  elements: Schema.Array(ElementTarget),
  image: Schema.optionalKey(
    Schema.Struct({
      data: Schema.String,
      mimeType: Schema.Literal("image/png"),
      width: Schema.Int,
      height: Schema.Int,
      /** The captured window, so capture pixels can be mapped back to the screen. */
      window: CaptureWindow,
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
  Schema.Struct({
    ok: Schema.Literal(true),
    snapshot: Schema.optionalKey(NativeSnapshot),
    /** How an action was delivered. */
    via: Schema.optionalKey(
      Schema.Literals([
        "accessibility",
        "keyboard_event",
        "menu",
        "pointer",
        "takeover",
        "launch_services",
      ]),
    ),
    /** When pointer input ended (epoch ms). */
    inputAt: Schema.optionalKey(Schema.Number),
  }),
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
      "user_active",
      "menu_not_found",
      "failed",
    ]),
    detail: Schema.optionalKey(FailureDetail),
    /** Menu titles available where a menu path stopped matching. */
    available: Schema.optionalKey(Schema.Array(Schema.String)),
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
    "user_active",
    "invalid_point",
    "menu_not_found",
    "invalid_key",
    "failed",
  ]),
  cause: Schema.optional(Schema.Defect()),
  detail: Schema.optionalKey(FailureDetail),
  available: Schema.optionalKey(Schema.Array(Schema.String)),
}) {
  override get message(): string {
    switch (this.code) {
      case "disabled":
        return "Computer use is off. Enable it in Settings > Integrations > Computer use on the environment you want to control.";
      case "app_denied":
        return "This app is not allowed for computer use. Ask the user to enable Allow all computer apps or add it to Allowed computer apps in Settings > Integrations.";
      case "capture_denied":
        return "Screen capture is off. Ask the user to enable it in Settings > Integrations, or request a text-only snapshot.";
      case "snapshot_expired":
        return "Take a fresh computer_snapshot before acting. Snapshots expire after ten minutes and are replaced by the snapshot an action returns.";
      case "invalid_ref":
        return "That ref was not in the snapshot, a name matched no element or several (add role, or use a ref), or this action needs a target. Use the latest snapshot.";
      case "invalid_input":
        return "Invalid computer-use request. Check the tool's parameters.";
      case "permissions":
        if (this.detail?.reason === "screen_recording_permission")
          return "The native accessibility library requires macOS Screen & System Audio Recording permission even for text-only snapshots. Ask the user to grant it to the T3 host on that machine. T3's separate screenshot setting remains off unless enabled.";
        if (this.detail?.reason === "accessibility_permission")
          return "macOS has not granted Accessibility permission to the process running the T3 native helper. Ask the user to grant it to the T3 host on that machine.";
        return "The environment needs operating-system Accessibility or Screen Recording permission. Ask the user to grant it on that machine.";
      case "target_changed":
        return "The app, element or captured window changed. Take a fresh computer_snapshot before acting (with includeImage=true for click_at, move_at or drag coordinates).";
      case "app_not_running":
        return "That app is not running on the environment machine. Open it with computer_open.";
      case "unsupported_action":
        return "This element does not support that accessibility action. Use an action listed in a fresh snapshot.";
      case "capture_requires_foreground":
        return "The app has no visible window to capture. Open or unminimize one, or use includeImage=false.";
      case "input_requires_foreground":
        return "This action needs real pointer input, and the target was not reachable: the app is in the background and pointer takeover is off, or another window still covers the target. Prefer press, type, key, menu, or an action listed for the element; those run in the background. Otherwise ask the user to bring the app forward or turn on pointer takeover in Settings > Integrations > Computer use, then take a fresh snapshot.";
      case "user_active":
        return "The user is using this machine right now, so the agent did not take over the pointer. Prefer press, type, key, menu, or an action listed for the element; those run in the background. Otherwise ask the user to leave the mouse and keyboard alone for a few seconds, or to bring the app forward, and retry later.";
      case "invalid_point":
        return "click_at, move_at and drag coordinates are pixels of the app's latest window image and must lie inside it. Take computer_snapshot with includeImage=true and read coordinates from that image.";
      case "menu_not_found":
        return `No enabled menu item matched that path.${this.available?.length ? ` Available here: ${this.available.join(", ")}.` : ""}`;
      case "invalid_key":
        return "Unknown key. Use names like Return, Tab, Escape, Space, Delete, Up, Down, Left, Right, Home, End, PageUp, PageDown, F1-F12, or a character, optionally with cmd+, shift+, option+ or ctrl+ (for example cmd+shift+t). Use type for text.";
      case "unavailable":
        return "Native computer use is currently supported on macOS environments only.";
      default:
        return `Computer use did not complete${this.detail ? ` (${this.detail.stage}: ${this.detail.reason})` : ""}. An action may already have happened; inspect a fresh snapshot before trying again.`;
    }
  }
}
