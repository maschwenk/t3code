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

/**
 * What the model reads to triage a completed run, or null when the run alerts
 * without asking: the user typed the request and is waiting on the answer, or
 * there is no reply to judge.
 */
export function completionTriageSubject(
  run: Pick<OrchestrationV2Run, "status" | "userMessageId"> | undefined,
  messages: ReadonlyArray<
    Pick<
      OrchestrationV2ConversationMessage,
      "id" | "role" | "text" | "streaming" | "createdBy" | "scheduledTaskId"
    >
  >,
): { readonly request: string; readonly reply: string } | null {
  if (run?.status !== "completed") return null;
  const request = messages.find((message) => message.id === run.userMessageId);
  if (request === undefined) return null;
  if (request.createdBy === "user" && request.scheduledTaskId === undefined) return null;
  const reply = messages.findLast(
    (message) => message.role === "assistant" && !message.streaming && message.text.trim() !== "",
  );
  return reply === undefined ? null : { request: request.text, reply: reply.text };
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
      const projection = yield* threads.getThreadRecords(input.threadId, ["runs", "messages"], {
        runIds: [input.runId],
        messageRunIds: [input.runId],
      });
      const subject = completionTriageSubject(
        projection.runs.find((run) => run.id === input.runId),
        projection.messages,
      );
      if (subject === null) return true;
      const project = yield* projects.get(projection.thread.projectId);
      if (Option.isNone(project)) return true;
      const { notify } = yield* textGeneration
        .triageCompletion({
          cwd: projection.thread.worktreePath ?? project.value.workspaceRoot,
          ...subject,
          modelSelection: resolveProjectSettings(settings, projection.thread.projectId).settings
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
