import { expect, it } from "@effect/vitest";
import { pointerTarget } from "./pointerTarget.ts";

it("keeps logical coordinates on displays above or left of the main display", () => {
  expect(
    pointerTarget(
      { x: -900, y: -400, width: 100, height: 40 },
      { x: -1000, y: -500, width: 500, height: 400 },
    ),
  ).toEqual([-850, -380]);
});

it("refuses off-window, empty and invalid pointer targets instead of clipping them to another control", () => {
  const window = { x: 100, y: 100, width: 400, height: 300 };
  for (const target of [
    null,
    { x: 100, y: 100, width: 0, height: 50 },
    { x: 480, y: 100, width: 100, height: 50 },
    { x: NaN, y: 100, width: 30, height: 30 },
    { x: 100, y: -100, width: 30, height: 30 },
  ]) {
    expect(pointerTarget(target, window)).toBeUndefined();
  }
  expect(pointerTarget(window, null)).toBeUndefined();
});
