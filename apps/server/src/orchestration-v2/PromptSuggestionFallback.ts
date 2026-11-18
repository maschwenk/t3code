import { resolveProjectSettings } from "@t3tools/shared/projectSettings";
import {
  isDelegatedAppThread,
  type OrchestrationV2ConversationMessage,
  type OrchestrationV2Run,
  type RunId,
  type ThreadId,
} from "@t3tools/contracts";
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";
import * as FiberMap from "effect/FiberMap";
import * as Option from "effect/Option";
import * as Stream from "effect/Stream";

import { forkParked } from "../serverActivation.ts";
import * as ServerSettings from "../serverSettings.ts";
import * as TextGeneration from "../textGeneration/TextGeneration.ts";
import { earlierTriageRunIds, lastFinishedReply } from "./CompletionNotificationTriage.ts";
import * as Orchestrator from "./Orchestrator.ts";
import * as ProjectionStore from "./ProjectionStore.ts";
import * as ProjectStore from "./ProjectStore.ts";
import * as ProviderSessionManager from "./ProviderSessionManager.ts";

/**
 * Drivers whose own next-prompt suggestions this backs up. Claude Code drops some of its
 * predictions, such as any one-word reply outside a short allowlist ("send", "submit").
 * Codex samples its own suggestion through the thread, and other drivers offer none.
 */
const FALLBACK_DRIVERS: ReadonlySet<string> = new Set(["claudeAgent"]);

/** Claude Code sends 97% of its suggestions within 10 seconds of a turn's result. */
const PROVIDER_GRACE = "10 seconds";

/** Claude Code drops suggestions this long or longer, so the composer never shows one. */
const MAX_SUGGESTION_LENGTH = 100;

type SuggestionMessage = Pick<
  OrchestrationV2ConversationMessage,
  "id" | "runId" | "role" | "text" | "streaming" | "createdBy" | "scheduledTaskId"
>;

/**
 * What the model reads to predict the user's next message after `run`, or null when the run has
 * no finished reply to answer. `earlierRunIds` are newest first.
 */
export function promptSuggestionSubject(
  run: Pick<OrchestrationV2Run, "id" | "status" | "userMessageId"> | undefined,
  messages: ReadonlyArray<SuggestionMessage>,
  earlierRunIds: ReadonlyArray<RunId>,
): {
  readonly request: string;
  readonly reply: string;
  readonly earlierRequests: ReadonlyArray<string>;
} | null {
  if (run?.status !== "completed") return null;
  const reply = lastFinishedReply(messages, run.id);
  if (reply === undefined) return null;
  // Steering messages sent mid-run belong to the request too.
  const request = messages
    .filter(
      (message) =>
        message.runId === run.id &&
        message.role === "user" &&
        (message.id === run.userMessageId || message.createdBy === "user"),
    )
    .map((message) => message.text.trim())
    .filter((text) => text !== "")
    .join("\n\n");
  if (request === "") return null;
  const earlierRequests = earlierRunIds.flatMap((runId) =>
    messages
      .filter(
        (message) =>
          message.runId === runId &&
          message.role === "user" &&
          message.createdBy === "user" &&
          message.scheduledTaskId === undefined &&
          message.text.trim() !== "",
      )
      .map((message) => message.text.trim())
      .toReversed(),
  );
  return { request, reply, earlierRequests };
}

