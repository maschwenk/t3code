import * as Cause from "effect/Cause";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import * as SqlClient from "effect/sql/SqlClient";

import type { OrchestrationV2AutoSettlementSource } from "@t3tools/contracts";

import packageJson from "../../package.json" with { type: "json" };

const encodeJson = Schema.encodeEffect(Schema.fromJsonString(Schema.Unknown));

/** What made the settlement service look at the thread. */
export type SettlementDecisionTrigger = "merge_event" | "thread_event" | "full_sweep";

export interface SettlementDecision {
  readonly decidedAt: string;
  readonly threadId: string;
  readonly projectId: string;
  readonly outcome: "settled" | "held";
  /** The rule that settled the thread, or the one that would have without the hold. */
  readonly rule: OrchestrationV2AutoSettlementSource;
  readonly holdReason: string | null;
  readonly trigger: SettlementDecisionTrigger;
  readonly runId: string | null;
  readonly settledAt: string | null;
  /** The reply check's record for `runId`, when it decided one. */
  readonly replyCheck: unknown;
  /** The settlement candidate the rules read, so the audit can replay them. */
  readonly inputs: unknown;
  readonly settings: unknown;
}

export class SettlementDecisionLog extends Context.Service<
  SettlementDecisionLog,
  { readonly record: (decision: SettlementDecision) => Effect.Effect<void> }
>()("t3/persistence/SettlementDecisions/SettlementDecisionLog") {}

const make = Effect.gen(function* () {
  const sql = yield* SqlClient.SqlClient;
  // Created here rather than in a migration: fork migration ids collide with upstream's
  // (see reconcileForkMigration.ts), and nothing else reads this table.
  yield* sql`
    CREATE TABLE IF NOT EXISTS settlement_decisions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      decided_at TEXT NOT NULL,
      thread_id TEXT NOT NULL,
      project_id TEXT NOT NULL,
      outcome TEXT NOT NULL,
      rule TEXT NOT NULL,
      hold_reason TEXT,
      trigger TEXT NOT NULL,
      run_id TEXT,
      settled_at TEXT,
      reply_check_json TEXT,
      inputs_json TEXT NOT NULL,
      settings_json TEXT NOT NULL,
      server_version TEXT NOT NULL
    )
  `;
  yield* sql`
    CREATE INDEX IF NOT EXISTS settlement_decisions_thread_idx
    ON settlement_decisions(thread_id, id)
  `;

  return SettlementDecisionLog.of({
    record: Effect.fn("SettlementDecisionLog.record")(
      function* (decision) {
        const replyCheck =
          decision.replyCheck == null ? null : yield* encodeJson(decision.replyCheck);
        const inputs = yield* encodeJson(decision.inputs);
        const settings = yield* encodeJson(decision.settings);
        yield* sql`
          INSERT INTO settlement_decisions (
            decided_at, thread_id, project_id, outcome, rule, hold_reason, trigger, run_id,
            settled_at, reply_check_json, inputs_json, settings_json, server_version
          ) VALUES (
            ${decision.decidedAt}, ${decision.threadId}, ${decision.projectId},
            ${decision.outcome}, ${decision.rule}, ${decision.holdReason}, ${decision.trigger},
            ${decision.runId}, ${decision.settledAt}, ${replyCheck}, ${inputs}, ${settings},
            ${packageJson.version}
          )
        `;
      },
      // A lost audit row must never stop a thread from settling.
      Effect.catchCause((cause) =>
        Cause.hasInterruptsOnly(cause)
          ? Effect.interrupt
          : Effect.logWarning("settlement decision not recorded", { cause }),
      ),
    ),
  });
});

export const layer = Layer.effect(SettlementDecisionLog, make);
