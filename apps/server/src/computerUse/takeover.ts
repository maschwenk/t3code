type Point = { readonly x: number; readonly y: number };

/** Seconds without any user input (keys, pointer, scrolling) before an agent may take over the pointer. */
export const USER_IDLE_SECONDS = 3;
/** How long the target app gets to come forward. */
export const ACTIVATION_TIMEOUT_MS = 1_000;
/** Lets a person see where the pointer lands before it acts. */
export const POINTER_LEAD_MS = 160;
// The idle clock and ours are read at slightly different moments.
const CLOCK_SLACK_SECONDS = 0.05;

/** The parts of the desktop that pointer delivery reads and changes. */
export type Desktop = {
  readonly frontmost: () => Promise<number | undefined>;
  /** Asks an app to come forward; true when the request was accepted. */
  readonly activate: (pid: number) => boolean;
  /** Raises the target window within its app. */
  readonly raise: () => Promise<void>;
  /** The process owning the topmost element at a screen point. */
  readonly owner: (point: Point) => number | undefined;
  /** Seconds since the last input event from any source in the login session. */
  readonly idleSeconds: () => number;
  readonly pointer: () => Point;
  /** Puts the pointer back without generating input. */
  readonly warp: (point: Point) => void;
  readonly moveTo: (point: Point) => Promise<void>;
  readonly sleep: (ms: number) => Promise<void>;
  /** Wall-clock milliseconds, comparable across worker processes. */
  readonly now: () => number;
};

export type PointerOutcome =
  /** `inputAt` is when the agent's own input ended, for the next step's idle check. */
  | { readonly ok: true; readonly via: "pointer" | "takeover"; readonly inputAt: number }
  | { readonly ok: false; readonly code: "input_requires_foreground" | "user_active" };

/**
 * Runs real pointer input whose points must land on `pid`.
 *
 * When the app is already in front and owns every point, input runs as is.
 * Otherwise, if takeover is allowed and the user has been idle for
 * USER_IDLE_SECONDS, the app is brought forward just for this gesture, then
 * the user's pointer and frontmost app are restored. Any user input during
 * the takeover aborts it before the gesture, or skips putting the pointer
 * back after it, so the agent never fights the user for the mouse.
 *
 * `ownInputAt` is when an earlier gesture of the agent's ended. macOS may
 * count synthesized events as input, so a user who has not touched anything
 * since then is still idle, and a batch can run several pointer steps.
 */
export async function deliverPointer(
  desktop: Desktop,
  options: {
    readonly pid: number;
    readonly points: readonly Point[];
    readonly takeover: boolean;
    readonly ownInputAt?: number | undefined;
  },
  gesture: () => Promise<void>,
): Promise<PointerOutcome> {
  const { pid, points } = options;
  const owned = () => points.every((point) => desktop.owner(point) === pid);
  const lead = points[0];
  if (!lead) return { ok: false, code: "input_requires_foreground" };
  // Our own synthesized events may count as input too, so input "since t" is
  // detected as the idle clock being younger than the time since t.
  const userMovedSince = (at: number) =>
    desktop.idleSeconds() < (desktop.now() - at) / 1000 - CLOCK_SLACK_SECONDS;

  if ((await desktop.frontmost()) === pid && owned()) {
    await desktop.moveTo(lead);
    await desktop.sleep(POINTER_LEAD_MS);
    if ((await desktop.frontmost()) !== pid || !owned())
      return { ok: false, code: "input_requires_foreground" };
    await gesture();
    return { ok: true, via: "pointer", inputAt: desktop.now() };
  }
  if (!options.takeover) return { ok: false, code: "input_requires_foreground" };
  const idle =
    desktop.idleSeconds() >= USER_IDLE_SECONDS ||
    (options.ownInputAt !== undefined && !userMovedSince(options.ownInputAt));
  if (!idle) return { ok: false, code: "user_active" };

  const previous = { app: await desktop.frontmost(), pointer: desktop.pointer() };
  let quietSince = desktop.now();
  let userMoved = false;
  try {
    if (!desktop.activate(pid)) return { ok: false, code: "input_requires_foreground" };
    await desktop.raise();
    const deadline = desktop.now() + ACTIVATION_TIMEOUT_MS;
    // macOS reports AXFrontmost before the window server has finished raising
    // the window. Wait for hit-testing to agree before delivering input.
    while ((await desktop.frontmost()) !== pid || !owned()) {
      if ((userMoved = userMovedSince(quietSince))) return { ok: false, code: "user_active" };
      if (desktop.now() >= deadline) return { ok: false, code: "input_requires_foreground" };
      await desktop.sleep(50);
    }
    if ((userMoved = userMovedSince(quietSince))) return { ok: false, code: "user_active" };
    if (!owned()) return { ok: false, code: "input_requires_foreground" };
    await desktop.moveTo(lead);
    quietSince = desktop.now();
    await desktop.sleep(POINTER_LEAD_MS);
    if ((userMoved = userMovedSince(quietSince))) return { ok: false, code: "user_active" };
    if ((await desktop.frontmost()) !== pid || !owned())
      return { ok: false, code: "input_requires_foreground" };
    await gesture();
    quietSince = desktop.now();
    return { ok: true, via: "takeover", inputAt: quietSince };
  } finally {
    // A user who moved the mouse meanwhile keeps it where they put it.
    if (!userMoved && !userMovedSince(quietSince)) desktop.warp(previous.pointer);
    if (previous.app !== undefined && previous.app !== pid && desktop.activate(previous.app)) {
      const deadline = desktop.now() + ACTIVATION_TIMEOUT_MS;
      while ((await desktop.frontmost()) !== previous.app && desktop.now() < deadline)
        await desktop.sleep(50);
    }
  }
}
