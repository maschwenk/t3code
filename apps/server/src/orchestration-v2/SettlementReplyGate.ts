import type {
  ModelSelection,
  OrchestrationV2ConversationMessage,
  OrchestrationV2Run,
  RunId,
} from "@t3tools/contracts";
import type { SettlementReplyCheckInput } from "@t3tools/provider-core/server/textGeneration";
import * as Cause from "effect/Cause";
import * as DateTime from "effect/DateTime";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as Semaphore from "effect/Semaphore";

import * as TextGeneration from "../textGeneration/TextGeneration.ts";
import { lastFinishedReply } from "./CompletionNotificationTriage.ts";
import * as ProjectionStore from "./ProjectionStore.ts";

/** Why a merged or closed pull request may not settle the thread after its latest run. */
export type SettlementHoldReason =
  | "run_failed"
  | "run_interrupted"
  | "stop_requested"
  | "needs_user"
  | "no_verdict";

// Held threads stay candidates for days, so their runs' verdicts must outlive many sweeps.
const REMEMBERED_RUNS = 2_000;
// After each failed check; the run is held for good once these run out.
const RETRY_DELAYS_MS = [5 * 60_000, 30 * 60_000];
const CONCURRENT_CHECKS = 4;

type Decision =
  | { readonly kind: "settles" }
  | {
      readonly kind: "holds";
      readonly reason: Exclude<SettlementHoldReason, "no_verdict">;
    }
  | { readonly kind: "deciding"; readonly decided: Deferred.Deferred<void> }
  | { readonly kind: "failed"; readonly attempts: number; readonly retryAtMs: number | null };

type ReplyMessage = Pick<
  OrchestrationV2ConversationMessage,
  "id" | "runId" | "role" | "text" | "streaming" | "createdBy" | "scheduledTaskId"
>;

/** What the model reads about a run, or null when the run left no reply to judge. */
function settlementReplySubject(
  run: Pick<OrchestrationV2Run, "id" | "userMessageId">,
  messages: ReadonlyArray<ReplyMessage>,
): Pick<SettlementReplyCheckInput, "request" | "requestOrigin" | "reply"> | null {
  const reply = lastFinishedReply(messages, run.id);
  if (reply === undefined) return null;
  const request = messages.find((message) => message.id === run.userMessageId);
  return {
    request: request?.text ?? "",
    requestOrigin:
      request?.scheduledTaskId !== undefined
        ? "scheduled"
        : request?.createdBy === "user"
          ? "user"
          : "automated",
    reply,
  };
}

export interface SettlementReplyGateInput {
  readonly thread: Pick<
    ProjectionStore.ProjectionSettlementCandidate,
    "id" | "latestRunId" | "latestRunCompletedAt"
  >;
  readonly pullRequest: { readonly state: "merged" | "closed"; readonly finishedAtMs: number };
  /** The project's workspace root: the thread's worktree is often gone once its pull request merges. */
  readonly cwd: string | null;
  readonly modelSelection: ModelSelection;
  /** Off, only a failed, interrupted, or stopped run holds; the model is not asked. */
  readonly checkReply: boolean;
}

/**
 * Decides once per run whether a merged or closed pull request may settle the thread: never after
 * a run that failed, was interrupted, or was stopped, and, while `checkReply` is on, not while the
 * text generation model reads the run's last reply as needing the user. Model errors, timeouts,
 * and missing verdicts hold the thread, with a bounded number of retries per run.
 */
