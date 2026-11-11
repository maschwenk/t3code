import * as Clock from "effect/Clock";
import * as Context from "effect/Context";
import * as SecureRandom from "effect/crypto/SecureRandom";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Result from "effect/Result";
import * as Semaphore from "effect/Semaphore";
import * as BrowserGoal from "../preview/BrowserGoal.ts";
import type { GoalInput } from "../preview/goalInput.ts";
import * as ServerSettings from "../serverSettings.ts";
import * as AgentCursor from "./agentCursor.ts";
import * as Driver from "./Driver.ts";
import { parseKeyChord } from "./keys.ts";
import { type Capture, captureToScreen } from "./pointerTarget.ts";
import { carryRefs, formatElement } from "./snapshotTree.ts";
import {
  ComputerUseError,
  type ComputerAction,
  type ComputerStep,
  type ElementTarget,
  type NativeSnapshot,
  type SnapshotOptions,
  type WorkerRequest,
  type WorkerResponse,
} from "./protocol.ts";

type Receipt = {
  readonly at: number;
  readonly caller: string;
  readonly snapshot: NativeSnapshot;
  /** How the snapshot was taken, so an action can return the same view afterwards. */
  readonly options: SnapshotOptions;
  /** The latest window image this caller received for the app, for coordinate steps. */
  readonly capture?: Capture | undefined;
  /** The ref the next new element gets; refs carry over to the caller's next snapshot. */
  readonly nextRef: number;
};

const DEFAULT_LIMIT = 250;
// Steps re-find their element and stop on any change, so an older snapshot is
// safe to act on; a long expiry spares agents a snapshot after every reply.
const RECEIPT_TTL_MS = 10 * 60_000;
export const MAX_BATCH_STEPS = 20;

export type SnapshotInput = {
  readonly app: string;
  readonly includeImage: boolean;
  readonly query?: string | undefined;
  readonly roles?: readonly string[] | undefined;
  /** A ref from the caller's latest snapshot of this app whose subtree to walk. */
  readonly root?: number | undefined;
  readonly offset?: number | undefined;
  readonly limit?: number | undefined;
  readonly includeOffscreen?: boolean | undefined;
};
/** The one snapshot element a step names; undefined when absent or ambiguous. */
export function resolveStepTarget(
  elements: readonly ElementTarget[],
  step: Pick<ComputerStep, "ref" | "name" | "role">,
): ElementTarget | undefined {
  if (step.ref !== undefined) return elements.find((element) => element.ref === step.ref);
  if (step.name === undefined) return undefined;
  const matches = elements.filter(
    (element) =>
      element.name === step.name && (step.role === undefined || element.role === step.role),
  );
  return matches.length === 1 ? matches[0] : undefined;
}

type ActionRequest = Extract<WorkerRequest, { kind: "action" }>;
type ActionStep = Pick<ActionRequest, "action" | "target" | "drop" | "screen">;
export type PlannedStep = ActionStep | { readonly goal: GoalInput };

/**
 * Checks one step against its snapshot and the latest capture, maps its verb to
 * the worker action that performs it, resolves element names and maps capture
 * pixels to screen points. Returns the error code that rejects the whole batch
 * when the step cannot run.
 */
