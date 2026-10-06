/**
 * Allows at most `max` launches within any `windowMs`. The dev runner uses it
 * to stop for good instead of opening app after app if something keeps asking
 * it to relaunch.
 */
export function createLaunchLimiter({ max, windowMs, now = Date.now }) {
  const launches = [];
  return {
    /** Records a launch and returns true, or returns false once the limit is reached. */
    tryLaunch() {
      const current = now();
      while (launches.length > 0 && current - launches[0] >= windowMs) launches.shift();
      if (launches.length >= max) return false;
      launches.push(current);
      return true;
    },
  };
}
