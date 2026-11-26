import {
  CommandId,
  isDelegatedAppThread,
  isThreadMuted,
  type RunId,
  type ThreadId,
} from "@t3tools/contracts";
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";
import * as FiberMap from "effect/FiberMap";
import * as Stream from "effect/Stream";

import { forkParked } from "../serverActivation.ts";
import * as ServerSettings from "../serverSettings.ts";
import * as CompletionNotificationTriage from "./CompletionNotificationTriage.ts";
import * as Orchestrator from "./Orchestrator.ts";
import * as ProjectionStore from "./ProjectionStore.ts";

/**
 * When notification triage finds that a completed run has nothing worth an alert, records it on
 * the thread, so clients keep a monitor that keeps checking in from reading as Done or moving up.
 * It shares the verdict that already decides the alert, so it asks the model nothing new.
 */
export const make = Effect.gen(function* () {
  const orchestrator = yield* Orchestrator.OrchestratorV2;
  const projections = yield* ProjectionStore.ProjectionStoreV2;
  const serverSettings = yield* ServerSettings.ServerSettingsService;
  const triage = yield* CompletionNotificationTriage.CompletionNotificationTriage;

  const recordIfQuiet = Effect.fn("QuietRunRecorder.recordIfQuiet")(
    function* (threadId: ThreadId, runId: RunId) {
      const settings = yield* serverSettings.getSettings;
      if (!settings.notificationTriage) return;
      const thread = yield* projections.getThread(threadId);
      // Delegated threads alert through their parent, and a muted thread shows no Done to keep
      // quiet, so neither is worth a model call.
      if (thread.deletedAt !== null || isDelegatedAppThread(thread) || isThreadMuted(thread.tags)) {
        return;
      }
      if (yield* triage.shouldNotify({ threadId, runId })) return;
      yield* orchestrator.dispatch({
        type: "thread.quiet-run.record",
        // One per run, so a repeat verdict replays the receipt instead of recording again.
        commandId: CommandId.make(`server:quiet-run:${runId}`),
        threadId,
        runId,
      });
    },
    (effect, threadId, runId) =>
      effect.pipe(
        Effect.catchCause((cause) =>
          Cause.hasInterruptsOnly(cause)
            ? Effect.interrupt
            : Effect.logWarning("recording a quiet run failed", { threadId, runId, cause }),
        ),
      ),
  );

  const start = Effect.fn("QuietRunRecorder.start")(function* () {
    // Keyed by thread: a newer completed run replaces a verdict still being waited on.
    const pending = yield* FiberMap.make<ThreadId>();
    // Runs report completion more than once; each is judged once.
    const judgedRuns = new Map<ThreadId, RunId>();
    yield* forkParked(
      Stream.runForEach(orchestrator.streamDomainEvents, (event) => {
        if (event.type !== "run.updated" || event.payload.status !== "completed") {
          return Effect.void;
        }
        if (judgedRuns.get(event.threadId) === event.payload.id) return Effect.void;
        judgedRuns.set(event.threadId, event.payload.id);
        return FiberMap.run(
          pending,
          event.threadId,
          recordIfQuiet(event.threadId, event.payload.id),
        );
      }),
    );
  });
  return { start };
});
