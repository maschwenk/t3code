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

/** What the server remembers of the latest window image an agent received for an app. */
export type Capture = {
  readonly window: { readonly id: number; readonly bounds: Rect };
  /** Image size in pixels, after any downscale. */
  readonly width: number;
  readonly height: number;
};

/**
 * Maps a pixel of a window capture to a screen point. The image spans exactly
 * the window's bounds, so one ratio covers both the Retina backing scale and
 * the downscale applied to large captures. Pixels outside the image are refused.
 */
export function captureToScreen(
  capture: Capture,
  pixel: { readonly x: number; readonly y: number },
): { x: number; y: number } | undefined {
  const { bounds } = capture.window;
  if (
    !Number.isFinite(pixel.x) ||
    !Number.isFinite(pixel.y) ||
    capture.width <= 0 ||
    capture.height <= 0 ||
    pixel.x < 0 ||
    pixel.y < 0 ||
    pixel.x >= capture.width ||
    pixel.y >= capture.height
  )
    return undefined;
  return {
    x: bounds.x + (pixel.x * bounds.width) / capture.width,
    y: bounds.y + (pixel.y * bounds.height) / capture.height,
  };
}

/** Whether a live window still has the bounds a capture recorded, within a point of rounding. */
export const sameWindowBounds = (a: Rect, b: Rect) =>
  Math.abs(a.x - b.x) < 1 &&
  Math.abs(a.y - b.y) < 1 &&
  Math.abs(a.width - b.width) < 1 &&
  Math.abs(a.height - b.height) < 1;
