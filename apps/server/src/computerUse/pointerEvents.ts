type Point = { readonly x: number; readonly y: number };
type Rect = {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
};
/** A window-server window an event can be addressed to. */
export type PointerWindow = { readonly id: number; readonly bounds: Rect };
type ListedWindow = PointerWindow & { readonly layer: number };

/** One pointer event posted to an app: a transition of the virtual pointer at `point`. */
export type Transition = {
  readonly kind: "move" | "down" | "up" | "drag";
  readonly button: "left" | "right";
  /** kCGMouseEventClickState: 1 for a single click's down and up, 2 for the second click. */
  readonly clickState: number;
  readonly point: Point;
};

const contains = (rect: Rect, point: Point) =>
  point.x >= rect.x &&
  point.y >= rect.y &&
  point.x < rect.x + rect.width &&
  point.y < rect.y + rect.height;

/**
 * The window of the app that should receive input at `point`: the one whose
 * frame matches the element's accessibility window (within rounding), else the
 * app's topmost normal window under the point. `windows` is front to back, as
 * the window server lists it.
 */
export function windowFor(
  windows: readonly ListedWindow[],
  axWindow: Rect | null,
  point: Point,
): PointerWindow | undefined {
  const normal = windows.filter((window) => window.layer === 0);
  const matched =
    axWindow &&
    normal.find(
      (window) =>
        Math.abs(window.bounds.x - axWindow.x) < 2 &&
        Math.abs(window.bounds.y - axWindow.y) < 2 &&
        Math.abs(window.bounds.width - axWindow.width) < 2,
    );
  const window = matched || normal.find((candidate) => contains(candidate.bounds, point));
  return window && contains(window.bounds, point)
    ? { id: window.id, bounds: window.bounds }
    : undefined;
}

/** A click: the pointer arrives, then presses and releases once per count. */
export function clickTransitions(
  point: Point,
  button: "left" | "right",
  count: 1 | 2,
): Transition[] {
  const transitions: Transition[] = [{ kind: "move", button, clickState: 0, point }];
  for (let clickState = 1; clickState <= count; clickState++)
    transitions.push(
      { kind: "down", button, clickState, point },
      { kind: "up", button, clickState, point },
    );
  return transitions;
}

/** A left drag from `from` to `to` in `steps` moves, ending exactly at `to`. */
export function dragTransitions(from: Point, to: Point, steps = 25): Transition[] {
  const button = "left";
  const transitions: Transition[] = [
    { kind: "move", button, clickState: 0, point: from },
    { kind: "down", button, clickState: 1, point: from },
  ];
  for (let step = 1; step <= steps; step++)
    transitions.push({
      kind: "drag",
      button,
      clickState: 1,
      point: {
        x: from.x + ((to.x - from.x) * step) / steps,
        y: from.y + ((to.y - from.y) * step) / steps,
      },
    });
  transitions.push({ kind: "up", button, clickState: 1, point: to });
  return transitions;
}

/**
 * Scroll wheel units for a scroll request. Positive dy scrolls the content
 * down, which CoreGraphics expresses as a negative vertical wheel delta, and
 * likewise for dx and the horizontal wheel.
 */
export function wheelDeltas(dx: number, dy: number): { vertical: number; horizontal: number } {
  return { vertical: 0 - Math.round(dy), horizontal: 0 - Math.round(dx) };
}
