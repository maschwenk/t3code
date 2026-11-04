// @effect-diagnostics nodeBuiltinImport:off globalTimers:off -- Runs in the isolated native worker, before an Effect runtime exists.
import * as NodeTimersPromises from "node:timers/promises";
import type { FrontProcess } from "./macNative.ts";
import type { WorkerRequest } from "./protocol.ts";

type Point = { readonly x: number; readonly y: number };
type Rect = Point & { readonly width: number; readonly height: number };

const POLL_MS = 50;
/** How long `open` keeps watching: many apps bring themselves forward once they finish launching. */
export const OPEN_SETTLE_MS = 1_500;
/** A click or a Command-Tab this recent can be how the user brought the target forward. */
const USER_SWITCH_MS = 700;
/** After this many restores in one session, an app that keeps coming forward is left in front. */
export const MAX_RESTORES = 5;
const COMMAND_KEYS = [54, 55];
const TAB_KEY = 48;

export type StackedWindow = { readonly id: number; readonly pid: number; readonly bounds: Rect };

/** The parts of the desktop the focus guard reads and changes. */
export type FocusDesktop = {
  readonly frontProcess: () => FrontProcess | undefined;
  /** Normal on-screen windows of every app, front to back. */
  readonly stack: () => readonly StackedWindow[];
  /** Puts `app` in front with `window` (0 for any) on top; true when it worked. */
  readonly bringToFront: (app: FrontProcess, window: number) => boolean;
  readonly secondsSinceUserClick: () => number;
  readonly pointer: () => Point;
  readonly keyHeld: (keyCode: number) => boolean;
};

export type FocusObservation = {
  /** The app the request works on; undefined while a launching app has no pid yet. */
  readonly target: number | undefined;
  /** The user's app: what was in front when the request started, or where the user moved since. */
  readonly previous: number | undefined;
  readonly front: number | undefined;
  readonly userSwitched: boolean;
  readonly restores: number;
};

export type FocusMove = "keep" | "adopt" | "restore";

/**
 * Restores the user's app only when the target app took the front by itself.
 * Any other change of front app is the user's doing and becomes the app to
 * restore from then on.
 */
export function focusMove(observed: FocusObservation): FocusMove {
  const { target, previous, front } = observed;
  if (front === undefined || front === previous || target === undefined) return "keep";
  if (front !== target || previous === undefined || observed.userSwitched) return "adopt";
  return observed.restores < MAX_RESTORES ? "restore" : "adopt";
}

const overlaps = (a: Rect, b: Rect) =>
  a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;

const within = (point: Point, rect: Rect) =>
  point.x >= rect.x &&
  point.y >= rect.y &&
  point.x < rect.x + rect.width &&
  point.y < rect.y + rect.height;

/**
 * Whether the pointer rests on a window of `owner`, the user's app. A click
 * there keeps the user in their own app, so it cannot be how the target came
 * forward; a click anywhere else, such as on the target's window, can be.
 */
export function pointerOnApp(
  frontToBack: readonly StackedWindow[],
  pointer: Point,
  owner: number,
): boolean {
  return frontToBack.find((window) => within(pointer, window.bounds))?.pid === owner;
}

/** Whether a window of `target` lies over the topmost window of `owner`. */
export function coveredBy(
  frontToBack: readonly StackedWindow[],
  owner: number,
  target: number,
): boolean {
  const top = frontToBack.findIndex((window) => window.pid === owner);
  const own = frontToBack[top];
  return (
    !!own &&
    frontToBack
      .slice(0, top)
      .some((window) => window.pid === target && overlaps(window.bounds, own.bounds))
  );
}

/** Requests that ask for the app in front, where the guard leaves focus alone. */
export function bringsAppForward(request: WorkerRequest): boolean {
  if (request.kind === "open") return request.activate;
  return request.kind === "action" && "foreground" in request.action && !!request.action.foreground;
}

