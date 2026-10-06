import { computerCursorGlideMs, type DesktopTelemetryShowComputerCursor } from "@t3tools/contracts";
import * as Clock from "effect/Clock";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import type * as Scope from "effect/Scope";
import * as Stream from "effect/Stream";
import * as Electron from "electron";

import { markOverlayWindow } from "../electron/overlayWindows.ts";
import * as DesktopTelemetryPublisher from "../telemetry/DesktopTelemetryPublisher.ts";
import { glideKeyframes, planGlide, sampleGlide, type Glide, type Point } from "./cursorMotion.ts";
import { OVERLAY_HTML } from "./overlayPage.ts";

/** A cursor stays between the actions of one task and fades after this long idle. */
const IDLE_MS = 8_000;
const FADE_MS = 300;
/** Where a cursor enters from (relative to its first target) the first time it appears. */
const ENTRY_OFFSET = { x: 140, y: 110 };
/** Room around a path for the arrow, tags, and ripple when picking displays. */
const MARGIN = 120;
const TONES = 4;

type Overlay = { readonly window: Electron.BrowserWindow; readonly loaded: Promise<void> };
type Cursor = {
  glide: { readonly path: Glide; readonly startedAt: number } | undefined;
  visible: boolean;
  home: number | undefined;
  idleFiber: Fiber.Fiber<void> | undefined;
  readonly name: string;
  readonly tag: string;
  readonly tone: number;
};

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
  markOverlayWindow(window);
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
/** A JavaScript string literal for page calls; anything unusual is \u-escaped. */
const quote = (value: string) =>
  `"${value.replace(/[^\w .:-]/g, (char) => `\\u${char.charCodeAt(0).toString(16).padStart(4, "0")}`)}"`;

/**
 * Draws agent computer-use cursors in click-through, non-focusable overlays,
 * one window per display a cursor travels across and one cursor per agent.
 * Background accessibility actions never move the user's mouse, so this is how
 * the user sees where each agent is working. Motion runs as compositor
 * animations; an idle cursor costs nothing.
 */
export const listen: Effect.Effect<
  void,
  never,
  DesktopTelemetryPublisher.DesktopTelemetryPublisher | Scope.Scope
