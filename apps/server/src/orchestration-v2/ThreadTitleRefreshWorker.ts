import { CommandId, type OrchestrationV2ThreadShell, type ThreadId } from "@t3tools/contracts";
import * as Cause from "effect/Cause";
import * as DateTime from "effect/DateTime";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Stream from "effect/Stream";

import { forkParked } from "../serverActivation.ts";
import * as ServerSettings from "../serverSettings.ts";
import * as ThreadManagement from "./ThreadManagementService.ts";

const TITLE_REFRESH_INTERVAL = Duration.minutes(30);
const TITLE_REFRESH_ACTIVITY_WINDOW = Duration.hours(3);
// Title generation runs on the shared effect worker; leave its other slots for turns.
const TITLE_REFRESH_CONCURRENCY = 2;
// Longer than any provider's title generation timeout, so a slot frees only when work is stuck.
const TITLE_REFRESH_SETTLE_TIMEOUT = Duration.minutes(4);

/**
 * Threads whose latest user message or agent turn falls inside the activity
 * window, newest first, each once, with that activity time. A thread with a
 * title generation already in flight is left to that request, and one with no
 * activity after the time recorded in `refreshedActivityMs` is skipped.
 */
export function threadsDueForTitleRefresh(
  threads: ReadonlyArray<
    Pick<
      OrchestrationV2ThreadShell,
      | "id"
      | "archivedAt"
      | "deletedAt"
      | "titleRegeneration"
      | "latestUserMessageAt"
      | "latestRunRequestedAt"
      | "latestRunStartedAt"
      | "latestRunCompletedAt"
    >
  >,
  nowMs: number,
  refreshedActivityMs: ReadonlyMap<ThreadId, number> = new Map(),
): ReadonlyArray<{ readonly threadId: ThreadId; readonly activityMs: number }> {
  const windowStartMs = nowMs - Duration.toMillis(TITLE_REFRESH_ACTIVITY_WINDOW);
  const due = new Map<ThreadId, number>();
  for (const thread of threads) {
    if (thread.archivedAt !== null || thread.deletedAt !== null || thread.titleRegeneration) {
      continue;
    }
    const activityMs = Math.max(
      ...[
        thread.latestUserMessageAt,
        thread.latestRunRequestedAt,
        thread.latestRunStartedAt,
        thread.latestRunCompletedAt,
      ].flatMap((value) => (value == null ? [] : [DateTime.toEpochMillis(value)])),
    );
    if (
      activityMs >= windowStartMs &&
      activityMs > (refreshedActivityMs.get(thread.id) ?? Number.NEGATIVE_INFINITY)
    ) {
      due.set(thread.id, activityMs);
    }
  }
  return [...due]
    .sort(([, left], [, right]) => right - left)
    .map(([threadId, activityMs]) => ({ threadId, activityMs }));
}

/** One refresh pass; `layer` runs it every `TITLE_REFRESH_INTERVAL`. */
export const makeRefreshPass = Effect.gen(function* () {
  const threads = yield* ThreadManagement.ThreadManagementService;
  const settings = yield* ServerSettings.ServerSettingsService;
  // Activity each thread had when its last rename was sent. A restart forgets
  // it, which costs at most one extra rename per thread.
  const refreshedActivityMs = new Map<ThreadId, number>();

  const refreshTitle = Effect.fn("ThreadTitleRefreshWorker.refreshTitle")(function* (
    threadId: ThreadId,
    activityMs: number,
    requestId: CommandId,
  ) {
    const dispatched = yield* threads.dispatch({
      type: "thread.metadata.update",
      commandId: requestId,
      threadId,
      regenerateTitle: true,
    });
    refreshedActivityMs.set(threadId, activityMs);
    // Holding the slot until this request's marker clears bounds the work
    // the pass puts on the effect worker at once.
    yield* threads
      .streamStoredEventsFrom({
        threadId,
        afterSequence: dispatched.sequence,
        eventType: "thread.metadata-updated",
      })
      .pipe(
        Stream.filter(
          ({ event }) =>
            event.type === "thread.metadata-updated" &&
            event.payload.titleRegeneration?.requestId !== requestId,
        ),
        Stream.runHead,
        Effect.timeoutOption(TITLE_REFRESH_SETTLE_TIMEOUT),
      );
  });

  return Effect.fn("ThreadTitleRefreshWorker.pass")(function* () {
    if (!(yield* settings.getSettings).autoRenameRecentThreads) return;
    const nowMs = DateTime.toEpochMillis(yield* DateTime.now);
    const snapshot = yield* threads.getShellSnapshot({ location: "active" });
    yield* Effect.forEach(
      threadsDueForTitleRefresh(snapshot.threads, nowMs, refreshedActivityMs),
      ({ threadId, activityMs }) =>
        refreshTitle(
          threadId,
          activityMs,
          CommandId.make(`title-refresh:${threadId}:${nowMs}`),
        ).pipe(
          Effect.catchCause((cause) =>
            Cause.hasInterruptsOnly(cause)
              ? Effect.interrupt
              : Effect.logWarning("Thread title refresh failed", { threadId, cause }),
          ),
        ),
      { concurrency: TITLE_REFRESH_CONCURRENCY, discard: true },
    );
  });
});

export const layer = Layer.effectDiscard(
  Effect.gen(function* () {
    const pass = yield* makeRefreshPass;
    yield* forkParked(
      Effect.sleep(TITLE_REFRESH_INTERVAL).pipe(
        Effect.andThen(pass()),
        Effect.catchCause((cause) =>
          Cause.hasInterruptsOnly(cause)
            ? Effect.interrupt
            : Effect.logWarning("Thread title refresh pass failed", { cause }),
        ),
        Effect.forever,
      ),
    );
  }),
);
