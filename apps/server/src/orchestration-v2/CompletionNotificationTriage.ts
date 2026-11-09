import { resolveProjectSettings } from "@t3tools/shared/projectSettings";
import type {
  CompletionNotificationTriageInput,
  OrchestrationV2ConversationMessage,
  OrchestrationV2Run,
  RunId,
} from "@t3tools/contracts";
import * as Cause from "effect/Cause";
import * as Context from "effect/Context";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";

import * as ServerSettings from "../serverSettings.ts";
import * as TextGeneration from "../textGeneration/TextGeneration.ts";
import * as ProjectStore from "./ProjectStore.ts";
import * as ThreadManagementService from "./ThreadManagementService.ts";

// Runs end at human pace, so this covers every completion clients can still be alerting on.
const REMEMBERED_VERDICTS = 500;

export class CompletionNotificationTriage extends Context.Service<
  CompletionNotificationTriage,
  {
    /**
     * Whether a completed run deserves an alert. Each run is decided once and
     * shared by every caller. Anything that goes wrong alerts.
     */
    readonly shouldNotify: (input: CompletionNotificationTriageInput) => Effect.Effect<boolean>;
    /**
     * The verdict without waiting: always alert while triage is off, and none
     * until `shouldNotify` has decided the run.
     */
    readonly peek: (
      input: CompletionNotificationTriageInput,
    ) => Effect.Effect<Option.Option<boolean>>;
  }
>()("t3/orchestration-v2/CompletionNotificationTriage") {}

// Three runs back still catches a blocker or ask that only comes up every few check-ins.
const EARLIER_REPLIES = 3;

type TriageMessage = Pick<
  OrchestrationV2ConversationMessage,
  "id" | "runId" | "role" | "text" | "streaming" | "createdBy" | "scheduledTaskId"
>;

/** The text of the run's last finished, non-blank assistant message. */
export function lastFinishedReply(messages: ReadonlyArray<TriageMessage>, runId: RunId) {
  return messages.findLast(
    (message) =>
      message.runId === runId &&
      message.role === "assistant" &&
      !message.streaming &&
      message.text.trim() !== "",
  )?.text;
}

/**
 * The runs whose replies the model compares against: the ones just before
 * `run` in the thread, newest first.
 */
export function earlierTriageRunIds(
  run: Pick<OrchestrationV2Run, "ordinal"> | undefined,
  runs: ReadonlyArray<Pick<OrchestrationV2Run, "id" | "ordinal">>,
): ReadonlyArray<RunId> {
  if (run === undefined) return [];
  return runs
    .filter((candidate) => candidate.ordinal < run.ordinal)
    .toSorted((a, b) => b.ordinal - a.ordinal)
    .slice(0, EARLIER_REPLIES)
    .map((candidate) => candidate.id);
}

/**
 * What the model reads to triage a completed run, or null when the run alerts
 * without asking: the user typed the request and is waiting on the answer, or
 * there is no reply to judge. `earlierRunIds` are newest first.
 */
export function completionTriageSubject(
  run: Pick<OrchestrationV2Run, "id" | "status" | "userMessageId"> | undefined,
  messages: ReadonlyArray<TriageMessage>,
  earlierRunIds: ReadonlyArray<RunId> = [],
): {
  readonly request: string;
  readonly reply: string;
  readonly earlierReplies: ReadonlyArray<string>;
} | null {
  if (run?.status !== "completed") return null;
  const request = messages.find((message) => message.id === run.userMessageId);
  if (request === undefined) return null;
  if (request.createdBy === "user" && request.scheduledTaskId === undefined) return null;
  const reply = lastFinishedReply(messages, run.id);
  if (reply === undefined) return null;
  const earlierReplies = earlierRunIds.flatMap((runId) => lastFinishedReply(messages, runId) ?? []);
  return { request: request.text, reply, earlierReplies };
}

const make = Effect.gen(function* () {
  const threads = yield* ThreadManagementService.ThreadManagementService;
  const projects = yield* ProjectStore.ProjectStoreV2;
  const serverSettings = yield* ServerSettings.ServerSettingsService;
  const textGeneration = yield* TextGeneration.TextGeneration;
  const scope = yield* Effect.scope;
  const verdicts = new Map<
    RunId,
    { readonly decided: Deferred.Deferred<boolean>; notify: boolean | undefined }
  >();

  const decide = Effect.fn("CompletionNotificationTriage.decide")(
    function* (input: CompletionNotificationTriageInput) {
      const settings = yield* serverSettings.getSettings;
      if (!settings.notificationTriage) return true;
      const { thread, runs } = yield* threads.getThreadRecords(input.threadId, ["runs"]);
      const run = runs.find((candidate) => candidate.id === input.runId);
      const earlierRunIds = earlierTriageRunIds(run, runs);
      const { messages } = yield* threads.getThreadRecords(input.threadId, ["messages"], {
        messageRunIds: [input.runId, ...earlierRunIds],
      });
      const subject = completionTriageSubject(run, messages, earlierRunIds);
      if (subject === null) return true;
      const project = yield* projects.get(thread.projectId);
      if (Option.isNone(project)) return true;
      const { notify } = yield* textGeneration
        .triageCompletion({
          cwd: thread.worktreePath ?? project.value.workspaceRoot,
          ...subject,
          modelSelection: resolveProjectSettings(settings, thread.projectId).settings
            .textGenerationModelSelection,
        })
        .pipe(Effect.timeout("30 seconds"));
      yield* Effect.logInfo("completion notification triaged", { ...input, notify });
      return notify;
    },
    (effect, input) =>
      effect.pipe(
        Effect.catchCause((cause) =>
          Cause.hasInterruptsOnly(cause)
            ? Effect.interrupt
            : Effect.logWarning("completion notification triage failed; alerting", {
                ...input,
                cause,
              }).pipe(Effect.as(true)),
        ),
      ),
  );

  const shouldNotify: CompletionNotificationTriage["Service"]["shouldNotify"] = (input) =>
    Effect.suspend(() => {
      const existing = verdicts.get(input.runId);
      if (existing !== undefined) return Deferred.await(existing.decided);
      const entry = {
        decided: Deferred.makeUnsafe<boolean>(),
        notify: undefined as boolean | undefined,
      };
      verdicts.set(input.runId, entry);
      if (verdicts.size > REMEMBERED_VERDICTS) {
        const oldest = verdicts.keys().next().value;
        if (oldest !== undefined) verdicts.delete(oldest);
      }
      // Forked into the service scope so a caller that stops waiting, such as
      // a dropped RPC, does not abandon the verdict other callers share.
      return decide(input).pipe(
        Effect.tap((notify) =>
          Effect.sync(() => {
            entry.notify = notify;
          }),
        ),
        Effect.flatMap((notify) => Deferred.succeed(entry.decided, notify)),
        Effect.forkIn(scope),
        Effect.andThen(Deferred.await(entry.decided)),
      );
    });

  const peek: CompletionNotificationTriage["Service"]["peek"] = (input) =>
    serverSettings.getSettings.pipe(
      Effect.map((settings) =>
        settings.notificationTriage
          ? Option.fromUndefinedOr(verdicts.get(input.runId)?.notify)
          : Option.some(true),
      ),
      Effect.orElseSucceed(() => Option.some(true)),
    );

  return CompletionNotificationTriage.of({ shouldNotify, peek });
});

export const layer = Layer.effect(CompletionNotificationTriage, make);