export function planStep(
  elements: readonly ElementTarget[],
  capture: Capture | undefined,
  step: ComputerStep,
): PlannedStep | ComputerUseError["code"] {
  if (step.action === "goal") {
    if (step.goal === undefined) return "invalid_input";
    const { goal, maxSteps, minConfidence, deny } = step;
    return { goal: { goal, maxSteps, minConfidence, deny } };
  }
  const named = step.ref !== undefined || step.name !== undefined;
  const target = resolveStepTarget(elements, step) ?? null;
  if (named && !target) return "invalid_ref";
  if ((step.x === undefined) !== (step.y === undefined)) return "invalid_input";
  const point = step.x !== undefined && step.y !== undefined ? { x: step.x, y: step.y } : null;
  // A step starts from exactly one of an element or a capture pixel.
  if (named && point) return "invalid_input";
  const toScreen = (pixel: { readonly x: number; readonly y: number }) =>
    capture ? captureToScreen(capture, pixel) : undefined;
  const foreground = step.foreground === undefined ? {} : { foreground: step.foreground };
  const plan = (action: ComputerAction, more?: Pick<ActionStep, "drop" | "screen">) => ({
    action,
    target,
    ...more,
  });
  switch (step.action) {
    case "click":
    case "hover": {
      const click = { button: step.button ?? "left", count: step.clickCount ?? 1, ...foreground };
      // The worker lands a single click on an element listing press (show_menu for
      // right) through that accessibility action.
      if (target)
        return plan(
          step.action === "click" ? { kind: "click", ...click } : { kind: "move", ...foreground },
        );
      if (!point) return "invalid_ref";
      const to = toScreen(point);
      if (!to || !capture) return "invalid_point";
      return plan(
        step.action === "click"
          ? { kind: "click_at", ...point, ...click }
          : { kind: "move_at", ...point, ...foreground },
        { screen: { window: capture.window, to } },
      );
    }
    case "drag": {
      if (!step.target) return "invalid_input";
      if (!target && !point) return "invalid_ref";
      const from = point ? toScreen(point) : undefined;
      if (point && !from) return "invalid_point";
      let to: ReturnType<typeof toScreen>;
      let drop: ElementTarget | undefined;
      if ("x" in step.target) {
        to = toScreen(step.target);
        if (!to) return "invalid_point";
      } else {
        drop = resolveStepTarget(elements, step.target);
        if (!drop) return "invalid_ref";
      }
      return plan(
        { kind: "drag", ...(point ? { from: point } : {}), to: step.target, ...foreground },
        {
          ...(drop ? { drop } : {}),
          ...(capture && (from || to)
            ? {
                screen: {
                  window: capture.window,
                  ...(from ? { from } : {}),
                  ...(to ? { to } : {}),
                },
              }
            : {}),
        },
      );
    }
  }
  if (point) return "invalid_input";
  switch (step.action) {
    case "press": {
      if (step.key === undefined) return "invalid_input";
      const key = [...(step.modifiers ?? []), step.key].join("+");
      if (!parseKeyChord(key)) return "invalid_key";
      return plan({ kind: "key", key, ...(step.repeat ? { repeat: step.repeat } : {}) });
    }
    case "menu":
      return step.path ? plan({ kind: "menu", path: step.path }) : "invalid_input";
    case "wait":
      return step.ms === undefined ? "invalid_input" : plan({ kind: "wait", ms: step.ms });
  }
  if (step.action === "type") {
    if (step.text === undefined || (step.clear && !target)) return "invalid_input";
    // Without a target the text goes to the focused element, like press.
    return plan({ kind: "type", text: step.text, replace: step.clear ?? false });
  }
  if (!target) return "invalid_ref";
  switch (step.action) {
    case "scroll":
      return step.deltaX === undefined && step.deltaY === undefined
        ? "invalid_input"
        : plan({ kind: "scroll", dx: step.deltaX ?? 0, dy: step.deltaY ?? 0, ...foreground });
    case "perform":
      return step.perform === undefined
        ? "invalid_input"
        : plan({ kind: "perform", action: step.perform });
  }
}
export type AppGoalAction = { readonly description: string; readonly target: ElementTarget };
const GOAL_VIEW: SnapshotOptions = { offset: 0, limit: 600, includeOffscreen: false };
const GOAL_BUDGET_MS = 90_000;
const GOAL_QUIET_MS = 600;
const GOAL_SETTLE_MS = 5000;
const GOAL_SETTLE_GAP = "200 millis";
const GOAL_STATES = new Set(["selected", "checked", "mixed", "expanded"]);

/** What a goal step's decider reads of an app, and the elements it may click: enabled ones
 * listing press whose role and name pick out one of them. */
