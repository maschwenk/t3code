import { computerCursorGlideMs, ProviderInstanceId } from "@t3tools/contracts";
import * as Clock from "effect/Clock";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";

import * as ProviderInstanceRegistry from "../provider/ProviderInstanceRegistry.ts";
import * as DesktopTelemetryReceiver from "../resourceTelemetry/DesktopTelemetryReceiver.ts";
import type { ComputerAction, ElementTarget, NativeSnapshot } from "./protocol.ts";

type Bounds = NonNullable<ElementTarget["bounds"]>;
type Point = { readonly x: number; readonly y: number };

/** Matches the desktop overlay's idle fade, after which a cursor re-enters. */
const PRESENT_MS = 8_000;
const MAX_TRACKED = 32;

// xa11y's snake_case roles, as snapshots report them.
const MENU_ROLES = new Set(["menu_button", "pop_up_button", "menu_bar_item", "combo_box"]);
/** The feedback the agent cursor plays for an action. */
export const cursorCue = (action: ComputerAction, role: string) => {
  switch (action.kind) {
    case "move":
    case "wait":
      return "point";
    case "type":
    case "key":
      return "type";
    case "menu":
      return "menu";
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

const hasArea = (bounds: ElementTarget["bounds"]): bounds is Bounds =>
  bounds !== null && bounds.width > 0 && bounds.height > 0;
const contains = (bounds: Bounds, point: Point) =>
  point.x >= bounds.x &&
  point.x <= bounds.x + bounds.width &&
  point.y >= bounds.y &&
  point.y <= bounds.y + bounds.height;

/**
 * Where the cursor goes when an agent looks at an app: the middle of the
 * window's title area. Undefined when the snapshot has no window frame (for
 * example a query or subtree snapshot).
 */
export const lookTarget = (snapshot: Pick<NativeSnapshot, "elements">) => {
  const window = snapshot.elements.find(
    (element) => element.role === "window" && hasArea(element.bounds),
  )?.bounds;
  if (!window) return undefined;
  return {
    window,
    point: { x: window.x + window.width / 2, y: window.y + Math.min(14, window.height / 2) },
  };
};

const KNOWN_PROVIDERS: ReadonlyArray<readonly [string, string]> = [
  ["claude", "Claude"],
  ["codex", "Codex"],
  ["cursor", "Cursor"],
  ["opencode", "OpenCode"],
  ["grok", "Grok"],
  ["antigravity", "Antigravity"],
];
/** A readable agent name from a provider instance or driver id, for when no display name is known. */
export const fallbackAgentName = (id: string) =>
  KNOWN_PROVIDERS.find(([needle]) => id.toLowerCase().includes(needle))?.[1] ?? (id || "Agent");

/**
 * Signals the desktop agent cursor for computer use: one cursor per caller
 * (environment, thread, provider instance and session), tagged with the
 * provider's name. Callers that use this must already hold the computer-use
 * lock, so glides never interleave.
 */
export const make = Effect.gen(function* () {
  const desktop = yield* DesktopTelemetryReceiver.DesktopTelemetryReceiver;
  const registry = yield* Effect.serviceOption(ProviderInstanceRegistry.ProviderInstanceRegistry);
  const last = new Map<string, { readonly point: Point; readonly at: number }>();
  const names = new Map<string, string>();

  const agentName = (caller: string) =>
    Effect.gen(function* () {
      // caller = environmentId:threadId:providerInstanceId:providerSessionId
      const instanceId = caller.split(":")[2] ?? "";
      const cached = names.get(instanceId);
      if (cached) return cached;
      let name: string | undefined;
      if (Option.isSome(registry) && instanceId) {
        const instance = yield* registry.value.getInstance(ProviderInstanceId.make(instanceId));
        if (instance) {
          const snapshot = yield* instance.snapshot.getSnapshot;
          name =
            instance.displayName ??
            snapshot.displayName ??
            fallbackAgentName(String(instance.driverKind));
        }
      }
      const resolved = name ?? fallbackAgentName(instanceId);
      names.set(instanceId, resolved);
      return resolved;
    }).pipe(Effect.catchCause(() => Effect.succeed(fallbackAgentName(""))));

  const send = (
    caller: string,
    point: Point,
    cursor: { readonly cue: ReturnType<typeof cursorCue> | "look"; readonly bounds: Bounds },
  ) =>
    Effect.gen(function* () {
      const now = yield* Clock.currentTimeMillis;
      const previous = last.get(caller);
      const from = previous?.point ?? { x: point.x + 140, y: point.y + 110 };
      const durationMs = computerCursorGlideMs(Math.hypot(point.x - from.x, point.y - from.y));
      const shown = yield* desktop.showComputerCursor({
        ...point,
        ...cursor,
        durationMs,
        cursorId: caller,
        label: yield* agentName(caller),
      });
      last.delete(caller);
      last.set(caller, { point, at: now });
      for (const key of last.keys()) {
        if (last.size <= MAX_TRACKED) break;
        last.delete(key);
      }
      return shown ? durationMs : undefined;
    });

  return {
    /** Glides to an action's target and waits for it to land, so the user sees where the agent acts first. */
    point: (caller: string, action: ComputerAction, target: ElementTarget) =>
      Effect.gen(function* () {
        if (!hasArea(target.bounds)) return;
        const bounds = target.bounds;
        const center = { x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2 };
        const durationMs = yield* send(caller, center, {
          cue: cursorCue(action, target.role),
          bounds,
        });
        if (durationMs !== undefined) yield* Effect.sleep(durationMs + 60);
      }),
    /**
     * Moves to the app window when the agent observes it, without waiting.
     * Skipped while this agent's cursor is already working inside that window.
     */
    look: (caller: string, snapshot: Pick<NativeSnapshot, "elements">) =>
      Effect.gen(function* () {
        const target = lookTarget(snapshot);
        if (!target) return;
        const previous = last.get(caller);
        const now = yield* Clock.currentTimeMillis;
        if (previous && now - previous.at < PRESENT_MS && contains(target.window, previous.point))
          return;
        yield* send(caller, target.point, { cue: "look", bounds: target.window });
      }),
  };
});
