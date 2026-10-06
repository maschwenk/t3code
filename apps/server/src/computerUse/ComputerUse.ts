import * as Clock from "effect/Clock";
import * as Context from "effect/Context";
import * as Crypto from "effect/Crypto";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Result from "effect/Result";
import * as Semaphore from "effect/Semaphore";
import * as ServerSettings from "../serverSettings.ts";
import * as AgentCursor from "./agentCursor.ts";
import * as Driver from "./Driver.ts";
import { parseKeyChord } from "./keys.ts";
import {
  ComputerUseError,
  ELEMENTLESS_ACTIONS,
  type ComputerAction,
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
};

const DEFAULT_LIMIT = 250;
const RECEIPT_TTL_MS = 120_000;
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
/** Targets an element by ref, or by exact name (and role) from the latest snapshot. */
export type ActionStep = {
  readonly ref?: number | undefined;
  readonly name?: string | undefined;
  readonly role?: string | undefined;
  readonly action: ComputerAction;
};

/** The one snapshot element a step names; undefined when absent or ambiguous. */
export function resolveStepTarget(
  elements: readonly ElementTarget[],
  step: Pick<ActionStep, "ref" | "name" | "role">,
): ElementTarget | undefined {
  if (step.ref !== undefined) return elements.find((element) => element.ref === step.ref);
  if (step.name === undefined) return undefined;
  const matches = elements.filter(
    (element) =>
      element.name === step.name && (step.role === undefined || element.role === step.role),
  );
  return matches.length === 1 ? matches[0] : undefined;
}
export type Observation = NativeSnapshot & { readonly snapshotId: string };
export type ActResult = {
  readonly total: number;
  /** How each completed step was delivered, in order. */
  readonly completed: ReadonlyArray<
    NonNullable<Extract<WorkerResponse, { ok: true }>["via"]> | "wait"
  >;
  /** Why the batch stopped early. Later steps did not run. */
  readonly error?: ComputerUseError;
  /** The app after the batch, viewed the same way as the snapshot it started from. */
  readonly snapshot?: Observation;
  readonly snapshotError?: ComputerUseError;
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
      input: SnapshotInput,
    ) => Effect.Effect<Observation, ComputerUseError>;
    /** Runs steps in order against one snapshot, stopping at the first failure. */
    readonly act: (
      caller: string,
      input: {
        readonly snapshotId: string;
        readonly steps: readonly ActionStep[];
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
  const cursor = yield* AgentCursor.make;
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
                ...("detail" in result && result.detail ? { detail: result.detail } : {}),
                ...("available" in result && result.available
                  ? { available: result.available }
                  : {}),
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

  /** Takes a snapshot and issues its receipt. Callers hold the mutex and authorization. */
  const observe = (caller: string, app: string, includeImage: boolean, options: SnapshotOptions) =>
    Effect.gen(function* () {
      // A failed refresh must not leave an older observation usable.
      for (const [id, receipt] of receipts) if (receipt.caller === caller) receipts.delete(id);
      const result = yield* execute({ kind: "snapshot", app, includeImage, options });
      if (!result.snapshot) return yield* fail("failed");
      const at = yield* Clock.currentTimeMillis;
      for (const [id, receipt] of receipts)
        if (at - receipt.at > RECEIPT_TTL_MS || receipt.caller === caller) receipts.delete(id);
      const oldest = receipts.keys().next().value;
      if (receipts.size >= 32 && oldest !== undefined) receipts.delete(oldest);
      const snapshotId = yield* crypto.randomUUIDv4.pipe(
        Effect.mapError((cause) => new ComputerUseError({ code: "failed", cause })),
      );
      // Images live only in the tool response, never in the receipt cache.
      const { image: _image, ...remembered } = result.snapshot;
      receipts.set(snapshotId, { at, caller, snapshot: remembered, options });
      return { ...result.snapshot, snapshotId };
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
        }),
      ),
    );

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
        const steps: { action: ComputerAction; target: ElementTarget | null }[] = [];
        for (const step of input.steps) {
          const target = resolveStepTarget(receipt.snapshot.elements, step);
          if ((step.ref !== undefined || step.name !== undefined) && !target)
            return yield* fail("invalid_ref");
          if (!target && !ELEMENTLESS_ACTIONS.has(step.action.kind))
            return yield* fail("invalid_ref");
          if (step.action.kind === "key" && !parseKeyChord(step.action.key))
            return yield* fail("invalid_key");
          steps.push({ action: step.action, target: target ?? null });
        }
        const { app, pid } = receipt.snapshot;
        return yield* authorized(
          app,
          input.includeImage ?? false,
          Effect.gen(function* () {
            // A failed/uncertain write is never replayed. An action also invalidates
            // other threads' observations of the same desktop.
            receipts.clear();
            const completed: ActResult["completed"][number][] = [];
            let error: ComputerUseError | undefined;
            for (const { action, target } of steps) {
              if (action.kind === "wait") {
                yield* Effect.sleep(action.ms);
                completed.push("wait");
                continue;
              }
              if (target) yield* cursor.point(caller, action, target);
              // Each step re-finds its element, so a step that changes the
              // app cannot redirect a later step to a different element.
              const outcome = yield* Effect.result(
                execute({ kind: "action", app, pid, target, action }),
              );
              if (Result.isFailure(outcome)) {
                error = outcome.failure;
                break;
              }
              completed.push(outcome.success.via ?? "accessibility");
            }
            // Starting the snapshot worker takes longer than most apps need to
            // finish reacting, so the view is taken without an extra delay.
            const options = { ...receipt.options, offset: 0 };
            let after = yield* Effect.result(
              observe(caller, app, input.includeImage ?? false, options),
            );
            if (
              Result.isFailure(after) &&
              after.failure.code === "target_changed" &&
              options.root
            ) {
              const { root: _root, ...whole } = options;
              after = yield* Effect.result(
                observe(caller, app, input.includeImage ?? false, whole),
              );
            }
            return {
              total: steps.length,
              completed,
              ...(error ? { error } : {}),
              ...(Result.isSuccess(after)
                ? { snapshot: after.success }
                : { snapshotError: after.failure }),
            };
          }),
        );
      }),
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
        }),
      ),
    );
  return ComputerUse.of({ status, snapshot, act, open });
});
export const layer = Layer.effect(ComputerUse, make);
