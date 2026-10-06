import { computerCursorGlideMs, type DesktopTelemetryShowComputerCursor } from "@t3tools/contracts";
import * as Clock from "effect/Clock";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import type * as Scope from "effect/Scope";
import * as Stream from "effect/Stream";
import * as Electron from "electron";

import * as DesktopTelemetryPublisher from "../telemetry/DesktopTelemetryPublisher.ts";
import { glideKeyframes, planGlide, sampleGlide, type Glide, type Point } from "./cursorMotion.ts";
import { OVERLAY_HTML } from "./overlayPage.ts";

/** The cursor stays between the actions of one task and fades after this long idle. */
const IDLE_MS = 8_000;
const FADE_MS = 300;
/** Where the cursor enters from (relative to its first target) the first time it appears. */
const ENTRY_OFFSET = { x: 140, y: 110 };
/** Room around a path for the arrow, label, and ripple when picking displays. */
const MARGIN = 80;

type Overlay = { readonly window: Electron.BrowserWindow; readonly loaded: Promise<void> };

function createOverlay(bounds: Electron.Rectangle): Overlay {
  const window = new Electron.BrowserWindow({
    ...bounds,
    alwaysOnTop: true,
    backgroundColor: "#00000000",
    enableLargerThanScreen: true,
    focusable: false,
    frame: false,
    hasShadow: false,
    hiddenInMissionControl: true,
    movable: false,
    resizable: false,
    show: false,
    skipTaskbar: true,
    title: "T3 Code Agent Cursor",
    transparent: true,
    webPreferences: {
      backgroundThrottling: false,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      spellcheck: false,
    },
  });
  window.setAlwaysOnTop(true, "screen-saver");
  window.setVisibleOnAllWorkspaces(true, {
    visibleOnFullScreen: true,
    skipTransformProcessType: true,
  });
  window.setIgnoreMouseEvents(true);
  window.excludedFromShownWindowsMenu = true;
  const loaded = window.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(OVERLAY_HTML)}`);
  return { window, loaded };
}

const intersects = (
  box: { minX: number; minY: number; maxX: number; maxY: number },
  rect: Electron.Rectangle,
) =>
  box.maxX >= rect.x &&
  box.minX <= rect.x + rect.width &&
  box.maxY >= rect.y &&
  box.minY <= rect.y + rect.height;

const round = (value: number) => Math.round(value * 10) / 10;

/**
 * Draws the agent's computer-use cursor in click-through, non-focusable
 * overlays, one per display it travels across. Background accessibility actions
 * never move the user's mouse, so this is how the user sees where the agent is
 * working. Motion runs as compositor animations; an idle cursor costs nothing.
 */
export const listen: Effect.Effect<
  void,
  never,
  DesktopTelemetryPublisher.DesktopTelemetryPublisher | Scope.Scope
> = Effect.gen(function* () {
  const publisher = yield* DesktopTelemetryPublisher.DesktopTelemetryPublisher;
  const overlays = new Map<number, Overlay>();
  let glide: { readonly path: Glide; readonly startedAt: number } | undefined;
  let visible = false;
  let idleFiber: Fiber.Fiber<void> | undefined;

  const destroyAll = () => {
    for (const { window } of overlays.values()) if (!window.isDestroyed()) window.destroy();
    overlays.clear();
    visible = false;
  };
  // Display layout or scale changed: rebuild windows lazily at the new geometry.
  Electron.screen.on("display-added", destroyAll);
  Electron.screen.on("display-removed", destroyAll);
  Electron.screen.on("display-metrics-changed", destroyAll);

  const overlayFor = (display: Electron.Display) => {
    const existing = overlays.get(display.id);
    if (existing && !existing.window.isDestroyed()) return existing;
    const created = createOverlay(display.bounds);
    overlays.set(display.id, created);
    return created;
  };

  const show = (request: DesktopTelemetryShowComputerCursor) =>
    Effect.gen(function* () {
      const now = yield* Clock.currentTimeMillis;
      const target = { x: request.x, y: request.y };
      let from: Point;
      let velocity: Point | undefined;
      if (glide && visible) {
        // Continue from wherever the cursor is right now, at its current speed.
        const sample = sampleGlide(glide.path, now - glide.startedAt);
        from = sample.position;
        velocity = sample.velocity;
      } else if (glide) {
        from = glide.path.to;
      } else {
        from = { x: target.x + ENTRY_OFFSET.x, y: target.y + ENTRY_OFFSET.y };
      }
      const durationMs =
        request.durationMs ??
        computerCursorGlideMs(Math.hypot(target.x - from.x, target.y - from.y));
      const path = planGlide(from, target, durationMs, velocity);
      glide = { path, startedAt: now };
      const frames = glideKeyframes(path);
      const box = {
        minX: Math.min(...frames.map((p) => p.x)) - MARGIN,
        minY: Math.min(...frames.map((p) => p.y)) - MARGIN,
        maxX: Math.max(...frames.map((p) => p.x)) + MARGIN,
        maxY: Math.max(...frames.map((p) => p.y)) + MARGIN,
      };
      const displays = Electron.screen.getAllDisplays();
      const onPath = new Set<number>();
      yield* Effect.forEach(
        displays.filter((display) => intersects(box, display.bounds)),
        (display) =>
          Effect.gen(function* () {
            onPath.add(display.id);
            const overlay = overlayFor(display);
            const origin = display.bounds;
            // Numbers and a schema literal only, so plain interpolation is safe.
            const local = frames
              .map((p) => `[${round(p.x - origin.x)},${round(p.y - origin.y)}]`)
              .join(",");
            const bounds = request.bounds
              ? `[${round(request.bounds.x - origin.x)},${round(request.bounds.y - origin.y)},${round(request.bounds.width)},${round(request.bounds.height)}]`
              : "null";
            const cue = request.cue ? `"${request.cue}"` : "null";
            yield* Effect.tryPromise(() => overlay.loaded);
            if (overlay.window.isDestroyed()) return;
            yield* Effect.tryPromise(() =>
              overlay.window.webContents.executeJavaScript(
                `glide([${local}],${Math.round(durationMs)},${cue},${bounds})`,
              ),
            );
            if (!overlay.window.isVisible()) overlay.window.showInactive();
          }).pipe(
            Effect.catchCause((cause) =>
              Effect.logWarning("computer cursor overlay failed", { cause: String(cause) }),
            ),
          ),
        { concurrency: "unbounded", discard: true },
      );
      visible = true;
      for (const [id, overlay] of overlays)
        if (!onPath.has(id) && !overlay.window.isDestroyed()) overlay.window.hide();

      if (idleFiber) yield* Fiber.interrupt(idleFiber);
      idleFiber = yield* Effect.gen(function* () {
        // Once arrived, drop overlays on displays the cursor only passed through.
        yield* Effect.sleep(durationMs + 50);
        const home = Electron.screen.getDisplayNearestPoint({
          x: Math.round(target.x),
          y: Math.round(target.y),
        });
        for (const [id, overlay] of overlays)
          if (id !== home.id && !overlay.window.isDestroyed()) overlay.window.hide();
        yield* Effect.sleep(IDLE_MS);
        visible = false;
        for (const overlay of overlays.values())
          if (!overlay.window.isDestroyed())
            yield* Effect.promise(() =>
              overlay.window.webContents.executeJavaScript("fadeOut()").catch(() => undefined),
            );
        yield* Effect.sleep(FADE_MS);
        for (const overlay of overlays.values())
          if (!overlay.window.isDestroyed()) overlay.window.hide();
      }).pipe(Effect.forkScoped);
    });

  yield* Stream.runForEach(publisher.computerCursorRequests, show).pipe(Effect.forkScoped);

  yield* Effect.addFinalizer(() =>
    Effect.sync(() => {
      Electron.screen.off("display-added", destroyAll);
      Electron.screen.off("display-removed", destroyAll);
      Electron.screen.off("display-metrics-changed", destroyAll);
      destroyAll();
    }),
  );
});
