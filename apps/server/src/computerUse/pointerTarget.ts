type Rect = {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
};

/** AX and input simulation share logical screen coordinates, including negative
 * origins on secondary displays. Never route a pointer to an off-window centre. */
export function pointerTarget(
  bounds: Rect | null,
  window: Rect | null,
): [number, number] | undefined {
  if (!bounds || !window) return undefined;
  if (
    ![
      bounds.x,
      bounds.y,
      bounds.width,
      bounds.height,
      window.x,
      window.y,
      window.width,
      window.height,
    ].every(Number.isFinite)
  )
    return undefined;
  if (bounds.width <= 0 || bounds.height <= 0 || window.width <= 0 || window.height <= 0)
    return undefined;
  const x = bounds.x + bounds.width / 2;
  const y = bounds.y + bounds.height / 2;
  if (x < window.x || y < window.y || x >= window.x + window.width || y >= window.y + window.height)
    return undefined;
  return [x, y];
}