/**
 * Watches the front app for one worker session and sends the target app back
 * behind the user's app whenever it comes forward on its own: apps activate
 * themselves when they launch or reopen, and some when an accessibility
 * action reaches them. Native failures turn the guard off rather than fail
 * the request.
 */
export function makeFocusGuard(desktop: FocusDesktop) {
  let previous: FrontProcess | undefined;
  let target: number | undefined;
  let timer: ReturnType<typeof setInterval> | undefined;
  let restores = 0;
  let sentBack = false;
  let switching = false;
  let switcherAt = Number.NEGATIVE_INFINITY;
  let clickAt = Number.NEGATIVE_INFINITY;
  let clickInUserApp = false;

  // Command-Tab switches apps when Command is released, which can be well
  // after Tab was pressed. Other Command shortcuts do not switch apps.
  const trackSwitcher = () => {
    const command = COMMAND_KEYS.some((code) => desktop.keyHeld(code));
    switching = command && (switching || desktop.keyHeld(TAB_KEY));
    if (switching) switcherAt = performance.now();
  };
  // Where the user's latest click landed, judged within one poll of it: the
  // target raises its windows once it takes the front, so the windows under
  // the pointer afterwards no longer show what the user clicked.
  const trackClick = () => {
    const at = performance.now() - desktop.secondsSinceUserClick() * 1000;
    if (at - clickAt < POLL_MS / 2) return;
    clickAt = at;
    clickInUserApp =
      previous !== undefined && pointerOnApp(desktop.stack(), desktop.pointer(), previous.pid);
  };
  const userSwitched = () => {
    const now = performance.now();
    return now - switcherAt < USER_SWITCH_MS || (now - clickAt < USER_SWITCH_MS && !clickInUserApp);
  };

  const disarm = () => {
    clearInterval(timer);
    timer = undefined;
    previous = undefined;
  };
  const guarded = (work: () => void) => {
    if (!timer) return;
    try {
      work();
    } catch {
      disarm();
    }
  };
  const sendBack = (app: FrontProcess, stack: readonly StackedWindow[]) => {
    restores++;
    const window = stack.find((candidate) => candidate.pid === app.pid)?.id ?? 0;
    if (desktop.bringToFront(app, window)) sentBack = true;
  };
  const enforce = () => {
    trackSwitcher();
    trackClick();
    const front = desktop.frontProcess();
    const move = focusMove({
      target,
      previous: previous?.pid,
      front: front?.pid,
      userSwitched: userSwitched(),
      restores,
    });
    if (move === "adopt") {
      // The click or Command-Tab that just switched apps is spent.
      previous = front;
      clickInUserApp = true;
      switcherAt = Number.NEGATIVE_INFINITY;
    }
    if (move === "restore" && previous) sendBack(previous, desktop.stack());
  };
  // A target window can stay over the user's window without taking the front,
  // for example after a raise.
  const uncover = () => {
    if (!previous || target === undefined || previous.pid === target) return;
    if (restores >= MAX_RESTORES || desktop.frontProcess()?.pid !== previous.pid) return;
    const stack = desktop.stack();
    if (coveredBy(stack, previous.pid, target)) sendBack(previous, stack);
  };
  const check = () => guarded(enforce);

  return {
    /** Starts watching from the current front app, unless already watching. */
    arm() {
      if (timer) return;
      try {
        previous = desktop.frontProcess();
      } catch {
        return;
      }
      timer = setInterval(check, POLL_MS);
      timer.unref();
    },
    disarm,
    watch(pid: number) {
      target = pid;
      check();
    },
    /** Called when a request ends. */
    finish() {
      check();
      guarded(uncover);
    },
    /** Keeps watching for `ms` before the request ends, for apps that come forward late. */
    async settle(ms: number) {
      if (!timer) return;
      await NodeTimersPromises.setTimeout(ms);
      check();
    },
    /** Whether an app was sent back since the last call. */
    takeSentBack() {
      const value = sentBack;
      sentBack = false;
      return value;
    },
  };
}
export type FocusGuard = ReturnType<typeof makeFocusGuard>;
