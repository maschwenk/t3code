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
 * window, newest first, each once. A thread with a title generation already
 * in flight is left to that request.
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
): ReadonlyArray<ThreadId> {
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
    if (activityMs >= windowStartMs) due.set(thread.id, activityMs);
  }
  return [...due].sort(([, left], [, right]) => right - left).map(([threadId]) => threadId);
}

/** One refresh pass; `layer` runs it every `TITLE_REFRESH_INTERVAL`. */
export const makeRefreshPass = Effect.gen(function* () {
  const threads = yield* ThreadManagement.ThreadManagementService;
  const settings = yield* ServerSettings.ServerSettingsService;

  const refreshTitle = Effect.fn("ThreadTitleRefreshWorker.refreshTitle")(function* (
    threadId: ThreadId,
    requestId: CommandId,
  ) {
    const dispatched = yield* threads.dispatch({
      type: "thread.metadata.update",
      commandId: requestId,
      threadId,
      regenerateTitle: true,
    });
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
      threadsDueForTitleRefresh(snapshot.threads, nowMs),
      (threadId) =>
        refreshTitle(threadId, CommandId.make(`title-refresh:${threadId}:${nowMs}`)).pipe(
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