> = Effect.gen(function* () {
  const publisher = yield* DesktopTelemetryPublisher.DesktopTelemetryPublisher;
  const overlays = new Map<number, Overlay>();
  const cursors = new Map<string, Cursor>();

  // Follow display geometry and scale changes; windows re-render at the new
  // scale on their own. Overlays for new displays are created on first use.
  const onDisplayRemoved = (_event: unknown, display: Electron.Display) => {
    const overlay = overlays.get(display.id);
    if (overlay && !overlay.window.isDestroyed()) overlay.window.destroy();
    overlays.delete(display.id);
  };
  const onDisplayChanged = (_event: unknown, display: Electron.Display) => {
    const overlay = overlays.get(display.id);
    if (overlay && !overlay.window.isDestroyed()) overlay.window.setBounds(display.bounds);
  };
  Electron.screen.on("display-removed", onDisplayRemoved);
  Electron.screen.on("display-metrics-changed", onDisplayChanged);

  const overlayFor = (display: Electron.Display) => {
    const existing = overlays.get(display.id);
    if (existing && !existing.window.isDestroyed()) return existing;
    const created = createOverlay(display.bounds);
    overlays.set(display.id, created);
    return created;
  };
  /** Hide overlay windows that no visible cursor rests on. */
  const hideIdleWindows = () => {
    const needed = new Set<number>();
    for (const cursor of cursors.values())
      if (cursor.visible && cursor.home !== undefined) needed.add(cursor.home);
    for (const [id, overlay] of overlays)
      if (!needed.has(id) && !overlay.window.isDestroyed()) overlay.window.hide();
  };

  /** Agents with the same name get numbered tags; visible cursors get distinct tag colors. */
  const cursorFor = (id: string, name: string): Cursor => {
    const existing = cursors.get(id);
    if (existing && existing.name === name) return existing;
    const others = [...cursors.entries()].filter(([other]) => other !== id).map(([, c]) => c);
    const sameName = others.filter((other) => other.name === name).length;
    let tone = 0;
    while (tone < TONES && others.some((other) => other.visible && other.tone === tone)) tone += 1;
    const cursor: Cursor = {
      glide: existing?.glide,
      visible: existing?.visible ?? false,
      home: existing?.home,
      idleFiber: existing?.idleFiber,
      name,
      tag: sameName === 0 ? name : `${name} ${sameName + 1}`,
      tone: tone % TONES,
    };
    cursors.set(id, cursor);
    return cursor;
  };

  const show = (request: DesktopTelemetryShowComputerCursor) =>
    Effect.gen(function* () {
      const id = request.cursorId ?? "agent";
      const cursor = cursorFor(id, request.label ?? "Agent");
      const now = yield* Clock.currentTimeMillis;
      const target = { x: request.x, y: request.y };
      let from: Point;
      let velocity: Point | undefined;
      if (cursor.glide && cursor.visible) {
        // Continue from wherever the cursor is right now, at its current speed.
        const sample = sampleGlide(cursor.glide.path, now - cursor.glide.startedAt);
        from = sample.position;
        velocity = sample.velocity;
      } else if (cursor.glide) {
        from = cursor.glide.path.to;
      } else {
        from = { x: target.x + ENTRY_OFFSET.x, y: target.y + ENTRY_OFFSET.y };
      }
      const durationMs =
        request.durationMs ??
        computerCursorGlideMs(Math.hypot(target.x - from.x, target.y - from.y));
      const path = planGlide(from, target, durationMs, velocity);
      cursor.glide = { path, startedAt: now };
      cursor.visible = true;
      const frames = glideKeyframes(path);
      const box = {
        minX: Math.min(...frames.map((p) => p.x)) - MARGIN,
        minY: Math.min(...frames.map((p) => p.y)) - MARGIN,
        maxX: Math.max(...frames.map((p) => p.x)) + MARGIN,
        maxY: Math.max(...frames.map((p) => p.y)) + MARGIN,
      };
      yield* Effect.forEach(
        Electron.screen.getAllDisplays().filter((display) => intersects(box, display.bounds)),
        (display) =>
          Effect.gen(function* () {
            const overlay = overlayFor(display);
            const origin = display.bounds;
            // Numbers, a schema literal, and quoted strings only.
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
                `glide(${quote(id)},[${local}],${Math.round(durationMs)},${cue},${bounds},${quote(cursor.tag)},${cursor.tone})`,
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

      if (cursor.idleFiber) yield* Fiber.interrupt(cursor.idleFiber);
      cursor.idleFiber = yield* Effect.gen(function* () {
        // Once arrived, drop overlays on displays cursors only passed through.
        yield* Effect.sleep(durationMs + 50);
        cursor.home = Electron.screen.getDisplayNearestPoint({
          x: Math.round(target.x),
          y: Math.round(target.y),
        }).id;
        hideIdleWindows();
        yield* Effect.sleep(IDLE_MS);
        cursor.visible = false;
        for (const overlay of overlays.values())
          if (!overlay.window.isDestroyed())
            yield* Effect.promise(() =>
              overlay.window.webContents
                .executeJavaScript(`fadeOut(${quote(id)})`)
                .catch(() => undefined),
            );
        yield* Effect.sleep(FADE_MS);
        hideIdleWindows();
      }).pipe(Effect.forkScoped);
    });

  yield* Stream.runForEach(publisher.computerCursorRequests, show).pipe(Effect.forkScoped);

  yield* Effect.addFinalizer(() =>
    Effect.sync(() => {
      Electron.screen.off("display-removed", onDisplayRemoved);
      Electron.screen.off("display-metrics-changed", onDisplayChanged);
      for (const { window } of overlays.values()) if (!window.isDestroyed()) window.destroy();
      overlays.clear();
    }),
  );
});