export function appGoalView(
  snapshot: NativeSnapshot,
  deny: ReadonlyArray<string> = [],
): BrowserGoal.GoalView<AppGoalAction> {
  const window = snapshot.elements.find((element) => element.role === "window")?.name;
  const screen = window || snapshot.app;
  // Coordinates only cost the decider tokens; it picks elements, never points.
  const tree = snapshot.elements
    .map((element) => formatElement(element).replace(/ @-?\d+,-?\d+ \d+x\d+/, ""))
    .join("\n");
  const pressable = snapshot.elements.filter(
    (element) => element.enabled && element.name?.trim() && element.actions.includes("press"),
  );
  // Options name the role, so a tab and a sidebar row may share a name.
  const key = (element: ElementTarget) => `${element.role}\n${element.name}`;
  const named = new Map<string, number>();
  for (const element of pressable) named.set(key(element), (named.get(key(element)) ?? 0) + 1);
  const denied = deny.map((value) => value.toLowerCase());
  const actions = pressable
    .filter(
      (element) =>
        named.get(key(element)) === 1 &&
        !denied.some((value) => element.name!.toLowerCase().includes(value)),
    )
    .slice(0, BrowserGoal.MAX_OPTIONS)
    .map((target) => {
      const states = target.states.filter((state) => GOAL_STATES.has(state));
      return {
        target,
        description: `Click ${target.role} ${JSON.stringify(target.name)}${states.length ? ` (${states.join(", ")})` : ""}`,
      };
    });
  return { page: `App: ${snapshot.app}\nWindow: ${screen}\n${tree}`, screen, actions };
}

export type Observation = NativeSnapshot & {
  readonly snapshotId: string;
  /** The app came forward on its own and was sent back behind the user's app. */
  readonly sentBack?: true;
};
export type ActResult = {
  readonly total: number;
  /** The app came forward on its own during the batch and was sent back behind the user's app. */
  readonly sentBack?: true;
  /** How each completed step was delivered, in order. */
  readonly completed: ReadonlyArray<
    NonNullable<Extract<WorkerResponse, { ok: true }>["via"]> | "wait" | "goal"
  >;
  /** Each goal step's run, including one that stopped the batch. */
  readonly goals?: ReadonlyArray<BrowserGoal.GoalOutcome & { readonly goal: string }>;
  /** Why the batch stopped early. Later steps did not run. */
  readonly error?: ComputerUseError;
  /** The app after the batch, viewed the same way as the snapshot it started from. */
  readonly snapshot?: Observation;
  /** The snapshot the batch ran against, when `snapshot` shows the same view of the app. */
  readonly before?: NativeSnapshot;
  readonly snapshotError?: ComputerUseError;
};

export class ComputerUse extends Context.Service<
  ComputerUse,
  {
    readonly status: Effect.Effect<
      {
        enabled: boolean;
        allowAllApps: boolean;
        allowedApps: readonly string[];
        screenCaptureEnabled: boolean;
        /** macOS only: whether the T3 host process holds these permissions. */
        accessibilityPermission?: boolean;
        screenRecordingPermission?: boolean;
      },
      ComputerUseError
    >;
    readonly snapshot: (
      caller: string,
      input: SnapshotInput,
    ) => Effect.Effect<Observation, ComputerUseError>;
    /** Runs steps in order against one snapshot, stopping at the first failure. */
    readonly act: (
      caller: string,
      input: {
        readonly snapshotId: string;
        readonly steps: readonly ComputerStep[];
        readonly includeImage?: boolean | undefined;
      },
    ) => Effect.Effect<ActResult, ComputerUseError>;
    /** Launches or reopens an allowed app, without bringing it forward unless asked. */
    readonly open: (
      caller: string,
      input: { readonly app: string; readonly activate: boolean },
    ) => Effect.Effect<Observation, ComputerUseError>;
  }
>()("t3/computerUse/ComputerUse") {}

