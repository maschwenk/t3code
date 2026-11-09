import { assert, describe, it } from "@effect/vitest";
import * as NodeSqliteClient from "@t3tools/shared/nodeSqliteClient";
import * as Effect from "effect/Effect";
import * as Migrator from "effect/sql/Migrator";
import * as SqlClient from "effect/sql/SqlClient";

import { migrationManifest, runMigrations } from "./Migrations.ts";
import ScheduledTaskEndConditions from "./Migrations/081_ScheduledTaskEndConditions.ts";

const latestMigrationId = Math.max(...migrationManifest.map(([id]) => id));

describe("fork migration upgrade", () => {
  it.effect.each([59, 68])(
    "runs upstream's %s and later on a database that took that id for end conditions",
    (forkId) =>
      Effect.gen(function* () {
        const sql = yield* SqlClient.SqlClient;
        yield* runMigrations({ toMigrationInclusive: forkId - 1 });
        yield* Migrator.make({})({
          loader: Migrator.fromRecord({
            [`${forkId}_ScheduledTaskEndConditions`]: ScheduledTaskEndConditions,
          }),
        });
        yield* sql`
          INSERT INTO scheduled_tasks (
            task_id, title, prompt, enabled, schedule_json, project_id, thread_id,
            workspace_strategy_json, model_selection_json, runtime_mode, interaction_mode,
            created_by, creation_source, created_at, updated_at, last_run_status, run_count,
            ends_at, max_runs
          ) VALUES (
            'task-1', 'Check CI', 'check CI', 1, '{}', 'project-1', 'thread-1',
            '{}', '{}', 'full-access', 'default',
            'user', 'settings', '2026-11-01T00:00:00.000Z', '2026-11-01T00:00:00.000Z', 'never', 2,
            '2026-11-02T00:00:00.000Z', 5
          )
        `;

        const executed = yield* runMigrations();
        assert.deepStrictEqual(
          executed.map(([id]) => id),
          Array.from({ length: latestMigrationId - forkId + 1 }, (_, index) => forkId + index),
        );
        const history = yield* sql<{ readonly migration_id: number; readonly name: string }>`
          SELECT migration_id, name FROM effect_sql_migrations ORDER BY migration_id
        `;
        assert.deepStrictEqual(
          history.map((row) => [row.migration_id, row.name] as const),
          migrationManifest,
        );
        const tasks = yield* sql<{
          readonly ends_at: string | null;
          readonly max_runs: number | null;
          readonly thread_mode: string;
        }>`SELECT ends_at, max_runs, thread_mode FROM scheduled_tasks WHERE task_id = 'task-1'`;
        assert.deepStrictEqual(tasks, [
          { ends_at: "2026-11-02T00:00:00.000Z", max_runs: 5, thread_mode: "continue" },
        ]);
        assert.deepStrictEqual(yield* runMigrations(), []);
      }).pipe(Effect.provide(NodeSqliteClient.layer({ filename: ":memory:" }))),
  );
});
