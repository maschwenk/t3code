import * as Effect from "effect/Effect";
import * as SqlClient from "effect/sql/SqlClient";

export default Effect.gen(function* () {
  const sql = yield* SqlClient.SqlClient;

  // "Every 15 minutes for the next 12 hours" / "check 5 times". Both null
  // means the schedule runs until it is paused or deleted.
  yield* sql`ALTER TABLE scheduled_tasks ADD COLUMN ends_at TEXT`;
  yield* sql`ALTER TABLE scheduled_tasks ADD COLUMN max_runs INTEGER`;
});
