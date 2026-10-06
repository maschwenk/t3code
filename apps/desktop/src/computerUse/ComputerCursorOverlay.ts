import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import type * as Scope from "effect/Scope";
import * as Stream from "effect/Stream";
import * as Electron from "electron";

import * as DesktopTelemetryPublisher from "../telemetry/DesktopTelemetryPublisher.ts";

const HIDE_AFTER_MS = 2_500;

// The pointer matches the browser panel's MousePointer2 agent cursor. Its tip
// sits on the target point; the ring marks where the agent acts.
const OVERLAY_HTML = `<!doctype html><style>
html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}
#cursor{position:absolute;left:0;top:0;filter:drop-shadow(0 1px 3px rgba(0,0,0,.35));transition:transform 260ms cubic-bezier(.2,.8,.2,1);will-change:transform}
#ring{position:absolute;left:-14px;top:-14px;width:28px;height:28px;box-sizing:border-box;border-radius:50%;border:2px solid #2563eb;opacity:0}
@media (prefers-reduced-motion:reduce){#cursor{transition:none}}
</style><div id="cursor"><div id="ring"></div><svg xmlns="http://www.w3.org/2000/svg" width="28" height="28" viewBox="0 0 24 24" fill="white" stroke="#2563eb" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="position:absolute;left:-5px;top:-5px"><path d="M4.037 4.688a.495.495 0 0 1 .651-.651l16 6.5a.5.5 0 0 1-.063.947l-6.124 1.58a2 2 0 0 0-1.438 1.435l-1.579 6.126a.5.5 0 0 1-.947.063z"/></svg></div><script>
const cursor=document.getElementById("cursor"),ring=document.getElementById("ring");
window.pointAt=(x,y,jump)=>{
  if(jump)cursor.style.transition="none";
  cursor.style.transform="translate("+x+"px,"+y+"px)";
  if(jump){cursor.getBoundingClientRect();cursor.style.transition=""}
  ring.animate([{transform:"scale(.4)",opacity:.9},{transform:"scale(1.6)",opacity:0}],{duration:420,delay:jump?0:260,easing:"ease-out"});
};
</script>`;

const sameBounds = (a: Electron.Rectangle, b: Electron.Rectangle) =>
  a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height;

function createOverlay(bounds: Electron.Rectangle): Electron.BrowserWindow {
  const window = new Electron.BrowserWindow({
    ...bounds,
    alwaysOnTop: true,
    backgroundColor: "#00000000",
    enableLargerThanScreen: true,
    focusable: false,
    frame: false,
    hasShadow: false,
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
    },
  });
  window.setAlwaysOnTop(true, "screen-saver");
  window.setVisibleOnAllWorkspaces(true, {
    visibleOnFullScreen: true,
    skipTransformProcessType: true,
  });
  window.setIgnoreMouseEvents(true);
  return window;
}

/**
 * Draws the agent's computer-use cursor in a click-through, non-focusable
 * overlay. Background accessibility actions never move the user's mouse, so
 * this is how the user sees where the agent is working.
 */
export const listen: Effect.Effect<
  void,
  never,
  DesktopTelemetryPublisher.DesktopTelemetryPublisher | Scope.Scope
> = Effect.gen(function* () {
  const publisher = yield* DesktopTelemetryPublisher.DesktopTelemetryPublisher;
  let overlay: Electron.BrowserWindow | undefined;
  let loaded: Promise<void> = Promise.resolve();
  let hideFiber: Fiber.Fiber<void> | undefined;

  const show = (x: number, y: number) =>
    Effect.gen(function* () {
      const bounds = Electron.screen.getDisplayNearestPoint({
        x: Math.round(x),
        y: Math.round(y),
      }).bounds;
      if (!overlay || overlay.isDestroyed()) {
        overlay = createOverlay(bounds);
        loaded = overlay.loadURL(
          `data:text/html;charset=utf-8,${encodeURIComponent(OVERLAY_HTML)}`,
        );
      }
      const current = overlay;
      const moved = !sameBounds(current.getBounds(), bounds);
      if (moved) current.setBounds(bounds);
      const jump = moved || !current.isVisible();
      yield* Effect.tryPromise(() => loaded);
      yield* Effect.tryPromise(() =>
        current.webContents.executeJavaScript(`pointAt(${x - bounds.x},${y - bounds.y},${jump})`),
      );
      current.showInactive();
      if (hideFiber) yield* Fiber.interrupt(hideFiber);
      hideFiber = yield* Effect.sleep(HIDE_AFTER_MS).pipe(
        Effect.andThen(
          Effect.sync(() => {
            if (!current.isDestroyed()) current.hide();
          }),
        ),
        Effect.forkScoped,
      );
    });

  yield* Stream.runForEach(publisher.computerCursorRequests, (request) =>
    show(request.x, request.y).pipe(
      Effect.catchCause((cause) =>
        Effect.logWarning("computer cursor overlay failed", { cause: String(cause) }),
      ),
    ),
  ).pipe(Effect.forkScoped);

  yield* Effect.addFinalizer(() =>
    Effect.sync(() => {
      if (overlay && !overlay.isDestroyed()) overlay.destroy();
    }),
  );
});
