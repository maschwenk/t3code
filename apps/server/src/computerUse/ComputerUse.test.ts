import { expect, it } from "@effect/vitest";
import * as NodeCrypto from "@effect/platform-node/NodeCrypto";
import * as NodeServices from "@effect/platform-node/NodeServices";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Layer from "effect/Layer";
import * as TestClock from "effect/testing/TestClock";
import * as ComputerUse from "./ComputerUse.ts";
import * as Driver from "./Driver.ts";
import * as BrowserGoal from "../preview/BrowserGoal.ts";
import * as DesktopTelemetryReceiver from "../resourceTelemetry/DesktopTelemetryReceiver.ts";
import * as ServerSettings from "../serverSettings.ts";
import { backgroundAction } from "./nativeWorker.ts";
import type { Capture } from "./pointerTarget.ts";
import {
  type ComputerAction,
  type ComputerStep,
  type WorkerRequest,
  ComputerUseError,
  type NativeSnapshot,
} from "./protocol.ts";

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
const seven = snapshot.elements[0]!;

it("targets steps by exact name only when the name picks one element", () => {
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

const nameField = {
  ...seven,
  ref: 3,
  role: "text_field",
  name: "Name",
  actions: ["set_value"],
  editable: true,
  stableId: "name",
};
const capture = {
  window: { id: 5, bounds: { x: 100, y: 50, width: 400, height: 300 } },
  width: 800,
  height: 600,
};
const plan = (step: ComputerStep, latest: Capture | null = capture) =>
  ComputerUse.planStep(
    [seven, { ...seven, ref: 2, name: "8", stableId: "eight" }, nameField],
    latest ?? undefined,
    step,
  );
/** The accessibility action the worker runs instead of a posted click. */
const pressedAs = (planned: ReturnType<typeof plan>) =>
  typeof planned === "object" && "action" in planned && planned.action.kind === "click"
    ? backgroundAction(planned.action, planned.target?.actions ?? [])
    : undefined;

it("presses a clicked element that lists press, and clicks exactly at x, y", () => {
  expect(pressedAs(plan({ action: "click", name: "7" }))).toBe("press");
  // A double click needs pointer input.
  expect(pressedAs(plan({ action: "click", ref: 1, clickCount: 2 }))).toBeUndefined();
  expect(plan({ action: "click", x: 400, y: 300, button: "right" })).toEqual({
    action: { kind: "click_at", x: 400, y: 300, button: "right", count: 1 },
    target: null,
    screen: { window: capture.window, to: { x: 300, y: 200 } },
  });
  expect(plan({ action: "hover", x: 400, y: 300 })).toEqual({
    action: { kind: "move_at", x: 400, y: 300 },
    target: null,
    screen: { window: capture.window, to: { x: 300, y: 200 } },
  });
  expect(plan({ action: "click", x: 400, y: 300 }, null)).toBe("invalid_point");
  expect(plan({ action: "click", x: 800, y: 300 })).toBe("invalid_point");
});

it.each<[string, ComputerStep, ComputerAction]>([
  ["hover onto an element", { action: "hover", ref: 1 }, { kind: "move" }],
  ["type", { action: "type", ref: 3, text: "hi" }, { kind: "type", text: "hi", replace: false }],
  [
    "type into the focused element",
    { action: "type", text: "hi" },
    { kind: "type", text: "hi", replace: false },
  ],
  [
    "type with clear as a value replacement",
    { action: "type", name: "Name", text: "hi", clear: true },
    { kind: "type", text: "hi", replace: true },
  ],
  [
    "press as a key on the element",
    { action: "press", ref: 3, key: "Return" },
    { kind: "key", key: "Return" },
  ],
  [
    "press with modifiers as one chord",
    { action: "press", key: "t", modifiers: ["Meta", "Shift"], repeat: 2 },
    { kind: "key", key: "Meta+Shift+t", repeat: 2 },
  ],
  ["scroll", { action: "scroll", ref: 1, deltaY: 100 }, { kind: "scroll", dx: 0, dy: 100 }],
  [
    "perform",
    { action: "perform", ref: 1, perform: "raise" },
    { kind: "perform", action: "raise" },
  ],
  ["menu", { action: "menu", path: ["File", "New"] }, { kind: "menu", path: ["File", "New"] }],
  ["wait", { action: "wait", ms: 200 }, { kind: "wait", ms: 200 }],
])("plans %s", (_, step, action) => {
  expect(plan(step)).toEqual(expect.objectContaining({ action }));
});

it.each<[string, ComputerStep, ComputerUseError["code"]]>([
  ["a ref the snapshot lacks", { action: "click", ref: 9 }, "invalid_ref"],
  ["a click with no target", { action: "click" }, "invalid_ref"],
  ["both an element and a point", { action: "click", ref: 1, x: 1, y: 1 }, "invalid_input"],
  ["x without y", { action: "hover", x: 1 }, "invalid_input"],
  ["type without text", { action: "type", ref: 3 }, "invalid_input"],
  ["clear without an element", { action: "type", text: "hi", clear: true }, "invalid_input"],
  ["type at a point", { action: "type", x: 1, y: 1, text: "hi" }, "invalid_input"],
  ["press without a key", { action: "press", ref: 3 }, "invalid_input"],
  ["press with an unknown key", { action: "press", key: "Hyper" }, "invalid_key"],
  ["scroll without a delta", { action: "scroll", ref: 1 }, "invalid_input"],
  ["perform without an action", { action: "perform", ref: 1 }, "invalid_input"],
])("rejects %s", (_, step, code) => {
  expect(plan(step)).toBe(code);
});

it("drags from one element or point to a target element or point", () => {
  expect(plan({ action: "drag", ref: 1, target: { name: "8" } }, null)).toMatchObject({
    target: { ref: 1 },
    drop: { ref: 2 },
  });
  expect(plan({ action: "drag", x: 798, y: 2, target: { x: 0, y: 0 } })).toMatchObject({
    action: { kind: "drag", from: { x: 798, y: 2 }, to: { x: 0, y: 0 } },
    screen: { from: { x: 499, y: 51 }, to: { x: 100, y: 50 } },
  });
  expect(plan({ action: "drag", target: { ref: 2 } })).toBe("invalid_ref");
  expect(plan({ action: "drag", ref: 1 })).toBe("invalid_input");
  expect(plan({ action: "drag", ref: 1, target: { ref: 9 } })).toBe("invalid_ref");
  expect(plan({ action: "drag", ref: 1, target: { x: 1, y: 1 } }, null)).toBe("invalid_point");
});
/** A goal decider that answers `choices` in turn, then BLOCKED, recording each request. */
const decider = (
  choices: readonly string[] = [],
  requests: Parameters<BrowserGoal.GoalDecider["Service"]["decide"]>[0][] = [],
) =>
  Layer.succeed(
    BrowserGoal.GoalDecider,
    BrowserGoal.GoalDecider.of({
      decide: (request) =>
        Effect.sync(() => ({
          choice: choices[requests.push(request) - 1] ?? "BLOCKED",
          confidence: 0.9,
        })),
    }),
  );
const setup = (calls: WorkerRequest[], enabled = true, failAction = false) =>
  ComputerUse.layer.pipe(
    Layer.provide(decider()),
    Layer.provide(
      Layer.succeed(Driver.Driver, {
        withSession: (effect) => effect,
        execute: (request) =>
          Effect.sync(() => {
            if (request.kind === "permissions")
              return {
                ok: true as const,
                permissions: { accessibility: true, screenRecording: false },
              };
            calls.push(request);
            return request.kind === "snapshot"
              ? { ok: true as const, snapshot: { ...snapshot, app: request.app } }
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
    Layer.provide(Layer.mergeAll(NodeServices.layer, NodeCrypto.layer)),
  );
const code = <A>(effect: Effect.Effect<A, ComputerUseError>) =>
  effect.pipe(Effect.match({ onSuccess: () => "success", onFailure: (error) => error.code }));

it.effect("aims coordinate steps at the latest capture, even after text-only snapshots", () => {
  const calls: WorkerRequest[] = [];
  const window = { id: 77, bounds: { x: 200, y: 100, width: 300, height: 200 } };
  const layer = ComputerUse.layer.pipe(
    Layer.provide(decider()),
    Layer.provide(
      Layer.succeed(Driver.Driver, {
        withSession: (effect) => effect,
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
    Layer.provide(Layer.mergeAll(NodeServices.layer, NodeCrypto.layer)),
  );
  return Effect.gen(function* () {
    const computer = yield* ComputerUse.ComputerUse;
    const settings = yield* ServerSettings.ServerSettingsService;
    const click = { action: "click" as const, x: 300, y: 200 };
    const textOnly = yield* computer.snapshot("a", { app: "Calculator", includeImage: false });
    expect(
      yield* code(computer.act("a", { snapshotId: textOnly.snapshotId, steps: [click] })),
    ).toBe("invalid_point");
    yield* computer.snapshot("a", { app: "Calculator", includeImage: true });
    const later = yield* computer.snapshot("a", { app: "Calculator", includeImage: false });
    const first = yield* computer.act("a", { snapshotId: later.snapshotId, steps: [click] });
    expect(first.completed).toEqual(["takeover"]);
    yield* settings.updateSettings({ enableComputerPointerTakeover: false });
    // The snapshot an action returns keeps the capture too.
    yield* computer.act("a", { snapshotId: first.snapshot!.snapshotId, steps: [click] });
    const actions = calls.filter((call) => call.kind === "action");
    expect(actions.map((call) => [call.screen, call.takeover])).toEqual([
      [{ window, to: { x: 350, y: 200 } }, true],
      [{ window, to: { x: 350, y: 200 } }, false],
    ]);
  }).pipe(Effect.provide(layer));
});

it.effect("tells the agent when the app was sent back, in that operation's result only", () => {
  const layer = ComputerUse.layer.pipe(
    Layer.provide(decider()),
    Layer.provide(
      Layer.succeed(Driver.Driver, {
        withSession: (effect) => effect,
        execute: (request) =>
          Effect.sync(() =>
            request.kind === "snapshot"
              ? { ok: true as const, snapshot }
              : request.kind === "open"
                ? { ok: true as const, sentBack: true as const }
                : // The app came forward and the step still failed.
                  { ok: false as const, code: "failed" as const, sentBack: true as const },
          ),
      }),
    ),
    Layer.provide(DesktopTelemetryReceiver.layerTest()),
    Layer.provideMerge(
      ServerSettings.layerTest({
        enableAgentComputerAccess: true,
        computerUseAllowedApps: ["Calculator"],
      }),
    ),
    Layer.provide(Layer.mergeAll(NodeServices.layer, NodeCrypto.layer)),
  );
  return Effect.gen(function* () {
    const computer = yield* ComputerUse.ComputerUse;
    const opened = yield* computer.open("a", { app: "Calculator", activate: false });
    expect(opened.sentBack).toBe(true);
    const later = yield* computer.snapshot("a", { app: "Calculator", includeImage: false });
    expect(later.sentBack).toBeUndefined();
    const result = yield* computer.act("a", {
      snapshotId: later.snapshotId,
      steps: [{ ref: 1, action: "click" }],
    });
    expect(result).toMatchObject({ completed: [], error: { code: "failed" }, sentBack: true });
    expect(result.snapshot?.sentBack).toBeUndefined();
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

it.effect(
  "allows unlisted apps and revokes existing access when all-app access is turned off",
  () => {
    const calls: WorkerRequest[] = [];
    return Effect.gen(function* () {
      const computer = yield* ComputerUse.ComputerUse;
      const settings = yield* ServerSettings.ServerSettingsService;
      const input = { app: "TextEdit", activate: false };
      expect(yield* code(computer.open("a", input))).toBe("app_denied");
      expect(calls).toHaveLength(0);

      yield* settings.updateSettings({ computerUseAllowAllApps: true, computerUseAllowedApps: [] });
      expect(yield* computer.status).toMatchObject({
        allowAllApps: true,
        allowedApps: [],
        accessibilityPermission: true,
        screenRecordingPermission: false,
      });
      const opened = yield* computer.open("a", input);
      const result = yield* computer.act("a", {
        snapshotId: opened.snapshotId,
        steps: [{ ref: 1, action: "click" }],
      });
      expect(result.completed).toEqual(["accessibility"]);
      expect(calls.map((call) => [call.kind, "app" in call && call.app])).toEqual([
        ["open", "TextEdit"],
        ["snapshot", "TextEdit"],
        ["action", "TextEdit"],
        ["snapshot", "TextEdit"],
      ]);

      yield* settings.updateSettings({ computerUseAllowAllApps: false });
      expect(yield* computer.status).toMatchObject({ allowAllApps: false, allowedApps: [] });
      expect(
        yield* code(
          computer.act("a", {
            snapshotId: result.snapshot!.snapshotId,
            steps: [{ ref: 1, action: "click" }],
          }),
        ),
      ).toBe("app_denied");
      expect(yield* code(computer.snapshot("a", { app: "TextEdit", includeImage: false }))).toBe(
        "app_denied",
      );
      expect(calls).toHaveLength(4);
    }).pipe(Effect.provide(setup(calls)));
  },
);

it.effect("all-app access still requires computer access and the separate capture grant", () => {
  const calls: WorkerRequest[] = [];
  return Effect.gen(function* () {
    const computer = yield* ComputerUse.ComputerUse;
    const settings = yield* ServerSettings.ServerSettingsService;
    yield* settings.updateSettings({ computerUseAllowAllApps: true });
    expect(yield* code(computer.open("a", { app: "TextEdit", activate: false }))).toBe("disabled");
    yield* settings.updateSettings({ enableAgentComputerAccess: true });
    expect(yield* code(computer.snapshot("a", { app: "TextEdit", includeImage: true }))).toBe(
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
    const press = { ref: 1, action: "click" as const };
    const action = { snapshotId: shot.snapshotId, steps: [press] };
    expect(yield* code(computer.act("claude-work", action))).toBe("snapshot_expired");
    // One unknown ref rejects the whole batch before anything runs.
    expect(
      yield* code(
        computer.act("claude-personal", { ...action, steps: [press, { ...press, ref: 9 }] }),
      ),
    ).toBe("invalid_ref");
    expect(
      yield* code(computer.act("claude-personal", { ...action, steps: [{ action: "click" }] })),
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
      steps: [{ ref: 1, action: "click" as const }],
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
    Layer.provide(decider()),
    Layer.provide(
      Layer.effect(
        Driver.Driver,
        Effect.gen(function* () {
          const settings = yield* ServerSettings.ServerSettingsService;
          return {
            withSession: <A, E, R>(effect: Effect.Effect<A, E, R>) => effect,
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
    Layer.provide(Layer.mergeAll(NodeServices.layer, NodeCrypto.layer)),
  );
  return Effect.gen(function* () {
    const computer = yield* ComputerUse.ComputerUse;
    const shot = yield* computer.snapshot("a", { app: "Calculator", includeImage: false });
    const press = { ref: 1, action: "click" as const };
    const result = yield* computer.act("a", { snapshotId: shot.snapshotId, steps: [press, press] });
    expect(result.completed).toEqual(["accessibility"]);
    expect(result.error?.code).toBe("disabled");
    expect(result.snapshotError?.code).toBe("disabled");
    expect(calls.filter((call) => call.kind === "action")).toHaveLength(1);
  }).pipe(Effect.provide(layer));
});

/** A driver whose snapshots walk `walks` in turn, numbered 1..n like the worker; the last repeats. */
const walking = (
  walks: readonly (readonly NativeSnapshot["elements"][number][])[],
  calls: WorkerRequest[],
  snapshotFails?: (request: Extract<WorkerRequest, { kind: "snapshot" }>) => boolean,
  goals = decider(),
) =>
  ComputerUse.layer.pipe(
    Layer.provide(goals),
    Layer.provide(
      Layer.succeed(Driver.Driver, {
        withSession: (effect) => effect,
        execute: (request) =>
          Effect.sync(() => {
            calls.push(request);
            if (request.kind !== "snapshot") return { ok: true as const };
            if (snapshotFails?.(request))
              return { ok: false as const, code: "target_changed" as const };
            const walk =
              walks[
                Math.min(
                  calls.filter((call) => call.kind === "snapshot").length - 1,
                  walks.length - 1,
                )
              ]!;
            return {
              ok: true as const,
              snapshot: {
                ...snapshot,
                elements: walk.map((element, index) => ({ ...element, ref: index + 1 })),
              },
            };
          }),
      }),
    ),
    Layer.provide(DesktopTelemetryReceiver.layerTest()),
    Layer.provideMerge(
      ServerSettings.layerTest({
        enableAgentComputerAccess: true,
        computerUseAllowedApps: ["Calculator"],
      }),
    ),
    Layer.provide(Layer.mergeAll(NodeServices.layer, NodeCrypto.layer)),
  );
const allClear = { ...seven, name: "All Clear", stableId: "AllClear", path: [0, 1] };
const clear = { ...allClear, name: "Clear", stableId: "Clear" };
const display = {
  ...seven,
  role: "static_text",
  name: "7",
  actions: [],
  stableId: null,
  path: [0, 2],
};
const named = (elements: readonly NativeSnapshot["elements"][number][] | undefined) =>
  elements?.map((element) => `${element.name}=${element.ref}`);

it.effect("keeps refs across snapshots and actions, and rejects refs the app removed", () => {
  const calls: WorkerRequest[] = [];
  return Effect.gen(function* () {
    const computer = yield* ComputerUse.ComputerUse;
    const shot = yield* computer.snapshot("a", { app: "Calculator", includeImage: false });
    expect(named(shot.elements)).toEqual(["7=1", "All Clear=2"]);
    const pressed = yield* computer.act("a", {
      snapshotId: shot.snapshotId,
      steps: [{ ref: 1, action: "click" }],
    });
    // The result can be read as changes against the snapshot the batch ran on.
    expect(named(pressed.before?.elements)).toEqual(["7=1", "All Clear=2"]);
    expect(named(pressed.snapshot?.elements)).toEqual(["7=1", "Clear=3", "7=4"]);
    // All Clear is gone, so its ref is rejected rather than handed to Clear.
    expect(
      yield* code(
        computer.act("a", {
          snapshotId: pressed.snapshot!.snapshotId,
          steps: [{ ref: 2, action: "click" }],
        }),
      ),
    ).toBe("invalid_ref");
    const again = yield* computer.snapshot("a", { app: "Calculator", includeImage: false });
    expect(named(again.elements)).toEqual(["7=1", "Clear=3", "7=4"]);
    yield* computer.act("a", {
      snapshotId: again.snapshotId,
      steps: [{ ref: 3, action: "click" }],
    });
    const actions = calls.filter((call) => call.kind === "action");
    expect(actions.map((call) => call.target?.name)).toEqual(["7", "Clear"]);
  }).pipe(
    Effect.provide(
      walking(
        [
          [seven, allClear],
          [seven, clear, display],
        ],
        calls,
      ),
    ),
  );
});

it("offers a goal step the enabled pressable elements whose role and name pick out one", () => {
  const element = (role: string, name: string, more: Partial<typeof seven> = {}) => ({
    ...seven,
    role,
    name,
    stableId: `${role}:${name}`,
    ...more,
  });
  const view = ComputerUse.appGoalView({
    ...snapshot,
    elements: [
      element("window", "Home - Slack", { actions: ["raise"] }),
      element("tab", "Channels"),
      element("tree_item", "Channels", { states: ["expanded"] }),
      element("button", "Reply"),
      element("button", "Reply"),
      element("button", "Archived", { enabled: false }),
    ],
  });
  expect(view.actions.map((action) => action.description)).toEqual([
    'Click tab "Channels"',
    'Click tree_item "Channels" (expanded)',
  ]);
  expect(view.screen).toBe("Home - Slack");
  expect(view.page).not.toContain("@0,0");
});

it.effect(
  "runs a goal step's clicks until the decider is done, and stops a batch it cannot finish",
  () => {
    const calls: WorkerRequest[] = [];
    const requests: Parameters<BrowserGoal.GoalDecider["Service"]["decide"]>[0][] = [];
    const clicked = () =>
      calls.flatMap((call) => (call.kind === "action" ? [call.target?.name] : []));
    return Effect.gen(function* () {
      const computer = yield* ComputerUse.ComputerUse;
      const shot = yield* computer.snapshot("a", { app: "Calculator", includeImage: false });
      const running = yield* computer
        .act("a", {
          snapshotId: shot.snapshotId,
          steps: [
            { action: "goal", goal: "Enter 7", deny: ["clear"] },
            { ref: 2, action: "click" },
          ],
        })
        .pipe(Effect.forkChild);
      // The step re-reads the app after its click until two reads agree.
      yield* TestClock.adjust("1 second");
      const done = yield* Fiber.join(running);
      expect(done.completed).toEqual(["goal", "accessibility"]);
      expect(done.goals).toMatchObject([
        { goal: "Enter 7", status: "needs_verification", actions: ['Click button "7" (0.90)'] },
      ]);
      expect(clicked()).toEqual(["7", "All Clear"]);
      expect(Object.values(requests[0]!.options)).not.toContain('Click button "All Clear"');
      expect(requests[1]!.history).toEqual(['On "Calculator": Click button "7"']);

      const blocked = yield* computer.act("a", {
        snapshotId: done.snapshot!.snapshotId,
        steps: [
          { action: "goal", goal: "Divide by zero" },
          { ref: 1, action: "click" },
        ],
      });
      expect(blocked.error?.code).toBe("goal_incomplete");
      expect(blocked.goals).toMatchObject([{ status: "blocked", actions: [] }]);
      expect(clicked()).toEqual(["7", "All Clear"]);
    }).pipe(
      Effect.provide(
        walking(
          [
            [seven, allClear],
            [seven, allClear],
            [seven, allClear, display],
          ],
          calls,
          undefined,
          decider(["a0", "DONE"], requests),
        ),
      ),
    );
  },
);

it.effect("returns no baseline when the batch's view could not be shown again", () => {
  const calls: WorkerRequest[] = [];
  const acted = () => calls.some((call) => call.kind === "action");
  return Effect.gen(function* () {
    const computer = yield* ComputerUse.ComputerUse;
    const press = { ref: 1, action: "click" as const };
    yield* computer.snapshot("a", { app: "Calculator", includeImage: false });
    const rooted = yield* computer.snapshot("a", {
      app: "Calculator",
      includeImage: false,
      root: 1,
    });
    // The root vanished, so the result shows the whole app instead.
    const fallback = yield* computer.act("a", { snapshotId: rooted.snapshotId, steps: [press] });
    expect(fallback.snapshot).toBeDefined();
    expect(fallback.before).toBeUndefined();
    const paged = yield* computer.snapshot("a", {
      app: "Calculator",
      includeImage: false,
      offset: 1,
    });
    const reset = yield* computer.act("a", { snapshotId: paged.snapshotId, steps: [press] });
    expect(reset.snapshot).toBeDefined();
    expect(reset.before).toBeUndefined();
  }).pipe(
    Effect.provide(
      walking(
        [[seven, allClear]],
        calls,
        (request) => acted() && request.options.root !== undefined,
      ),
    ),
  );
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
          steps: [{ ref: 1, action: "click" }],
        }),
      ),
    ).toBe("snapshot_expired");
    const first = yield* computer.snapshot("a", { app: "Calculator", includeImage: false });
    const second = yield* computer.snapshot("b", { app: "Calculator", includeImage: false });
    const failed = yield* computer.act("a", {
      snapshotId: first.snapshotId,
      steps: [
        { ref: 1, action: "click" },
        { ref: 1, action: "click" },
      ],
    });
    // The batch stops at the uncertain step and never replays or continues it.
    expect(failed.error?.code).toBe("failed");
    expect(failed.completed).toEqual([]);
    expect(
      yield* code(
        computer.act("b", {
          snapshotId: second.snapshotId,
          steps: [{ ref: 1, action: "click" }],
        }),
      ),
    ).toBe("snapshot_expired");
    expect(calls.filter((call) => call.kind === "action")).toHaveLength(1);
  }).pipe(Effect.provide(setup(calls, true, true)));
});
