import { assert, describe, it } from "vite-plus/test";

import { createLaunchLimiter } from "./launch-limiter.mjs";

describe("createLaunchLimiter", () => {
  it("refuses launches past the limit until the window has moved on", () => {
    let time = 1_000;
    const limiter = createLaunchLimiter({ max: 3, windowMs: 10_000, now: () => time });

    assert.equal(limiter.tryLaunch(), true);
    time += 1_000;
    assert.equal(limiter.tryLaunch(), true);
    time += 1_000;
    assert.equal(limiter.tryLaunch(), true);
    time += 1_000;
    assert.equal(limiter.tryLaunch(), false);

    // The first launch leaves the window 10 s after it happened.
    time = 11_000;
    assert.equal(limiter.tryLaunch(), true);
    assert.equal(limiter.tryLaunch(), false);
  });

  it("does not count a refused launch against the window", () => {
    let time = 0;
    const limiter = createLaunchLimiter({ max: 1, windowMs: 5_000, now: () => time });
    assert.equal(limiter.tryLaunch(), true);
    for (time = 1_000; time < 5_000; time += 1_000) assert.equal(limiter.tryLaunch(), false);
    time = 5_000;
    assert.equal(limiter.tryLaunch(), true);
  });
});
