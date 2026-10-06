import { computerCursorGlideMs } from "@t3tools/contracts";
import * as Clock from "effect/Clock";
import * as Context from "effect/Context";
import * as Crypto from "effect/Crypto";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Semaphore from "effect/Semaphore";
import * as DesktopTelemetryReceiver from "../resourceTelemetry/DesktopTelemetryReceiver.ts";
import * as ServerSettings from "../serverSettings.ts";
import * as Driver from "./Driver.ts";
import {
  ComputerUseError,
  type ComputerAction,
  type NativeSnapshot,
  type WorkerRequest,
} from "./protocol.ts";

type Receipt = { readonly at: number; readonly caller: string; readonly snapshot: NativeSnapshot };

const MENU_ROLES = new Set(["AXMenuButton", "AXPopUpButton", "AXMenuBarItem", "AXComboBox"]);
/** The feedback the agent cursor plays for an action. */
const cursorCue = (action: ComputerAction, role: string) => {
  switch (action.kind) {
    case "move":
      return "point";
    case "type":
      return "type";
    case "click":
      if (action.button === "right") return "rightClick";
      return action.count === 2 ? "doubleClick" : "click";
    case "scroll":
      if (Math.abs(action.dx) > Math.abs(action.dy))
        return action.dx < 0 ? "scrollLeft" : "scrollRight";
      return action.dy < 0 ? "scrollUp" : "scrollDown";
    case "perform": {
      const name = action.action.toLowerCase();
      if (name.includes("menu")) return "menu";
      for (const direction of ["Up", "Down", "Left", "Right"] as const)
        if (name.includes(`scroll_${direction.toLowerCase()}`))
          return `scroll${direction}` as const;
      return MENU_ROLES.has(role) ? "menu" : "click";
    }
    case "press":
      return MENU_ROLES.has(role) ? "menu" : "click";
  }
};
export class ComputerUse extends Context.Service<
  ComputerUse,
  {
    readonly status: Effect.Effect<
      { enabled: boolean; allowedApps: readonly string[]; screenCaptureEnabled: boolean },
      ComputerUseError
    >;
    readonly snapshot: (
      caller: string,
      input: { app: string; includeImage: boolean },
    ) => Effect.Effect<NativeSnapshot & { snapshotId: string }, ComputerUseError>;
    readonly act: (
      caller: string,
      input: { snapshotId: string; ref: number; action: ComputerAction },
    ) => Effect.Effect<void, ComputerUseError>;
  }
>()("t3/computerUse/ComputerUse") {}

const make = Effect.gen(function* () {
  const settings = yield* ServerSettings.ServerSettingsService;
  const driver = yield* Driver.Driver;
  const desktop = yield* DesktopTelemetryReceiver.DesktopTelemetryReceiver;
  const crypto = yield* Crypto.Crypto;
  const mutex = yield* Semaphore.make(1);
  const receipts = new Map<string, Receipt>();
  const fail = (code: ComputerUseError["code"]) => new ComputerUseError({ code });
  const execute = (request: WorkerRequest) =>
    driver.execute(request).pipe(
      Effect.flatMap((result) =>
        result.ok
          ? Effect.succeed(result)
          : Effect.fail(
              new ComputerUseError({
                code: result.code,
                ...("detail" in result ? { detail: result.detail } : {}),
              }),
            ),
      ),
    );
  const status = settings.getSettings.pipe(
    Effect.map((current) => ({
      enabled: current.enableAgentComputerAccess,
      allowedApps: current.computerUseAllowedApps,
      screenCaptureEnabled: current.enableComputerScreenCapture,
    })),
    Effect.mapError((cause) => new ComputerUseError({ code: "disabled", cause })),
  );
  const authorized = <A>(
    app: string,
    includeImage: boolean,
    work: Effect.Effect<A, ComputerUseError>,
  ) =>
    settings
      .withSettingsSnapshot((current) =>
        Effect.gen(function* () {
          if (!current.enableAgentComputerAccess) {
            receipts.clear();
            return yield* fail("disabled");
          }
          if (!current.computerUseAllowedApps.includes(app)) return yield* fail("app_denied");
          if (includeImage && !current.enableComputerScreenCapture)
            return yield* fail("capture_denied");
          return yield* work;
        }),
      )
      .pipe(
        Effect.mapError((cause) =>
          cause._tag === "ComputerUseError"
            ? cause
            : new ComputerUseError({ code: "disabled", cause }),
        ),
      );

  const snapshot: ComputerUse["Service"]["snapshot"] = (caller, input) =>
    mutex.withPermits(1)(
      authorized(
        input.app,
        input.includeImage,
        Effect.gen(function* () {
          // A failed refresh must not leave an older observation usable.
          for (const [id, receipt] of receipts) if (receipt.caller === caller) receipts.delete(id);
          const result = yield* execute({ kind: "snapshot", ...input });
          if (!result.snapshot) return yield* fail("failed");
          const at = yield* Clock.currentTimeMillis;
          for (const [id, receipt] of receipts)
            if (at - receipt.at > 120_000 || receipt.caller === caller) receipts.delete(id);
          const oldest = receipts.keys().next().value;
          if (receipts.size >= 32 && oldest !== undefined) receipts.delete(oldest);
          const snapshotId = yield* crypto.randomUUIDv4.pipe(
            Effect.mapError((cause) => new ComputerUseError({ code: "failed", cause })),
          );
          // Images live only in the tool response, never in the receipt cache.
          const { image: _image, ...remembered } = result.snapshot;
          receipts.set(snapshotId, { at, caller, snapshot: remembered });
          return { ...result.snapshot, snapshotId };
        }),
      ),
    );

  // Where the agent cursor was last sent; its next glide starts there.
  let lastCursor: { x: number; y: number } | undefined;

  const act: ComputerUse["Service"]["act"] = (caller, input) =>
    mutex.withPermits(1)(
      Effect.gen(function* () {
        const receipt = receipts.get(input.snapshotId);
        const now = yield* Clock.currentTimeMillis;
        if (!receipt || receipt.caller !== caller || now - receipt.at > 120_000)
          return yield* fail("snapshot_expired");
        const target = receipt.snapshot.elements.find((element) => element.ref === input.ref);
        if (!target) return yield* fail("invalid_ref");
        return yield* authorized(
          receipt.snapshot.app,
          false,
          Effect.gen(function* () {
            // A failed/uncertain write is never replayed. An action also invalidates
            // other threads' observations of the same desktop.
            receipts.clear();
            const bounds = target.bounds;
            if (bounds && bounds.width > 0 && bounds.height > 0) {
              // The agent cursor glides from its last point; wait for it to land
              // so the user sees where the agent acts before it happens.
              const point = { x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2 };
              const from = lastCursor ?? { x: point.x + 140, y: point.y + 110 };
              const durationMs = computerCursorGlideMs(
                Math.hypot(point.x - from.x, point.y - from.y),
              );
              const shown = yield* desktop.showComputerCursor({
                ...point,
                durationMs,
                cue: cursorCue(input.action, target.role),
                bounds,
              });
              lastCursor = point;
              if (shown) yield* Effect.sleep(durationMs + 60);
            }
            yield* execute({
              kind: "action",
              app: receipt.snapshot.app,
              pid: receipt.snapshot.pid,
              target,
              action: input.action,
            });
          }),
        );
      }),
    );
  return ComputerUse.of({ status, snapshot, act });
});
export const layer = Layer.effect(ComputerUse, make);
