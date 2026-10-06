import * as Scheduler from "../scheduling/Scheduler.ts";
import * as NodeCrypto from "@effect/platform-node/NodeCrypto";
import { assert, it } from "@effect/vitest";
import { ScheduledTaskUpsertInput, scheduledTaskLifecycle } from "@t3tools/contracts";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Ref from "effect/Ref";
import * as Schema from "effect/Schema";
import * as SqlClient from "effect/sql/SqlClient";
import * as TestClock from "effect/testing/TestClock";

import * as ThreadLaunchService from "../orchestration-v2/ThreadLaunchService.ts";
import * as ThreadManagementService from "../orchestration-v2/ThreadManagementService.ts";
import * as SecretRequests from "../secrets/SecretRequests.ts";
import * as SqlitePersistence from "../persistence/Sqlite.ts";
import * as ScheduledTaskService from "./ScheduledTaskService.ts";

const decodeUpsertInput = Schema.decodeUnknownEffect(ScheduledTaskUpsertInput);
const START = Date.parse("2026-09-09T12:00:00.000Z");

/** Records each prompt posted into a thread. Bookkeeping is the same whether the send succeeds or fails. */
const layerRecordingSends = (sends: Ref.Ref<ReadonlyArray<string>>) =>
  Layer.mergeAll(
    NodeCrypto.layer,
    Scheduler.layer,
    Layer.mock(ThreadLaunchService.ThreadLaunchService)({}),
    Layer.mock(ThreadManagementService.ThreadManagementService)({
      sendToThread: (input) =>
        Ref.update(sends, (all) => [...all, `${input.threadId}:${input.text}`]).pipe(
          Effect.andThen(Effect.die(new Error("send recorded"))),
        ),
    }),
    Layer.mock(SecretRequests.SecretRequests)({}),
  );

// The poll loop sleeps five seconds between passes; stepping the clock by
// that much lets each pass finish before the next one is due.
const advanceMinutes = (minutes: number) =>
  Effect.forEach(Array.from({ length: minutes * 12 }), () => TestClock.adjust("5 seconds"), {
    discard: true,
  });

it.effect("posts a thread-bound schedule into its thread until the end time, then ends", () =>
  Effect.gen(function* () {
    yield* TestClock.setTime(START);
    const sends = yield* Ref.make<ReadonlyArray<string>>([]);
    yield* Effect.gen(function* () {
      const service = yield* ScheduledTaskService.ScheduledTaskService;
      const created = yield* service.upsert(
        yield* decodeUpsertInput({
          title: "Tell the time",
          prompt: "Tell me the current time.",
          enabled: true,
          schedule: { type: "interval", everyMs: 60_000 },
          endsAt: new Date(START + 3 * 60_000).toISOString(),
          projectId: "project-end-time",
          threadId: "thread-end-time",
          workspaceStrategy: { type: "root" },
          modelSelection: { instanceId: "claudeAgent", model: "claude-sonnet-4-5" },
          runtimeMode: "full-access",
          interactionMode: "default",
          creationSource: "mcp",
        }),
      );
      assert.equal(created.task.nextRunAt, new Date(START + 60_000).toISOString());

      // "Every minute for the next 3 minutes" is three runs, the last exactly
      // at the end, even though each run starts a little after its slot.
      yield* advanceMinutes(10);
      assert.deepEqual(yield* Ref.get(sends), [
        "thread-end-time:Tell me the current time.",
        "thread-end-time:Tell me the current time.",
        "thread-end-time:Tell me the current time.",
      ]);
      const [task] = (yield* service.list()).tasks;
      assert.equal(task?.runCount, 3);
      assert.isNull(task?.nextRunAt);
      assert.equal(task === undefined ? null : scheduledTaskLifecycle(task), "ended");

      // Resuming cannot reopen an ended schedule; moving its end later does.
      const resumed = yield* service.setEnabled({ id: created.task.id, enabled: true });
      assert.isNull(resumed.task.nextRunAt);
      const extended = yield* service.upsert(
        yield* decodeUpsertInput({
          id: created.task.id,
          title: "Tell the time",
          prompt: "Tell me the current time.",
          enabled: true,
          schedule: { type: "interval", everyMs: 60_000 },
          endsAt: new Date(START + 20 * 60_000).toISOString(),
          projectId: "project-end-time",
          threadId: "thread-end-time",
          workspaceStrategy: { type: "root" },
          modelSelection: { instanceId: "claudeAgent", model: "claude-sonnet-4-5" },
          runtimeMode: "full-access",
          interactionMode: "default",
        }),
      );
      assert.isNotNull(extended.task.nextRunAt);
      assert.equal(scheduledTaskLifecycle(extended.task), "active");
    }).pipe(
      Effect.provide(ScheduledTaskService.layer.pipe(Layer.provide(layerRecordingSends(sends)))),
    );
  }).pipe(Effect.provide(SqlitePersistence.layerMemory)),
);

