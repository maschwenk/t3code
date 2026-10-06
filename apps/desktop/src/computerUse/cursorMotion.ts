/**
 * Agent cursor motion. A glide is a cubic Hermite curve in time from the
 * current position and velocity to the target (arriving at rest), plus a small
 * sideways bow so long moves arc like a wrist movement instead of a ruler line.
 * Starting from the current velocity keeps the motion continuous when a new
 * target arrives mid-flight.
 */
export interface Point {
  readonly x: number;
  readonly y: number;
}

export interface Glide {
  readonly from: Point;
  readonly to: Point;
  /** Initial velocity in px/ms. */
  readonly velocity: Point;
  readonly durationMs: number;
  /** Signed sideways offset at the midpoint, in px. */
  readonly bow: number;
}

const MAX_BOW = 70;
const BOW_RATIO = 0.1;

export function planGlide(from: Point, to: Point, durationMs: number, velocity?: Point): Glide {
  const dx = to.x - from.x;
  const dy = to.y - from.y;
  const distance = Math.hypot(dx, dy);
  // Bow toward the upper side of the travel direction (or left when vertical)
  // so a sequence of moves arcs consistently.
  const nx = distance === 0 ? 0 : -dy / distance;
  const ny = distance === 0 ? 0 : dx / distance;
  const side = ny > 0 || (ny === 0 && nx > 0) ? -1 : 1;
  return {
    from,
    to,
    velocity: velocity ?? { x: 0, y: 0 },
    durationMs: Math.max(1, durationMs),
    bow: side * Math.min(MAX_BOW, distance * BOW_RATIO),
  };
}

/** Position and velocity (px/ms) `elapsedMs` into a glide. Clamps at both ends. */
export function sampleGlide(glide: Glide, elapsedMs: number): { position: Point; velocity: Point } {
  const { from, to, velocity, durationMs: T, bow } = glide;
  if (elapsedMs >= T) return { position: to, velocity: { x: 0, y: 0 } };
  const u = Math.max(0, elapsedMs) / T;
  const u2 = u * u;
  const u3 = u2 * u;
  const h00 = 2 * u3 - 3 * u2 + 1;
  const h10 = u3 - 2 * u2 + u;
  const h01 = -2 * u3 + 3 * u2;
  const d00 = 6 * u2 - 6 * u;
  const d10 = 3 * u2 - 4 * u + 1;
  const d01 = -6 * u2 + 6 * u;
  // Sideways bump 16u²(1-u)²: zero position and slope at both ends.
  const dx = to.x - from.x;
  const dy = to.y - from.y;
  const distance = Math.hypot(dx, dy);
  const nx = distance === 0 ? 0 : -dy / distance;
  const ny = distance === 0 ? 0 : dx / distance;
  const bump = bow * 16 * u2 * (1 - u) * (1 - u);
  const bumpSlope = bow * 32 * u * (1 - u) * (1 - 2 * u);
  return {
    position: {
      x: h00 * from.x + h10 * T * velocity.x + h01 * to.x + bump * nx,
      y: h00 * from.y + h10 * T * velocity.y + h01 * to.y + bump * ny,
    },
    velocity: {
      x: (d00 * from.x + d01 * to.x + bumpSlope * nx) / T + d10 * velocity.x,
      y: (d00 * from.y + d01 * to.y + bumpSlope * ny) / T + d10 * velocity.y,
    },
  };
}

/** Evenly timed positions for a linear-interpolated Web Animation (~60 fps). */
export function glideKeyframes(glide: Glide): Point[] {
  const steps = Math.min(60, Math.max(8, Math.round(glide.durationMs / 16)));
  return Array.from(
    { length: steps + 1 },
    (_, index) => sampleGlide(glide, (glide.durationMs * index) / steps).position,
  );
}