export const make = Effect.gen(function* () {
  const projections = yield* ProjectionStore.ProjectionStoreV2;
  const textGeneration = yield* TextGeneration.TextGeneration;
  const scope = yield* Effect.scope;
  const checks = yield* Semaphore.make(CONCURRENT_CHECKS);
  const decisions = new Map<RunId, Decision>();

  const remember = (runId: RunId, decision: Decision) => {
    decisions.delete(runId);
    decisions.set(runId, decision);
    if (decisions.size > REMEMBERED_RUNS) {
      const oldest = decisions.keys().next().value;
      if (oldest !== undefined) decisions.delete(oldest);
    }
  };

  /**
   * Whether a decision already holds the thread's latest run, without reading anything. A check
   * in progress or a failed one waiting out its retry delay counts as holding.
   */
  const holds = (
    thread: Pick<ProjectionStore.ProjectionSettlementCandidate, "latestRunId">,
    nowMs: number,
    checkReply: boolean,
  ): boolean => {
    if (thread.latestRunId === null) return false;
    const decision = decisions.get(thread.latestRunId);
    if (decision === undefined || decision.kind === "settles") return false;
    if (decision.kind === "holds") return checkReply || decision.reason !== "needs_user";
    if (!checkReply) return false;
    if (decision.kind === "deciding") return true;
    return decision.retryAtMs === null || nowMs < decision.retryAtMs;
  };

  const decide = Effect.fn("SettlementReplyGate.decide")(function* (
    input: SettlementReplyGateInput,
    runId: RunId,
    attempts: number,
  ) {
    const { runs, messages, turnItems } = yield* projections.getThreadRecords(
      input.thread.id,
      ["runs", "messages", "turnItems"],
      {
        runIds: [runId],
        messageRunIds: [runId],
        turnItemRunIds: [runId],
        turnItemTypes: ["run_interrupt_request"],
      },
    );
    const run = runs.find((candidate) => candidate.id === runId);
    const logHold = (reason: Exclude<SettlementHoldReason, "no_verdict">) =>
      Effect.logInfo("auto-settle held for the latest run", {
        threadId: input.thread.id,
        runId,
        reason,
      }).pipe(Effect.as({ kind: "holds", reason } as const));
    if (run?.status === "failed") return yield* logHold("run_failed");
    if (run?.status === "interrupted") return yield* logHold("run_interrupted");
    if (turnItems.length > 0) return yield* logHold("stop_requested");
    if (!input.checkReply) return null;
    const subject = run === undefined ? null : settlementReplySubject(run, messages);
    if (subject === null) return { kind: "settles" } as const;
    if (input.cwd === null) return yield* Effect.die(new Error("thread project not found"));
    const completedAtMs =
      input.thread.latestRunCompletedAt == null
        ? null
        : DateTime.toEpochMillis(input.thread.latestRunCompletedAt);
    const { needsUser } = yield* textGeneration
      .checkSettlementReply({
        cwd: input.cwd,
        ...subject,
        pullRequestState: input.pullRequest.state,
        pullRequestFinishedAfterReply:
          completedAtMs !== null && input.pullRequest.finishedAtMs > completedAtMs,
        modelSelection: input.modelSelection,
      })
      .pipe(Effect.timeout("30 seconds"), checks.withPermits(1));
    yield* Effect.logInfo("auto-settle reply checked", {
      threadId: input.thread.id,
      runId,
      requestOrigin: subject.requestOrigin,
      needsUser,
      attempt: attempts + 1,
    });
    return needsUser
      ? ({ kind: "holds", reason: "needs_user" } as const)
      : ({ kind: "settles" } as const);
  });

  /** Why the pull request may not settle the thread yet, or null when it may. */
  const check = (input: SettlementReplyGateInput): Effect.Effect<SettlementHoldReason | null> =>
    Effect.suspend(() => {
      const runId = input.thread.latestRunId;
      if (runId === null) return Effect.succeed(null);
      const existing = decisions.get(runId);
      if (existing?.kind === "deciding") {
        return Deferred.await(existing.decided).pipe(Effect.andThen(check(input)));
      }
      if (existing?.kind === "settles") return Effect.succeed(null);
      if (existing?.kind === "holds") {
        return Effect.succeed(
          input.checkReply || existing.reason !== "needs_user" ? existing.reason : null,
        );
      }
      if (existing?.kind === "failed" && input.checkReply) {
        const retryAtMs = existing.retryAtMs;
        if (retryAtMs === null) return Effect.succeed("no_verdict" as const);
        return DateTime.now.pipe(
          Effect.flatMap((now) =>
            DateTime.toEpochMillis(now) < retryAtMs
              ? Effect.succeed("no_verdict" as const)
              : start(input, runId, existing.attempts),
          ),
        );
      }
      return start(input, runId, existing?.kind === "failed" ? existing.attempts : 0);
    });

  // Forked into the gate's scope so a sweep that stops waiting does not abandon a verdict the next
  // sweep would otherwise ask the model for again.
  const start = (
    input: SettlementReplyGateInput,
    runId: RunId,
    attempts: number,
  ): Effect.Effect<SettlementHoldReason | null> => {
    const decided = Deferred.makeUnsafe<void>();
    remember(runId, { kind: "deciding", decided });
    return decide(input, runId, attempts).pipe(
      Effect.flatMap((decision) =>
        Effect.sync(() => {
          if (decision === null) decisions.delete(runId);
          else remember(runId, decision);
        }),
      ),
      Effect.catchCause((cause) =>
        Cause.hasInterruptsOnly(cause)
          ? Effect.sync(() => decisions.delete(runId))
          : Effect.gen(function* () {
              const delayMs = RETRY_DELAYS_MS[attempts];
              const retryAtMs =
                delayMs === undefined
                  ? null
                  : DateTime.toEpochMillis(yield* DateTime.now) + delayMs;
              remember(runId, { kind: "failed", attempts: attempts + 1, retryAtMs });
              yield* Effect.logWarning("auto-settle reply check failed; holding the thread", {
                threadId: input.thread.id,
                runId,
                attempt: attempts + 1,
                retryAt:
                  retryAtMs === null ? null : DateTime.formatIso(DateTime.makeUnsafe(retryAtMs)),
                cause: Cause.pretty(cause),
              });
            }),
      ),
      Effect.ensuring(Deferred.succeed(decided, undefined)),
      Effect.forkIn(scope),
      Effect.andThen(Deferred.await(decided)),
      Effect.andThen(
        Effect.suspend(() => {
          const decision = decisions.get(runId);
          if (decision === undefined || decision.kind === "settles") return Effect.succeed(null);
          if (decision.kind === "holds") return Effect.succeed(decision.reason);
          return Effect.succeed("no_verdict" as const);
        }),
      ),
    );
  };

  return { holds, check };
});

export type SettlementReplyGate = Effect.Success<typeof make>;
