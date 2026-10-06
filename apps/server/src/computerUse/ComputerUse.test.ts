import { expect, it } from "@effect/vitest";
import * as NodeServices from "@effect/platform-node/NodeServices";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as TestClock from "effect/testing/TestClock";
import * as ComputerUse from "./ComputerUse.ts";
import * as Driver from "./Driver.ts";
import * as DesktopTelemetryReceiver from "../resourceTelemetry/DesktopTelemetryReceiver.ts";
import * as ServerSettings from "../serverSettings.ts";
import { type WorkerRequest, ComputerUseError, type NativeSnapshot } from "./protocol.ts";

const snapshot: NativeSnapshot = {
  app: "Calculator",
  pid: 42,
  truncated: false,
  elements: [
    {
      ref: 1,
      role: "button",
      name: "7",
      value: null,
      enabled: true,
      editable: false,
      actions: ["press"],
      path: [0, 0],
      stableId: "seven",
      bounds: { x: 0, y: 0, width: 30, height: 30 },
      description: null,
      states: [],
      depth: 1,
    },
  ],
  offscreen: 0,
  frontmost: false,
};
// Only the OS boundary is substituted. Authorization, settings writes, receipt
// ownership, expiry and one-shot mutation behavior run through real services.

it("targets steps by exact name only when the name picks one element", () => {
  const seven = snapshot.elements[0]!;
  const elements = [
    seven,
    { ...seven, ref: 11, name: "1", stableId: "one" },
    { ...seven, ref: 12, role: "static_text", name: "1", actions: [], stableId: null },
  ];
  expect(ComputerUse.resolveStepTarget(elements, { name: "7" })?.ref).toBe(1);
  expect(ComputerUse.resolveStepTarget(elements, { name: "1" })).toBeUndefined();
  expect(ComputerUse.resolveStepTarget(elements, { name: "1", role: "button" })?.ref).toBe(11);
  expect(ComputerUse.resolveStepTarget(elements, { name: "9" })).toBeUndefined();
  expect(ComputerUse.resolveStepTarget(elements, { ref: 12, name: "7" })?.ref).toBe(12);
});
const setup = (calls: WorkerRequest[], enabled = true, failAction = false) =>
  ComputerUse.layer.pipe(
    Layer.provide(
      Layer.succeed(Driver.Driver, {
        execute: (request) =>
          Effect.sync(() => {
            calls.push(request);
            return request.kind === "snapshot"
              ? { ok: true as const, snapshot }
              : failAction
                ? { ok: false as const, code: "failed" as const }
                : { ok: true as const };
          }),
      }),
    ),
    Layer.provide(DesktopTelemetryReceiver.layerTest()),
    Layer.provideMerge(
      ServerSettings.layerTest({
        enableAgentComputerAccess: enabled,
        computerUseAllowedApps: ["Calculator"],
      }),
    ),
    Layer.provide(NodeServices.layer),
  );
const code = <A>(effect: Effect.Effect<A, ComputerUseError>) =>
  effect.pipe(Effect.match({ onSuccess: () => "success", onFailure: (error) => error.code }));

it.effect("blocks native work until enabled, including screen capture's separate grant", () => {
  const calls: WorkerRequest[] = [];
  return Effect.gen(function* () {
    const computer = yield* ComputerUse.ComputerUse;
    const settings = yield* ServerSettings.ServerSettingsService;
    expect(yield* code(computer.snapshot("a", { app: "Calculator", includeImage: false }))).toBe(
      "disabled",
    );
    yield* settings.updateSettings({ enableAgentComputerAccess: true });
    expect(yield* code(computer.snapshot("a", { app: "Terminal", includeImage: false }))).toBe(
      "app_denied",
    );
    expect(yield* code(computer.snapshot("a", { app: "Calculator", includeImage: true }))).toBe(
      "capture_denied",
    );
    expect(calls).toHaveLength(0);
  }).pipe(Effect.provide(setup(calls, false)));
});

