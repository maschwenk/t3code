import * as Effect from "effect/Effect";
import * as SqlClient from "effect/sql/SqlClient";

// Fork builds recorded ScheduledTaskEndConditions as 59, then 68, ids upstream later took.
// The migrator skips every id up to the highest recorded, so drop that record while it is
// the latest; upstream's migrations from there run, and 81 adds the columns if missing.
const FORK_RECORDED_IDS = [59, 68] as const;

export const reconcileForkMigration = Effect.fn("reconcileForkMigration")(function* () {
  const sql = yield* SqlClient.SqlClient;
  const tables = yield* sql`
    SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'effect_sql_migrations'
  `;
  if (tables.length === 0) return;
  for (const id of FORK_RECORDED_IDS) {
    yield* sql`
      DELETE FROM effect_sql_migrations
      WHERE migration_id = ${id} AND name = 'ScheduledTaskEndConditions'
        AND NOT EXISTS (SELECT 1 FROM effect_sql_migrations WHERE migration_id > ${id})
    `;
  }
});
