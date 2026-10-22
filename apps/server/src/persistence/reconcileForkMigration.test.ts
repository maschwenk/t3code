import { assert, describe, it } from "@effect/vitest";
import * as NodeSqliteClient from "@t3tools/shared/nodeSqliteClient";
import * as Effect from "effect/Effect";
import * as Migrator from "effect/sql/Migrator";
import * as SqlClient from "effect/sql/SqlClient";

import { migrationManifest, runMigrations } from "./Migrations.ts";
import ScheduledTaskEndConditions from "./Migrations/068_ScheduledTaskEndConditions.ts";

describe("fork migration upgrade", () => {
  it.effect("runs upstream's 59 and later on a database that took 59 for end conditions", () =>
    Effect.gen(function* () {
      const sql = yield* SqlClient.SqlClient;
      yield* runMigrations({ toMigrationInclusive: 58 });
      yield* Migrator.make({})({
        loader: Migrator.fromRecord({
          "59_ScheduledTaskEndConditions": ScheduledTaskEndConditions,
        }),
      });

      const executed = yield* runMigrations();
      assert.deepStrictEqual(
        executed.map(([id]) => id),
        [59, 60, 61, 62, 63, 64, 65, 66, 67, 68],
      );
      const history = yield* sql<{ readonly migration_id: number; readonly name: string }>`
        SELECT migration_id, name FROM effect_sql_migrations ORDER BY migration_id
      `;
      assert.deepStrictEqual(
        history.map((row) => [row.migration_id, row.name] as const),
        migrationManifest,
      );
      const columns = yield* sql<{ readonly name: string }>`PRAGMA table_info(scheduled_tasks)`;
      const names = columns.map((column) => column.name);
      assert.include(names, "ends_at");
      assert.include(names, "max_runs");
      assert.lengthOf(yield* sql`SELECT * FROM mcp_app_model_context`, 0);
    }).pipe(Effect.provide(NodeSqliteClient.layer({ filename: ":memory:" }))),
  );
});
