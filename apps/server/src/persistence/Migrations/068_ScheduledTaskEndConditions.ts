import * as Effect from "effect/Effect";
import * as SqlClient from "effect/sql/SqlClient";

export default Effect.gen(function* () {
  const sql = yield* SqlClient.SqlClient;

  // "Every 15 minutes for the next 12 hours" / "check 5 times". Both null
  // means the schedule runs until it is paused or deleted. Fork databases that
  // ran this as migration 59 already have the columns.
  const columns = yield* sql<{ readonly name: string }>`PRAGMA table_info(scheduled_tasks)`;
  const existing = new Set(columns.map((column) => column.name));
  if (!existing.has("ends_at")) {
    yield* sql`ALTER TABLE scheduled_tasks ADD COLUMN ends_at TEXT`;
  }
  if (!existing.has("max_runs")) {
    yield* sql`ALTER TABLE scheduled_tasks ADD COLUMN max_runs INTEGER`;
  }
});
