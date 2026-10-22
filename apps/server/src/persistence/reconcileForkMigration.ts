import * as Effect from "effect/Effect";
import * as SqlClient from "effect/sql/SqlClient";

// The fork recorded ScheduledTaskEndConditions as migration 59 before upstream
// claimed 59 for McpAppModelContext. Drop that record so upstream's 59..67 run;
// migration 68 re-adds the end-condition columns only when they are missing.
export const reconcileForkMigration = Effect.fn("reconcileForkMigration")(function* () {
  const sql = yield* SqlClient.SqlClient;
  const tables = yield* sql`
    SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'effect_sql_migrations'
  `;
  if (tables.length === 0) return;
  yield* sql`
    DELETE FROM effect_sql_migrations
    WHERE migration_id = 59 AND name = 'ScheduledTaskEndConditions'
      AND NOT EXISTS (SELECT 1 FROM effect_sql_migrations WHERE migration_id > 59)
  `;
});
