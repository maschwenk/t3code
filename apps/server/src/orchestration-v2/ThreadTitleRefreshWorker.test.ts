import { assert, describe, it } from "@effect/vitest";
import {
  CommandId,
  EventId,
  MessageId,
  ProjectId,
  ProviderDriverKind,
  ProviderInstanceId,
  ThreadId,
} from "@t3tools/contracts";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as TestClock from "effect/testing/TestClock";

import * as SqlitePersistence from "../persistence/Sqlite.ts";
import * as ServerSettings from "../serverSettings.ts";
import * as TextGeneration from "../textGeneration/TextGeneration.ts";
import { CodexProviderCapabilitiesV2 } from "./Adapters/CodexAdapterV2.ts";
import { OrchestratorDispatchError } from "./Orchestrator.ts";
import * as ProjectStore from "./ProjectStore.ts";
import type { ProviderAdapterV2Shape } from "./ProviderAdapter.ts";
import * as ProviderAdapterRegistry from "./ProviderAdapterRegistry.ts";
import * as ThreadManagement from "./ThreadManagementService.ts";
import * as ThreadTitleRefreshWorker from "./ThreadTitleRefreshWorker.ts";
import * as ProviderReplayHarness from "./testkit/ProviderReplayHarness.ts";

describe("threadsDueForTitleRefresh", () => {
  const nowMs = Date.parse("2026-10-15T12:00:00.000Z");
  const hoursAgo = (hours: number) => DateTime.makeUnsafe(nowMs - hours * 3_600_000);
  const shell = (
    id: string,
    overrides: Partial<
      Parameters<typeof ThreadTitleRefreshWorker.threadsDueForTitleRefresh>[0][number]
    > = {},
  ) => ({
    id: ThreadId.make(id),
    archivedAt: null,
    deletedAt: null,
    titleRegeneration: null,
    latestUserMessageAt: null,
    latestRunRequestedAt: null,
    latestRunStartedAt: null,
    latestRunCompletedAt: null,
    ...overrides,
  });

  it("selects threads with a message or turn in the last three hours, newest first", () => {
    assert.deepEqual(
      ThreadTitleRefreshWorker.threadsDueForTitleRefresh(
        [
          shell("message-2h", { latestUserMessageAt: hoursAgo(2) }),
          shell("turn-1h", { latestUserMessageAt: hoursAgo(5), latestRunCompletedAt: hoursAgo(1) }),
          shell("edge-3h", { latestRunStartedAt: hoursAgo(3) }),
          shell("message-4h", { latestUserMessageAt: hoursAgo(4) }),
          shell("no-activity"),
        ],
        nowMs,
      ),
      ["turn-1h", "message-2h", "edge-3h"].map((id) => ThreadId.make(id)),
    );
  });

  it("skips archived, deleted and already regenerating threads, and lists a thread once", () => {
    const active = { latestUserMessageAt: hoursAgo(1) };
    assert.deepEqual(
      ThreadTitleRefreshWorker.threadsDueForTitleRefresh(
        [
          shell("archived", { ...active, archivedAt: hoursAgo(0) }),
          shell("deleted", { ...active, deletedAt: hoursAgo(0) }),
          shell("regenerating", {
            ...active,
            titleRegeneration: { requestId: CommandId.make("pending"), startedAt: hoursAgo(0) },
          }),
          shell("repeated", active),
          shell("repeated", active),
        ],
        nowMs,
      ),
      [ThreadId.make("repeated")],
    );
  });
});

const projectId = ProjectId.make("project:title-refresh");
const modelSelection = {
  instanceId: ProviderInstanceId.make("codex"),
  model: "gpt-5.1-codex",
} as const;
const rejectedThreadId = ThreadId.make("thread:title-refresh:rejected");

const adapter = {
  instanceId: modelSelection.instanceId,
  driver: ProviderDriverKind.make("codex"),
  getCapabilities: () => Effect.succeed(CodexProviderCapabilitiesV2),
  planSelectionTransition: () => Effect.succeed({ type: "apply_on_next_turn" as const }),
  openSession: () => Effect.die("provider execution is disabled in title refresh tests"),
} as ProviderAdapterV2Shape;