it.effect("stops after its run budget", () =>
  Effect.gen(function* () {
    yield* TestClock.setTime(START);
    const sends = yield* Ref.make<ReadonlyArray<string>>([]);
    yield* Effect.gen(function* () {
      const service = yield* ScheduledTaskService.ScheduledTaskService;
      yield* service.upsert(
        yield* decodeUpsertInput({
          title: "Check twice",
          prompt: "Check CI.",
          enabled: true,
          schedule: { type: "interval", everyMs: 60_000 },
          maxRuns: 2,
          projectId: "project-max-runs",
          threadId: "thread-max-runs",
          workspaceStrategy: { type: "root" },
          modelSelection: { instanceId: "claudeAgent", model: "claude-sonnet-4-5" },
          runtimeMode: "full-access",
          interactionMode: "default",
        }),
      );
      yield* advanceMinutes(5);
      assert.equal((yield* Ref.get(sends)).length, 2);
      const [task] = (yield* service.list()).tasks;
      assert.equal(task === undefined ? null : scheduledTaskLifecycle(task), "ended");
    }).pipe(
      Effect.provide(ScheduledTaskService.layer.pipe(Layer.provide(layerRecordingSends(sends)))),
    );
  }).pipe(Effect.provide(SqlitePersistence.layerMemory)),
);

it.effect("ends a schedule whose end passed while the server was down without running it", () =>
  Effect.gen(function* () {
    const sql = yield* SqlClient.SqlClient;
    const stored = new Date(START).toISOString();
    yield* sql`INSERT INTO scheduled_tasks ${sql.insert({
      task_id: "scheduled-task:missed-end",
      title: "Watch deploys",
      prompt: "Check #deploys.",
      enabled: 1,
      schedule_json: '{"type":"interval","everyMs":900000}',
      project_id: "project-missed-end",
      thread_id: "thread-missed-end",
      workspace_strategy_json: '{"type":"root"}',
      model_selection_json: '{"instanceId":"codex","model":"gpt-5"}',
      runtime_mode: "full-access",
      interaction_mode: "default",
      created_by: "agent",
      creation_source: "mcp",
      created_at: stored,
      updated_at: stored,
      next_run_at: new Date(START + 15 * 60_000).toISOString(),
      last_run_at: null,
      last_run_status: "never",
      last_run_error: null,
      run_count: 0,
      ends_at: new Date(START + 20 * 60_000).toISOString(),
    })}`;
    // The server comes back an hour later, long after the end.
    yield* TestClock.setTime(START + 60 * 60_000);
    const sends = yield* Ref.make<ReadonlyArray<string>>([]);
    yield* Effect.gen(function* () {
      const service = yield* ScheduledTaskService.ScheduledTaskService;
      yield* advanceMinutes(1);
      assert.deepEqual(yield* Ref.get(sends), []);
      const [task] = (yield* service.list()).tasks;
      assert.isNull(task?.nextRunAt);
      assert.equal(task?.runCount, 0);
      assert.equal(task === undefined ? null : scheduledTaskLifecycle(task), "ended");
    }).pipe(
      Effect.provide(ScheduledTaskService.layer.pipe(Layer.provide(layerRecordingSends(sends)))),
    );
  }).pipe(Effect.provide(SqlitePersistence.layerMemory)),
);
