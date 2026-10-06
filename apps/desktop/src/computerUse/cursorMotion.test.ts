import { computerCursorGlideMs } from "@t3tools/contracts";
import { assert, describe, it } from "vite-plus/test";

import { glideKeyframes, planGlide, sampleGlide } from "./cursorMotion.ts";

const close = (actual: number, expected: number, tolerance = 1e-6) =>
  assert.isAtMost(Math.abs(actual - expected), tolerance, `${actual} vs ${expected}`);

describe("agent cursor motion", () => {
  it("lands exactly on the target at rest", () => {
    const glide = planGlide({ x: 100, y: 500 }, { x: 900, y: 200 }, 400);
    const start = sampleGlide(glide, 0);
    close(start.position.x, 100);
    close(start.position.y, 500);
    const end = sampleGlide(glide, 400);
    assert.deepEqual(end.position, { x: 900, y: 200 });
    assert.deepEqual(end.velocity, { x: 0, y: 0 });
    // Just before arrival it is nearly stopped: the ease-out is real.
    const speed = (t: number) =>
      Math.hypot(sampleGlide(glide, t).velocity.x, sampleGlide(glide, t).velocity.y);
    assert.isBelow(speed(396), speed(200) * 0.05);
  });

  it("continues a retargeted glide without a jump or change of speed", () => {
    const first = planGlide({ x: 0, y: 0 }, { x: 1000, y: 0 }, 500);
    const midway = sampleGlide(first, 180);
    const second = planGlide(midway.position, { x: 400, y: 600 }, 450, midway.velocity);
    const resumed = sampleGlide(second, 0);
    close(resumed.position.x, midway.position.x);
    close(resumed.position.y, midway.position.y);
    close(resumed.velocity.x, midway.velocity.x);
    close(resumed.velocity.y, midway.velocity.y);
    // The analytic velocity matches the path it draws.
    const ahead = sampleGlide(second, 1);
    close(ahead.position.x - resumed.position.x, resumed.velocity.x, 0.05);
  });

  it("arcs long moves toward the upper side by a bounded amount", () => {
    const right = sampleGlide(planGlide({ x: 0, y: 300 }, { x: 600, y: 300 }, 400), 200);
    close(right.position.x, 300);
    close(right.position.y, 300 - 60);
    const left = sampleGlide(planGlide({ x: 3000, y: 300 }, { x: 0, y: 300 }, 600), 300);
    close(left.position.y, 300 - 70);
  });

  it("samples about one keyframe per frame, ending on the target", () => {
    const frames = glideKeyframes(planGlide({ x: 0, y: 0 }, { x: 300, y: 400 }, 320));
    assert.lengthOf(frames, 21);
    assert.deepEqual(frames.at(-1), { x: 300, y: 400 });
  });

  it("takes longer for longer moves, within readable bounds", () => {
    const hop = computerCursorGlideMs(20);
    const across = computerCursorGlideMs(400);
    assert.isAtLeast(hop, 160);
    assert.isBelow(hop, across);
    assert.strictEqual(computerCursorGlideMs(5000), 650);
  });
});