function makeLayer() {
  const layerDatabase = SqlitePersistence.layerMemory;
  const layerOrchestrator = ProviderReplayHarness.layerWithRegistry(
    { name: "thread-title-refresh" },
    ProviderAdapterRegistry.layerFromAdapters([adapter]),
    {
      databaseLayer: layerDatabase,
      textGeneration: Layer.mock(TextGeneration.TextGeneration)({
        generateThreadTitle: (input) =>
          Effect.succeed({ title: `Renamed: ${input.message.split("\n").at(-1)}` }),
      }),
    },
  );
  // The orchestrator rejects one thread's regeneration, as it does for a
  // thread deleted after the pass read the shell snapshot.
  const layerThreadManagement = Layer.effect(
    ThreadManagement.ThreadManagementService,
    Effect.gen(function* () {
      const threads = yield* ThreadManagement.ThreadManagementService;
      return ThreadManagement.ThreadManagementService.of({
        ...threads,
        dispatch: (command) =>
          command.type === "thread.metadata.update" && command.threadId === rejectedThreadId
            ? Effect.fail(
                new OrchestratorDispatchError({
                  commandId: command.commandId,
                  commandType: command.type,
                }),
              )
            : threads.dispatch(command),
      });
    }),
  ).pipe(Layer.provide(ThreadManagement.layer.pipe(Layer.provide(layerOrchestrator))));
  return Layer.mergeAll(
    layerThreadManagement,
    ProjectStore.layer.pipe(Layer.provide(layerDatabase)),
    ServerSettings.layerTest({}),
  );
}

const seedProject = Effect.flatMap(ProjectStore.ProjectStoreV2, (projects) =>
  projects.apply({
    sequence: 0,
    eventId: EventId.make(`seed:${projectId}`),
    aggregateKind: "project",
    aggregateId: projectId,
    occurredAt: "1970-01-01T00:00:00.000Z",
    commandId: null,
    causationEventId: null,
    correlationId: null,
    metadata: {},
    type: "project.created",
    payload: {
      projectId,
      title: "Title refresh",
      workspaceRoot: "/repo",
      defaultModelSelection: modelSelection,
      scripts: [],
      createdAt: "1970-01-01T00:00:00.000Z",
      updatedAt: "1970-01-01T00:00:00.000Z",
    },
  }),
);

const startThread = (threadId: ThreadId, text: string) =>
  Effect.gen(function* () {
    const threads = yield* ThreadManagement.ThreadManagementService;
    yield* threads.dispatch({
      type: "thread.create",
      commandId: CommandId.make(`create:${threadId}`),
      threadId,
      projectId,
      title: "Seed title",
      modelSelection,
      runtimeMode: "full-access",
      interactionMode: "default",
      branch: null,
      worktreePath: null,
      createdBy: "user",
      creationSource: "web",
    });
    yield* threads.dispatch({
      type: "message.dispatch",
      commandId: CommandId.make(`message:${threadId}`),
      threadId,
      messageId: MessageId.make(`message:${threadId}`),
      text,
      attachments: [],
      modelSelection,
      dispatchMode: { type: "defer_start" },
      createdBy: "user",
      creationSource: "web",
    });
  });

it.effect("renames threads active in the last three hours past a rejected regeneration", () =>
  Effect.gen(function* () {
    const threads = yield* ThreadManagement.ThreadManagementService;
    const stale = ThreadId.make("thread:title-refresh:stale");
    const earlier = ThreadId.make("thread:title-refresh:earlier");
    const recent = ThreadId.make("thread:title-refresh:recent");
    yield* seedProject;
    yield* startThread(stale, "Stale work");
    yield* TestClock.adjust("90 minutes");
    yield* startThread(earlier, "Earlier work");
    yield* TestClock.adjust("30 minutes");
    yield* startThread(recent, "Recent work");
    yield* TestClock.adjust("30 minutes");
    // Newest activity, so its rejection comes before the others are refreshed.
    yield* startThread(rejectedThreadId, "Rejected work");
    yield* TestClock.adjust("90 minutes");

    const pass = yield* ThreadTitleRefreshWorker.makeRefreshPass;
    yield* pass();

    const titles = yield* Effect.forEach([stale, earlier, recent, rejectedThreadId], (threadId) =>
      threads.getThreadShell(threadId).pipe(Effect.map((shell) => shell?.title)),
    );
    assert.deepEqual(titles, [
      "Seed title",
      "Renamed: Earlier work",
      "Renamed: Recent work",
      "Seed title",
    ]);
  }).pipe(Effect.provide(makeLayer())),
);
