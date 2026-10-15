import { expect, it } from "@effect/vitest";
import { clickTransitions, dragTransitions, wheelDeltas, windowFor } from "./pointerEvents.ts";

const windows = [
  { id: 7, layer: 25, bounds: { x: 0, y: 0, width: 800, height: 40 } },
  { id: 3, layer: 0, bounds: { x: 100, y: 100, width: 400, height: 300 } },
  { id: 2, layer: 0, bounds: { x: 100, y: 100, width: 400, height: 300 } },
  { id: 1, layer: 0, bounds: { x: 50, y: 50, width: 900, height: 700 } },
];

it("addresses input to the element's own window, never a menu bar or a window elsewhere", () => {
  // Two same-sized windows: the topmost wins when the AX window matches both.
  expect(
    windowFor(windows, { x: 100.4, y: 100, width: 400, height: 300 }, { x: 200, y: 200 })?.id,
  ).toBe(3);
  // Without an AX window, the topmost normal window under the point.
  expect(windowFor(windows, null, { x: 60, y: 600 })?.id).toBe(1);
  expect(windowFor(windows, null, { x: 10, y: 20 })).toBeUndefined();
  // A matched window that does not contain the point is refused rather than used blindly.
  expect(
    windowFor(windows, { x: 100, y: 100, width: 400, height: 300 }, { x: 900, y: 700 }),
  ).toBeUndefined();
});

it("presses and releases once per click, with the second click marked as such", () => {
  const point = { x: 10, y: 20 };
  expect(
    clickTransitions(point, "right", 1).map((t) => `${t.kind}:${t.button}:${t.clickState}`),
  ).toEqual(["move:right:0", "down:right:1", "up:right:1"]);
  expect(clickTransitions(point, "left", 2).map((t) => t.clickState)).toEqual([0, 1, 1, 2, 2]);
});

it("drags along a path that starts and ends exactly on the given points", () => {
  const transitions = dragTransitions({ x: 0, y: 0 }, { x: 100, y: 50 }, 4);
  expect(transitions.map((t) => t.kind)).toEqual([
    "move",
    "down",
    "drag",
    "drag",
    "drag",
    "drag",
    "up",
  ]);
  expect(transitions.at(-1)?.point).toEqual({ x: 100, y: 50 });
  expect(transitions[3]?.point).toEqual({ x: 50, y: 25 });
  expect(transitions.every((t) => t.kind === "move" || t.clickState === 1)).toBe(true);
});

it("scrolls content down and right by sending negative wheel deltas", () => {
  expect(wheelDeltas(0, 120)).toEqual({ vertical: -120, horizontal: 0 });
  expect(wheelDeltas(-30.4, -10)).toEqual({ vertical: 10, horizontal: 30 });
});