const make = Effect.gen(function* () {
  const settings = yield* ServerSettings.ServerSettingsService;
  const driver = yield* Driver.Driver;
  const decider = yield* BrowserGoal.GoalDecider;
  const cursor = yield* AgentCursor.make;
  const random = yield* SecureRandom.SecureRandom;
  const mutex = yield* Semaphore.make(1);
  const receipts = new Map<string, Receipt>();
  // When the last agent pointer gesture ended; see deliverPointer's ownInputAt.
  let pointerInputAt: number | undefined;
  // Whether the worker sent the app back since the running operation started.
  // The mutex runs one operation at a time.
  let sentBack = false;
  const fail = (code: ComputerUseError["code"]) => new ComputerUseError({ code });
  const execute = (request: WorkerRequest) =>
    driver.execute(request).pipe(
      Effect.tap((result) =>
        Effect.sync(() => {
          if (result.sentBack) sentBack = true;
        }),
      ),
      Effect.filterOrFail(
        (result): result is Extract<WorkerResponse, { readonly ok: true }> => result.ok,
        // orFailWith sees the whole union, so the failure fields are read with `in`.
        (result) =>
          new ComputerUseError({
            code: "code" in result ? result.code : "failed",
            ...("detail" in result && result.detail ? { detail: result.detail } : {}),
            ...("available" in result && result.available ? { available: result.available } : {}),
          }),
      ),
    );
  const status = Effect.gen(function* () {
    const current = yield* settings.getSettings.pipe(
      Effect.mapError((cause) => new ComputerUseError({ code: "disabled", cause })),
    );
    // Off macOS, or when the helper cannot start, the permission fields are left out.
    const granted = yield* execute({ kind: "permissions" }).pipe(
      Effect.map((result) => result.permissions),
      Effect.orElseSucceed(() => undefined),
    );
    return {
      enabled: current.enableAgentComputerAccess,
      allowAllApps: current.computerUseAllowAllApps,
      allowedApps: current.computerUseAllowedApps,
      screenCaptureEnabled: current.enableComputerScreenCapture,
      ...(granted
        ? {
            accessibilityPermission: granted.accessibility,
            screenRecordingPermission: granted.screenRecording,
          }
        : {}),
    };
  });
  /**
   * Checks the live settings. Native work runs for seconds to minutes, so it
   * must not hold the settings write lock: that would also hold back the user
   * turning computer use off. Batches check again before every step instead.
   */
  const check = (app: string, includeImage: boolean) =>
    settings.getSettings.pipe(
      Effect.mapError((cause) => new ComputerUseError({ code: "disabled", cause })),
      Effect.flatMap((current) => {
        if (!current.enableAgentComputerAccess) {
          receipts.clear();
          return Effect.fail(fail("disabled"));
        }
        if (!current.computerUseAllowAllApps && !current.computerUseAllowedApps.includes(app))
          return Effect.fail(fail("app_denied"));
        if (includeImage && !current.enableComputerScreenCapture)
          return Effect.fail(fail("capture_denied"));
        return Effect.succeed(current);
      }),
    );
  const authorized = <A>(
    app: string,
    includeImage: boolean,
    work: Effect.Effect<A, ComputerUseError>,
  ) => check(app, includeImage).pipe(Effect.andThen(work));
  /** Marks an operation's result when the worker sent the app back while it ran. */
  const reportingSentBack = <A extends object, E>(work: Effect.Effect<A, E>) =>
    Effect.suspend(() => {
      sentBack = false;
      return work;
    }).pipe(
      Effect.map((value): A & { readonly sentBack?: true } =>
        sentBack ? { ...value, sentBack: true } : value,
      ),
    );

  /**
   * Takes a snapshot and issues its receipt. Callers hold the mutex and
   * authorization. The snapshot keeps the refs of the caller's previous one of
   * the same app, and a text-only snapshot keeps its capture, whose window the
   * worker checks before using its pixels.
   */
  const observe = Effect.fn("ComputerUse.observe")(function* (
    caller: string,
    app: string,
    includeImage: boolean,
    options: SnapshotOptions,
    previous?: Receipt,
  ) {
    for (const receipt of receipts.values())
      if (receipt.caller === caller && receipt.snapshot.app === app) previous ??= receipt;
    // A failed refresh must not leave an older observation usable.
    for (const [id, receipt] of receipts) if (receipt.caller === caller) receipts.delete(id);
    const result = yield* execute({ kind: "snapshot", app, includeImage, options });
    if (!result.snapshot) return yield* fail("failed");
    const { elements, nextRef } = carryRefs(
      previous?.snapshot.pid === result.snapshot.pid ? previous.snapshot.elements : [],
      result.snapshot.elements,
      previous?.nextRef ?? 1,
    );
    const at = yield* Clock.currentTimeMillis;
    for (const [id, receipt] of receipts)
      if (at - receipt.at > RECEIPT_TTL_MS || receipt.caller === caller) receipts.delete(id);
    const oldest = receipts.keys().next().value;
    if (receipts.size >= 32 && oldest !== undefined) receipts.delete(oldest);
    const snapshotId = yield* random.uuidV4();
    // Images live only in the tool response, never in the receipt cache.
    const { image, ...remembered } = result.snapshot;
    const capture = image
      ? { window: image.window, width: image.width, height: image.height }
      : previous?.capture;
    receipts.set(snapshotId, {
      at,
      caller,
      snapshot: { ...remembered, elements },
      options,
      capture,
      nextRef,
    });
    return { ...result.snapshot, elements, snapshotId };
  });

  const snapshot: ComputerUse["Service"]["snapshot"] = (caller, input) =>
    mutex.withPermits(1)(
      authorized(
        input.app,
        input.includeImage,
        Effect.gen(function* () {
          let root: ElementTarget | undefined;
          if (input.root !== undefined) {
            const now = yield* Clock.currentTimeMillis;
            const latest = [...receipts.values()].findLast(
              (receipt) =>
                receipt.caller === caller &&
                receipt.snapshot.app === input.app &&
                now - receipt.at <= RECEIPT_TTL_MS,
            );
            if (!latest) return yield* fail("snapshot_expired");
            root = latest.snapshot.elements.find((element) => element.ref === input.root);
            if (!root) return yield* fail("invalid_ref");
          }
          const observation = yield* observe(caller, input.app, input.includeImage, {
            ...(input.query?.trim() ? { query: input.query.trim() } : {}),
            ...(input.roles?.length ? { roles: input.roles } : {}),
            ...(root ? { root } : {}),
            offset: input.offset ?? 0,
            limit: input.limit ?? DEFAULT_LIMIT,
            includeOffscreen: input.includeOffscreen ?? false,
          });
          yield* cursor.look(caller, observation);
          return observation;
        }).pipe(reportingSentBack),
      ),
    );

  /** A goal step's view of the app: fresh whole-app reads, and clicks that run like click steps.
   * Callers hold the mutex, the authorization and a worker session. */
  const goalSurface = (
    caller: string,
    app: string,
    pid: number,
    deny: ReadonlyArray<string> | undefined,
  ): BrowserGoal.GoalSurface<AppGoalAction, ComputerUseError> => {
    const read = execute({ kind: "snapshot", app, includeImage: false, options: GOAL_VIEW }).pipe(
      Effect.flatMap((result) =>
        result.snapshot?.pid === pid
          ? Effect.succeed(appGoalView(result.snapshot, deny))
          : Effect.fail(fail("target_changed")),
      ),
    );
    let clicked = false;
    return {
      // Apps keep redrawing after a click: a Slack channel switch passes through an empty
      // window and a bare "Slack" title for about two seconds, each step steady for up to
      // 400 ms. So a read counts only once the app has looked the same for GOAL_QUIET_MS.
      observe: Effect.fn("ComputerUse.goalObserve")(function* () {
        let view = yield* read;
        if (!clicked) return view;
        const start = yield* Clock.currentTimeMillis;
        let quietSince = start;
        while (true) {
          const now = yield* Clock.currentTimeMillis;
          if (now - quietSince >= GOAL_QUIET_MS || now - start >= GOAL_SETTLE_MS) {
            clicked = false;
            return view;
          }
          yield* Effect.sleep(GOAL_SETTLE_GAP);
          const next = yield* read;
          if (next.page !== view.page) {
            view = next;
            quietSince = yield* Clock.currentTimeMillis;
          }
        }
      }),
      act: Effect.fn("ComputerUse.goalClick")(function* (choice: AppGoalAction) {
        const allowed = yield* check(app, false);
        const click = { kind: "click", button: "left", count: 1 } as const;
        yield* cursor.point(caller, click, choice.target);
        const outcome = yield* execute({
          kind: "action",
          app,
          pid,
          target: choice.target,
          action: click,
          takeover: allowed.enableComputerPointerTakeover,
          ...(pointerInputAt !== undefined ? { ownInputAt: pointerInputAt } : {}),
        });
        if (outcome.inputAt !== undefined) pointerInputAt = outcome.inputAt;
        clicked = true;
      }),
    };
  };

  const act: ComputerUse["Service"]["act"] = (caller, input) =>
    mutex.withPermits(1)(
      Effect.gen(function* () {
        const receipt = receipts.get(input.snapshotId);
        const now = yield* Clock.currentTimeMillis;
        if (!receipt || receipt.caller !== caller || now - receipt.at > RECEIPT_TTL_MS)
          return yield* fail("snapshot_expired");
        if (input.steps.length === 0 || input.steps.length > MAX_BATCH_STEPS)
          return yield* fail("invalid_input");
        // Every step is checked against the snapshot before any of them runs.
        const steps: PlannedStep[] = [];
        for (const step of input.steps) {
          const planned = planStep(receipt.snapshot.elements, receipt.capture, step);
          if (typeof planned === "string") return yield* fail(planned);
          steps.push(planned);
        }
        const { app, pid } = receipt.snapshot;
        return yield* authorized(
          app,
          input.includeImage ?? false,
          driver.withSession(
            Effect.gen(function* () {
              // A failed/uncertain write is never replayed. An action also invalidates
              // other threads' observations of the same desktop.
              receipts.clear();
              const completed: ActResult["completed"][number][] = [];
              const goals: NonNullable<ActResult["goals"]>[number][] = [];
              let error: ComputerUseError | undefined;
              for (const step of steps) {
                // Turning computer use off, or removing the app, stops the rest of a batch.
                const allowed = yield* Effect.result(check(app, false));
                if (Result.isFailure(allowed)) {
                  error = allowed.failure;
                  break;
                }
                if ("goal" in step) {
                  const deadline = (yield* Clock.currentTimeMillis) + GOAL_BUDGET_MS;
                  const run = yield* BrowserGoal.runGoal(
                    step.goal,
                    goalSurface(caller, app, pid, step.goal.deny),
                    deadline,
                  ).pipe(Effect.provideService(BrowserGoal.GoalDecider, decider));
                  goals.push({ goal: step.goal.goal, ...run });
                  if (run.status !== "needs_verification") {
                    error = fail("goal_incomplete");
                    break;
                  }
                  completed.push("goal");
                  continue;
                }
                const { action, target } = step;
                if (action.kind === "wait") {
                  yield* Effect.sleep(action.ms);
                  completed.push("wait");
                  continue;
                }
                const from = target ?? step.screen?.from ?? step.screen?.to;
                if (from) yield* cursor.point(caller, action, from);
                // Each step re-finds its element, so a step that changes the
                // app cannot redirect a later step to a different element.
                const outcome = yield* Effect.result(
                  execute({
                    kind: "action",
                    app,
                    pid,
                    ...step,
                    takeover: allowed.success.enableComputerPointerTakeover,
                    ...(pointerInputAt !== undefined ? { ownInputAt: pointerInputAt } : {}),
                  }),
                );
                if (Result.isFailure(outcome)) {
                  error = outcome.failure;
                  break;
                }
                if (outcome.success.inputAt !== undefined) pointerInputAt = outcome.success.inputAt;
                // A drag ends where it dropped.
                const dropped = step.drop ?? (action.kind === "drag" ? step.screen?.to : undefined);
                if (dropped) yield* cursor.point(caller, { kind: "move" }, dropped);
                completed.push(outcome.success.via ?? "accessibility");
              }
              const options = { ...receipt.options, offset: 0 };
              const includeImage = input.includeImage ?? false;
              let sameView = receipt.options.offset === 0;
              let after = yield* Effect.result(
                authorized(app, includeImage, observe(caller, app, includeImage, options, receipt)),
              );
              if (
                Result.isFailure(after) &&
                after.failure.code === "target_changed" &&
                options.root
              ) {
                const { root: _root, ...whole } = options;
                sameView = false;
                after = yield* Effect.result(
                  authorized(app, includeImage, observe(caller, app, includeImage, whole, receipt)),
                );
              }
              return {
                total: steps.length,
                completed,
                ...(goals.length ? { goals } : {}),
                ...(error ? { error } : {}),
                ...(Result.isSuccess(after)
                  ? {
                      snapshot: after.success,
                      ...(sameView ? { before: receipt.snapshot } : {}),
                    }
                  : { snapshotError: after.failure }),
              };
            }),
          ),
        );
      }).pipe(reportingSentBack),
    );

  const open: ComputerUse["Service"]["open"] = (caller, input) =>
    mutex.withPermits(1)(
      authorized(
        input.app,
        false,
        Effect.gen(function* () {
          yield* execute({ kind: "open", app: input.app, activate: input.activate });
          const observation = yield* observe(caller, input.app, false, {
            offset: 0,
            limit: DEFAULT_LIMIT,
            includeOffscreen: false,
          });
          yield* cursor.look(caller, observation);
          return observation;
        }).pipe(reportingSentBack),
      ),
    );
  return ComputerUse.of({ status, snapshot, act, open });
});
export const layer = Layer.effect(ComputerUse, make);
