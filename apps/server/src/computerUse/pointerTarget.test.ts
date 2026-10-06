import { expect, it } from "@effect/vitest";
import { captureToScreen, pointerTarget } from "./pointerTarget.ts";

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

it("maps capture pixels to screen points through Retina scale and the 1600 px downscale", () => {
  // A 1000x800 pt window on a secondary display, captured at 2x (2000x1600 px)
  // and then downscaled to fit 1600 px.
  const capture = {
    window: { id: 9, bounds: { x: -1200, y: 100, width: 1000, height: 800 } },
    width: 1600,
    height: 1280,
  };
  expect(captureToScreen(capture, { x: 0, y: 0 })).toEqual({ x: -1200, y: 100 });
  expect(captureToScreen(capture, { x: 800, y: 640 })).toEqual({ x: -700, y: 500 });
  // A small Retina window keeps its 2x pixels.
  const small = {
    ...capture,
    window: { id: 9, bounds: { x: 10, y: 20, width: 230, height: 400 } },
    width: 460,
    height: 800,
  };
  expect(captureToScreen(small, { x: 230, y: 100 })).toEqual({ x: 125, y: 70 });
  for (const pixel of [
    { x: 1600, y: 10 },
    { x: 10, y: 1280 },
    { x: -1, y: 10 },
    { x: NaN, y: 10 },
  ])
    expect(captureToScreen(capture, pixel)).toBeUndefined();
});