/** The model's suggestion as the composer shows it, or null when it is empty or unusable. */
export function cleanPromptSuggestion(text: string): string | null {
  let cleaned = text.trim();
  const wrapped = /^(["'`“‘])([\s\S]*)(["'`”’])$/.exec(cleaned);
  if (wrapped !== null) cleaned = (wrapped[2] ?? "").trim();
  if (cleaned === "" || /[\r\n]/.test(cleaned) || cleaned.length >= MAX_SUGGESTION_LENGTH) {
    return null;
  }
  return cleaned;
}

/**
 * Labs: when a Claude run completes and Claude Code offers no next-prompt suggestion within a
 * few seconds, asks the text generation model for one. Claude Code's own suggestion still
 * replaces it if it arrives later. Timers live in memory, so a restart skips pending ones.
 */
export const make = Effect.gen(function* () {
  const orchestrator = yield* Orchestrator.OrchestratorV2;
  const projections = yield* ProjectionStore.ProjectionStoreV2;
  const projects = yield* ProjectStore.ProjectStoreV2;
  const sessions = yield* ProviderSessionManager.ProviderSessionManagerV2;
  const serverSettings = yield* ServerSettings.ServerSettingsService;
  const textGeneration = yield* TextGeneration.TextGeneration;

  /** The run's thread when the run is still the thread's latest and nothing has suggested for it. */
  const stillUnanswered = Effect.fn("PromptSuggestionFallback.stillUnanswered")(function* (
    threadId: ThreadId,
    runId: RunId,
  ) {
    const { thread, runs } = yield* projections.getThreadRecords(threadId, ["runs"]);
    const latest = runs.reduce<(typeof runs)[number] | undefined>(
      (found, run) => (found === undefined || run.ordinal > found.ordinal ? run : found),
      undefined,
    );
    if (latest?.id !== runId || latest.status !== "completed") return null;
    const stored = yield* Stream.runHead(sessions.subscribePromptSuggestion(threadId));
    if (Option.getOrNull(stored)?.runId === runId) return null;
    return { thread, runs };
  });

  const suggestWhenQuiet = Effect.fn("PromptSuggestionFallback.suggestWhenQuiet")(
    function* (threadId: ThreadId, runId: RunId) {
      const settings = yield* serverSettings.getSettings;
      if (!settings.promptSuggestionsEnabled) return;
      const thread = yield* projections.getThread(threadId);
      const driver = Object.hasOwn(settings.providerInstances, thread.providerInstanceId)
        ? settings.providerInstances[thread.providerInstanceId]?.driver
        : thread.providerInstanceId;
      // Delegated threads have no one typing, so they never get suggestions.
      if (
        driver === undefined ||
        !FALLBACK_DRIVERS.has(driver) ||
        thread.deletedAt !== null ||
        isDelegatedAppThread(thread)
      ) {
        return;
      }

      yield* Effect.sleep(PROVIDER_GRACE);
      const unanswered = yield* stillUnanswered(threadId, runId);
      if (unanswered === null) return;
      const run = unanswered.runs.find((candidate) => candidate.id === runId);
      const earlierRunIds = earlierTriageRunIds(run, unanswered.runs);
      const { messages } = yield* projections.getThreadRecords(threadId, ["messages"], {
        messageRunIds: [runId, ...earlierRunIds],
      });
      const subject = promptSuggestionSubject(run, messages, earlierRunIds);
      if (subject === null) return;
      const project = yield* projects.get(unanswered.thread.projectId);
      if (Option.isNone(project)) return;
      const { suggestion } = yield* textGeneration
        .suggestNextPrompt({
          cwd: unanswered.thread.worktreePath ?? project.value.workspaceRoot,
          ...subject,
          modelSelection: resolveProjectSettings(settings, unanswered.thread.projectId).settings
            .textGenerationModelSelection,
        })
        .pipe(Effect.timeout("30 seconds"));
      const text = cleanPromptSuggestion(suggestion);
      // The user may have sent another message while the model was answering.
      const offered =
        text !== null &&
        (yield* stillUnanswered(threadId, runId)) !== null &&
        (yield* sessions.offerPromptSuggestion(threadId, { runId, text }));
      yield* Effect.logInfo("prompt suggestion fallback", {
        threadId,
        runId,
        outcome: offered ? "offered" : text === null ? "none" : "superseded",
      });
    },
    (effect, threadId, runId) =>
      effect.pipe(
        Effect.catchCause((cause) =>
          Cause.hasInterruptsOnly(cause)
            ? Effect.interrupt
            : Effect.logWarning("prompt suggestion fallback failed", { threadId, runId, cause }),
        ),
      ),
  );

  const start = Effect.fn("PromptSuggestionFallback.start")(function* () {
    // Keyed by thread: a newer completed run replaces the waiting timer.
    const timers = yield* FiberMap.make<ThreadId>();
    // Runs report completion more than once; each gets one timer.
    const timedRuns = new Map<ThreadId, RunId>();
    yield* forkParked(
      Stream.runForEach(orchestrator.streamDomainEvents, (event) => {
        if (event.type !== "run.updated" || event.payload.status !== "completed") {
          return Effect.void;
        }
        if (timedRuns.get(event.threadId) === event.payload.id) return Effect.void;
        timedRuns.set(event.threadId, event.payload.id);
        return FiberMap.run(
          timers,
          event.threadId,
          suggestWhenQuiet(event.threadId, event.payload.id),
        );
      }),
    );
  });
  return { start };
});