it.effect("keeps refs within the issuing provider session and consumes writes exactly once", () => {
  const calls: WorkerRequest[] = [];
  return Effect.gen(function* () {
    const computer = yield* ComputerUse.ComputerUse;
    const shot = yield* computer.snapshot("claude-personal", {
      app: "Calculator",
      includeImage: false,
    });
    const press = { ref: 1, action: { kind: "press" as const } };
    const action = { snapshotId: shot.snapshotId, steps: [press] };
    expect(yield* code(computer.act("claude-work", action))).toBe("snapshot_expired");
    // One unknown ref rejects the whole batch before anything runs.
    expect(
      yield* code(
        computer.act("claude-personal", { ...action, steps: [press, { ...press, ref: 9 }] }),
      ),
    ).toBe("invalid_ref");
    expect(
      yield* code(
        computer.act("claude-personal", { ...action, steps: [{ action: { kind: "press" } }] }),
      ),
    ).toBe("invalid_ref");
    const result = yield* computer.act("claude-personal", action);
    expect(result.completed).toEqual(["accessibility"]);
    // The action returns a fresh observation; the one it acted on is spent.
    expect(result.snapshot?.snapshotId).not.toBe(shot.snapshotId);
    expect(yield* code(computer.act("claude-personal", action))).toBe("snapshot_expired");
    expect(calls.filter((call) => call.kind === "action")).toHaveLength(1);
  }).pipe(Effect.provide(setup(calls)));
});

it.effect("checks live settings before an existing session can act", () => {
  const calls: WorkerRequest[] = [];
  return Effect.gen(function* () {
    const computer = yield* ComputerUse.ComputerUse;
    const settings = yield* ServerSettings.ServerSettingsService;
    const shot = yield* computer.snapshot("a", { app: "Calculator", includeImage: false });
    yield* settings.updateSettings({ computerUseAllowedApps: [] });
    const action = {
      snapshotId: shot.snapshotId,
      steps: [{ ref: 1, action: { kind: "press" as const } }],
    };
    expect(yield* code(computer.act("a", action))).toBe("app_denied");
    yield* settings.updateSettings({
      computerUseAllowedApps: ["Calculator"],
      enableAgentComputerAccess: false,
    });
    expect(yield* code(computer.act("a", action))).toBe("disabled");
    expect(calls.filter((call) => call.kind === "action")).toHaveLength(0);
  }).pipe(Effect.provide(setup(calls)));
});

it.effect("expires snapshots and invalidates all observations after an uncertain action", () => {
  const calls: WorkerRequest[] = [];
  return Effect.gen(function* () {
    const computer = yield* ComputerUse.ComputerUse;
    const old = yield* computer.snapshot("a", { app: "Calculator", includeImage: false });
    yield* TestClock.adjust("121 seconds");
    expect(
      yield* code(
        computer.act("a", {
          snapshotId: old.snapshotId,
          steps: [{ ref: 1, action: { kind: "press" } }],
        }),
      ),
    ).toBe("snapshot_expired");
    const first = yield* computer.snapshot("a", { app: "Calculator", includeImage: false });
    const second = yield* computer.snapshot("b", { app: "Calculator", includeImage: false });
    const failed = yield* computer.act("a", {
      snapshotId: first.snapshotId,
      steps: [
        { ref: 1, action: { kind: "press" } },
        { ref: 1, action: { kind: "press" } },
      ],
    });
    // The batch stops at the uncertain step and never replays or continues it.
    expect(failed.error?.code).toBe("failed");
    expect(failed.completed).toEqual([]);
    expect(
      yield* code(
        computer.act("b", {
          snapshotId: second.snapshotId,
          steps: [{ ref: 1, action: { kind: "press" } }],
        }),
      ),
    ).toBe("snapshot_expired");
    expect(calls.filter((call) => call.kind === "action")).toHaveLength(1);
  }).pipe(Effect.provide(setup(calls, true, true)));
});
