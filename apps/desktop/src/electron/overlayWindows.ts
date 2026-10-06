import type * as Electron from "electron";

// Click-through overlays such as the agent cursor are windows but not app UI:
// app-wide operations (appearance sync paints an opaque background, broadcasts,
// the main-window fallback, capture destinations) must skip them.
const overlayWindows = new WeakSet<Electron.BrowserWindow>();

export const markOverlayWindow = (window: Electron.BrowserWindow): void => {
  overlayWindows.add(window);
};

export const isOverlayWindow = (window: Electron.BrowserWindow): boolean =>
  overlayWindows.has(window);
