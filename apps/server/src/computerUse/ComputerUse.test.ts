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

it("plans coordinate steps and drags only from a capture and one source", () => {
  const seven = snapshot.elements[0]!;
  const elements = [seven, { ...seven, ref: 2, name: "8", stableId: "eight" }];
  const capture = {
    window: { id: 5, bounds: { x: 100, y: 50, width: 400, height: 300 } },
    width: 800,
    height: 600,
  };
  const click = { kind: "click_at", x: 400, y: 300, button: "left", count: 2 } as const;
  expect(ComputerUse.planStep(elements, capture, { action: click })).toMatchObject({
    target: null,
    screen: { window: capture.window, to: { x: 300, y: 200 } },
  });
  expect(ComputerUse.planStep(elements, undefined, { action: click })).toBe("invalid_point");
  expect(ComputerUse.planStep(elements, capture, { action: { ...click, x: 800 } })).toBe(
    "invalid_point",
  );
  expect(ComputerUse.planStep(elements, capture, { ref: 1, action: click })).toBe("invalid_input");

  const drag = (to: object, from?: object) =>
    ({ kind: "drag", to, ...(from ? { from } : {}) }) as never;
  expect(
    ComputerUse.planStep(elements, undefined, { ref: 1, action: drag({ name: "8" }) }),
  ).toMatchObject({
    target: { ref: 1 },
    drop: { ref: 2 },
  });
  expect(
    ComputerUse.planStep(elements, capture, { action: drag({ x: 0, y: 0 }, { x: 798, y: 2 }) }),
  ).toMatchObject({ screen: { from: { x: 499, y: 51 }, to: { x: 100, y: 50 } } });
  expect(ComputerUse.planStep(elements, capture, { action: drag({ ref: 2 }) })).toBe("invalid_ref");
  expect(
    ComputerUse.planStep(elements, capture, { ref: 1, action: drag({ ref: 2 }, { x: 1, y: 1 }) }),
  ).toBe("invalid_input");
  expect(ComputerUse.planStep(elements, capture, { ref: 1, action: drag({ ref: 9 }) })).toBe(
    "invalid_ref",
  );
  expect(ComputerUse.planStep(elements, undefined, { ref: 1, action: drag({ x: 1, y: 1 }) })).toBe(
    "invalid_point",
  );
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

it.effect("aims coordinate steps at the latest capture, even after text-only snapshots", () => {
  const calls: WorkerRequest[] = [];
  const window = { id: 77, bounds: { x: 200, y: 100, width: 300, height: 200 } };
  const layer = ComputerUse.layer.pipe(
    Layer.provide(
      Layer.succeed(Driver.Driver, {
        execute: (request) =>
          Effect.sync(() => {
            calls.push(request);
            if (request.kind !== "snapshot") return { ok: true as const, via: "takeover" as const };
            return {
              ok: true as const,
              snapshot: request.includeImage
                ? {
                    ...snapshot,
                    image: {
                      data: "",
                      mimeType: "image/png" as const,
                      width: 600,
                      height: 400,
                      window,
                    },
                  }
                : snapshot,
            };
          }),
      }),
    ),
    Layer.provide(DesktopTelemetryReceiver.layerTest()),
    Layer.provideMerge(
      ServerSettings.layerTest({
        enableAgentComputerAccess: true,
        enableComputerScreenCapture: true,
        computerUseAllowedApps: ["Calculator"],
      }),
    ),
    Layer.provide(NodeServices.layer),
  );
  return Effect.gen(function* () {
    const computer = yield* ComputerUse.ComputerUse;
    const settings = yield* ServerSettings.ServerSettingsService;
    const click = {
      kind: "click_at" as const,
      x: 300,
      y: 200,
      button: "left" as const,
      count: 1 as const,
    };
    const textOnly = yield* computer.snapshot("a", { app: "Calculator", includeImage: false });
    expect(
      yield* code(
        computer.act("a", { snapshotId: textOnly.snapshotId, steps: [{ action: click }] }),
      ),
    ).toBe("invalid_point");
    yield* computer.snapshot("a", { app: "Calculator", includeImage: true });
    const later = yield* computer.snapshot("a", { app: "Calculator", includeImage: false });
    const first = yield* computer.act("a", {
      snapshotId: later.snapshotId,
      steps: [{ action: click }],
    });
    expect(first.completed).toEqual(["takeover"]);
    yield* settings.updateSettings({ enableComputerPointerTakeover: false });
    // The snapshot an action returns keeps the capture too.
    yield* computer.act("a", {
      snapshotId: first.snapshot!.snapshotId,
      steps: [{ action: click }],
    });
    const actions = calls.filter((call) => call.kind === "action");
    expect(actions.map((call) => [call.screen, call.takeover])).toEqual([
      [{ window, to: { x: 350, y: 200 } }, true],
      [{ window, to: { x: 350, y: 200 } }, false],
    ]);
  }).pipe(Effect.provide(layer));
});

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

it.effect("stops a batch when computer use is turned off while it runs", () => {
  const calls: WorkerRequest[] = [];
  // The user turns computer use off while the first step's native work runs.
  const layer = ComputerUse.layer.pipe(
    Layer.provide(
      Layer.effect(
        Driver.Driver,
        Effect.gen(function* () {
          const settings = yield* ServerSettings.ServerSettingsService;
          return {
            execute: (request: WorkerRequest) =>
              Effect.gen(function* () {
                calls.push(request);
                if (request.kind === "snapshot") return { ok: true as const, snapshot };
                yield* settings
                  .updateSettings({ enableAgentComputerAccess: false })
                  .pipe(Effect.orDie);
                return { ok: true as const };
              }),
          };
        }),
      ),
    ),
    Layer.provide(DesktopTelemetryReceiver.layerTest()),
    Layer.provideMerge(
      ServerSettings.layerTest({
        enableAgentComputerAccess: true,
        computerUseAllowedApps: ["Calculator"],
      }),
    ),
    Layer.provide(NodeServices.layer),
  );
  return Effect.gen(function* () {
    const computer = yield* ComputerUse.ComputerUse;
    const shot = yield* computer.snapshot("a", { app: "Calculator", includeImage: false });
    const press = { ref: 1, action: { kind: "press" as const } };
    const result = yield* computer.act("a", { snapshotId: shot.snapshotId, steps: [press, press] });
    expect(result.completed).toEqual(["accessibility"]);
    expect(result.error?.code).toBe("disabled");
    expect(result.snapshotError?.code).toBe("disabled");
    expect(calls.filter((call) => call.kind === "action")).toHaveLength(1);
  }).pipe(Effect.provide(layer));
});

it.effect("expires snapshots and invalidates all observations after an uncertain action", () => {
  const calls: WorkerRequest[] = [];
  return Effect.gen(function* () {
    const computer = yield* ComputerUse.ComputerUse;
    const old = yield* computer.snapshot("a", { app: "Calculator", includeImage: false });
    yield* TestClock.adjust("601 seconds");
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
