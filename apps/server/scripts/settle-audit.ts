#!/usr/bin/env node
// @effect-diagnostics nodeBuiltinImport:off - a read-only report over one SQLite file.
/**
 * Labels past auto-settles by what happened next and, with --replay, reruns this checkout's rules
 * on recorded decisions. Read-only. `node apps/server/scripts/settle-audit.ts --help`
 */
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeSqlite from "node:sqlite";

import * as NodeRuntime from "@effect/platform-node/NodeRuntime";
import * as NodeServices from "@effect/platform-node/NodeServices";
import type { OrchestrationV2ThreadUnsettleCause } from "@t3tools/contracts";
import * as Console from "effect/Console";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import { Command, Flag } from "effect/cli";

import {
  type AutoSettlement,
  resolveAutoSettlement,
} from "../src/orchestration-v2/ThreadSettlementService.ts";

const HOUR_MS = 60 * 60 * 1_000;
const TEXT_LIMIT = 4_000;

type Cause = OrchestrationV2ThreadUnsettleCause;

export type SettleLabel =
  | "reopened_by_user"
  | "reopened_late_by_user"
  | "reopened_automatically"
  | "reopened_unknown"
  | "stayed_settled";

const USER_CAUSES: ReadonlySet<Cause> = new Set(["user", "pin", "user_message", "guest"]);

/** A user reopening a settle soon after is the strongest sign it was wrong. */
function labelSettle(
  reopen: { readonly cause: Cause | null; readonly afterMs: number } | null,
  windowMs: number,
): SettleLabel {
  if (reopen === null) return "stayed_settled";
  if (reopen.cause === null) return "reopened_unknown";
  if (!USER_CAUSES.has(reopen.cause)) return "reopened_automatically";
  return reopen.afterMs <= windowMs ? "reopened_by_user" : "reopened_late_by_user";
}

/** Reopens from before `unsettleCause` was recorded: who sent the message that came with it. */
export function inferUnsettleCause(
  eventType: string,
  message: {
    readonly createdBy?: string;
    readonly scheduledTaskId?: string | null;
    readonly notification?: unknown;
  } | null,
): Cause | null {
  if (message !== null) {
    if (message.scheduledTaskId != null) return "scheduled_task";
    if (message.notification != null) return "notification";
    return message.createdBy === "user" ? "user_message" : "agent_message";
  }
  if (eventType === "thread.pinned") return "pin";
  if (eventType === "thread.guest-share-updated") return "guest";
  return eventType === "thread.unsettled" ? "user" : null;
}

const NESTED_DATES: ReadonlyArray<readonly [string, ReadonlyArray<string>]> = [
  ["pendingRuntimeRequest", ["createdAt"]],
];

const revive = (value: unknown) =>
  typeof value === "string" && !Number.isNaN(Date.parse(value))
    ? DateTime.makeUnsafe(value)
    : value;

/**
 * Turns a recorded decision's inputs back into what the rules read: JSON stored the thread's
 * `DateTime` fields (the ones ending in At or Until) as ISO strings. Link snapshots keep strings.
 */
function reviveSettlementInputs(inputs: {
  readonly thread: Record<string, unknown>;
  readonly pullRequest: unknown;
}) {
  const thread: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(inputs.thread)) {
    thread[key] = /(At|Until)$/.test(key) ? revive(value) : value;
  }
  for (const [key, fields] of NESTED_DATES) {
    const nested = thread[key];
    if (nested == null || typeof nested !== "object") continue;
    const copy: Record<string, unknown> = { ...(nested as Record<string, unknown>) };
    for (const field of fields) copy[field] = revive(copy[field]);
    thread[key] = copy;
  }
  if (Array.isArray(thread["automatedRunWindows"])) {
    thread["automatedRunWindows"] = thread["automatedRunWindows"].map(
      (window: { startedAt: string; completedAt: string }) => ({
        startedAt: revive(window.startedAt),
        completedAt: revive(window.completedAt),
      }),
    );
  }
  return {
    thread: thread as unknown as Parameters<typeof resolveAutoSettlement>[0]["thread"],
    pullRequest: inputs.pullRequest as Parameters<typeof resolveAutoSettlement>[0]["pullRequest"],
  };
}

interface DecisionRow {
  readonly id: number;
  readonly decided_at: string;
  readonly thread_id: string;
  readonly outcome: "settled" | "held";
  readonly rule: string;
  readonly hold_reason: string | null;
  readonly trigger: string;
  readonly run_id: string | null;
  readonly reply_check_json: string | null;
  readonly inputs_json: string;
  readonly settings_json: string;
  readonly server_version: string;
}

/** What this checkout's rules decide for a recorded decision, in the log's own terms. */
export function replayDecision(row: DecisionRow) {
  const settings = JSON.parse(row.settings_json);
  const replyCheck = row.reply_check_json === null ? null : JSON.parse(row.reply_check_json);
  const { thread, pullRequest } = reviveSettlementInputs(JSON.parse(row.inputs_json));
  const replayed: AutoSettlement | null = resolveAutoSettlement({
    thread,
    pullRequest,
    nowMs: Date.parse(row.decided_at),
    autoSettleAfterDays: settings.afterDays,
    autoSettleOnMerge: settings.onMerge,
    autoSettleKeepPullRequests: settings.keepPullRequests,
    pullRequestHeld:
      replyCheck !== null &&
      replyCheck.outcome !== "settles" &&
      (settings.replyCheck === true || replyCheck.reason !== "needs_user"),
  });
  if (replayed === null) return { outcome: "none", rule: null, holdReason: null } as const;
  return {
    outcome: replayed.outcome === "settle" ? "settled" : "held",
    rule: replayed.source,
    holdReason:
      replayed.outcome === "settle"
        ? null
        : replayed.hold === "reply_check"
          ? (replyCheck?.reason ?? replayed.hold)
          : replayed.hold,
  } as const;
}

const truncate = (text: string | null | undefined) =>
  text == null ? null : text.length <= TEXT_LIMIT ? text : `${text.slice(0, TEXT_LIMIT)}…`;

const defaultDatabase = () =>
  NodePath.join(
    process.env.T3CODE_HOME ?? NodePath.join(NodeOS.homedir(), ".t3"),
    "userdata",
    "statev2.sqlite",
  );

function audit(input: {
  readonly database: string;
  readonly days: number;
  readonly reopenHours: number;
  readonly json: string | undefined;
  readonly replay: boolean;
  readonly nowMs: number;
}) {
  const db = new NodeSqlite.DatabaseSync(input.database, { readOnly: true });
  try {
    const since = DateTime.formatIso(DateTime.makeUnsafe(input.nowMs - input.days * 24 * HOUR_MS));
    const windowMs = input.reopenHours * HOUR_MS;
    const lines: Array<string> = [];

    // occurred_at has no index, so find the window's first event by sequence.
    const maxSequence = Number(
      (
        db.prepare("SELECT max(sequence) AS max FROM orchestration_events").get() as {
          max: number | null;
        }
      ).max ?? 0,
    );
    const occurredAt = db.prepare(
      "SELECT occurred_at FROM orchestration_events WHERE sequence >= ? ORDER BY sequence LIMIT 1",
    );
    let low = 0;
    let high = maxSequence;
    while (low < high) {
      const middle = Math.floor((low + high) / 2);
      const row = occurredAt.get(middle) as { occurred_at: string } | undefined;
      if (row === undefined || row.occurred_at >= since) high = middle;
      else low = middle + 1;
    }

    const settles = db
      .prepare(
        `SELECT sequence, stream_id AS thread_id, occurred_at,
           json_extract(payload_json, '$.settlementSource') AS rule
         FROM orchestration_events
         WHERE sequence >= ? AND aggregate_kind = 'thread' AND event_type = 'thread.settled'
           AND command_id LIKE 'server:auto-settle:%' AND occurred_at >= ?
         ORDER BY sequence`,
      )
      .all(low, since) as Array<{
      sequence: number;
      thread_id: string;
      occurred_at: string;
      rule: string | null;
    }>;
    const nextChange = db.prepare(
      `SELECT event_type, occurred_at, command_id,
         json_extract(payload_json, '$.settledOverride') AS settled_override,
         json_extract(payload_json, '$.unsettleCause') AS cause
       FROM orchestration_events
       WHERE aggregate_kind = 'thread' AND stream_id = ? AND sequence > ?
         AND event_type IN ('thread.unsettled', 'thread.pinned', 'thread.guest-share-updated',
           'thread.settled')
       ORDER BY sequence LIMIT 20`,
    );
    const commandMessage = db.prepare(
      `SELECT payload_json FROM orchestration_events
       WHERE aggregate_kind = 'thread' AND stream_id = ? AND command_id = ?
         AND event_type = 'message.updated' AND json_extract(payload_json, '$.role') = 'user'
       ORDER BY sequence LIMIT 1`,
    );
    const title = db.prepare(
      "SELECT title FROM orchestration_v2_projection_threads WHERE thread_id = ?",
    );
    const latestRun = db.prepare(
      `SELECT run_id, json_extract(payload_json, '$.userMessageId') AS user_message_id
       FROM orchestration_v2_projection_runs
       WHERE thread_id = ? AND requested_at <= ?
       ORDER BY ordinal DESC LIMIT 1`,
    );
    const reply = db.prepare(
      `SELECT json_extract(payload_json, '$.text') AS text FROM orchestration_v2_projection_messages
       WHERE run_id = ? AND role = 'assistant' AND streaming = 0
         AND trim(coalesce(json_extract(payload_json, '$.text'), '')) <> ''
       ORDER BY created_at DESC LIMIT 1`,
    );
    const request = db.prepare(
      `SELECT json_extract(payload_json, '$.text') AS text FROM orchestration_v2_projection_messages
       WHERE message_id = ?`,
    );
    const hasDecisions =
      db
        .prepare(
          "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'settlement_decisions'",
        )
        .get() !== undefined;
    const decisionFor = hasDecisions
      ? db.prepare(
          `SELECT * FROM settlement_decisions
           WHERE thread_id = ? AND outcome = 'settled'
             AND decided_at BETWEEN datetime(?, '-30 seconds') AND datetime(?, '+30 seconds')
           ORDER BY id DESC LIMIT 1`,
        )
      : null;
    const holdsBefore = hasDecisions
      ? db.prepare(
          `SELECT decided_at, hold_reason FROM settlement_decisions
           WHERE thread_id = ? AND outcome = 'held' AND decided_at BETWEEN ? AND ?
           ORDER BY id`,
        )
      : null;

    const rows = settles.map((settle, index) => {
      const previous = settles
        .slice(0, index)
        .findLast((candidate) => candidate.thread_id === settle.thread_id);
      const change = (
        nextChange.all(settle.thread_id, settle.sequence) as Array<{
          event_type: string;
          occurred_at: string;
          command_id: string | null;
          settled_override: string | null;
          cause: Cause | null;
        }>
      ).find(
        (event) => event.event_type === "thread.settled" || event.settled_override !== "settled",
      );
      const reopened = change !== undefined && change.event_type !== "thread.settled";
      const message =
        reopened && change.command_id !== null
          ? (commandMessage.get(settle.thread_id, change.command_id) as
              | { payload_json: string }
              | undefined)
          : undefined;
      const cause = reopened
        ? (change.cause ??
          inferUnsettleCause(
            change.event_type,
            message === undefined ? null : JSON.parse(message.payload_json),
          ))
        : null;
      const afterMs = reopened
        ? Date.parse(change.occurred_at) - Date.parse(settle.occurred_at)
        : 0;
      const label = labelSettle(reopened ? { cause, afterMs } : null, windowMs);
      const decision = decisionFor?.get(
        settle.thread_id,
        settle.occurred_at,
        settle.occurred_at,
      ) as DecisionRow | undefined;
      const run = latestRun.get(settle.thread_id, settle.occurred_at) as
        | { run_id: string; user_message_id: string | null }
        | undefined;
      const runId = decision?.run_id ?? run?.run_id ?? null;
      const holds = (holdsBefore?.all(
        settle.thread_id,
        previous?.occurred_at ?? since,
        settle.occurred_at,
      ) ?? []) as Array<{ decided_at: string; hold_reason: string }>;
      return {
        settledAt: settle.occurred_at,
        threadId: settle.thread_id,
        title: (title.get(settle.thread_id) as { title: string } | undefined)?.title ?? null,
        rule: settle.rule ?? "unrecorded",
        label,
        reopen: reopened
          ? { at: change.occurred_at, cause, afterMinutes: Math.round(afterMs / 60_000) }
          : null,
        decision:
          decision === undefined
            ? null
            : {
                trigger: decision.trigger,
                serverVersion: decision.server_version,
                replyCheck: JSON.parse(decision.reply_check_json ?? "null"),
                settings: JSON.parse(decision.settings_json),
              },
        heldBefore: holds.map((hold) => ({ at: hold.decided_at, reason: hold.hold_reason })),
        runId,
        request: truncate(
          run?.user_message_id == null
            ? null
            : (request.get(run.user_message_id) as { text: string } | undefined)?.text,
        ),
        reply: truncate(
          runId === null ? null : (reply.get(runId) as { text: string } | undefined)?.text,
        ),
      };
    });

    lines.push(
      `auto-settles since ${since} (${input.days} days), reopen window ${input.reopenHours}h`,
    );
    const labels: ReadonlyArray<SettleLabel> = [
      "reopened_by_user",
      "reopened_late_by_user",
      "reopened_automatically",
      "reopened_unknown",
      "stayed_settled",
    ];
    lines.push(["rule".padEnd(34), "total", ...labels].join("  "));
    for (const rule of [...new Set(rows.map((row) => row.rule))].toSorted()) {
      const ofRule = rows.filter((row) => row.rule === rule);
      lines.push(
        [
          rule.padEnd(34),
          String(ofRule.length).padStart(5),
          ...labels.map((label) =>
            String(ofRule.filter((row) => row.label === label).length).padStart(label.length),
          ),
        ].join("  "),
      );
    }
    const wrong = rows.filter((row) => row.label === "reopened_by_user");
    if (wrong.length > 0) {
      lines.push("", "reopened by you within the window:");
      for (const row of wrong) {
        lines.push(
          `  ${row.settledAt}  ${row.rule}  back after ${row.reopen?.afterMinutes}m (${row.reopen?.cause})  ${row.title ?? row.threadId}`,
        );
      }
    }

    if (hasDecisions) {
      const holds = db
        .prepare(
          `SELECT rule, hold_reason, count(*) AS count, count(DISTINCT thread_id) AS threads
           FROM settlement_decisions WHERE outcome = 'held' AND decided_at >= ?
           GROUP BY rule, hold_reason ORDER BY count DESC`,
        )
        .all(since) as Array<{ rule: string; hold_reason: string; count: number; threads: number }>;
      lines.push("", "holds recorded (a rule would have settled the thread):");
      if (holds.length === 0) lines.push("  none");
      for (const hold of holds) {
        lines.push(
          `  ${hold.rule.padEnd(34)} ${hold.hold_reason.padEnd(16)} ${hold.count} rows, ${hold.threads} threads`,
        );
      }
    } else {
      lines.push(
        "",
        "no settlement_decisions table yet: holds and replay need a build that records them",
      );
    }

    if (input.replay && hasDecisions) {
      const decisions = db
        .prepare("SELECT * FROM settlement_decisions WHERE decided_at >= ? ORDER BY id")
        .all(since) as unknown as Array<DecisionRow>;
      const changed = decisions.flatMap((row) => {
        const replayed = replayDecision(row);
        const same =
          replayed.outcome === row.outcome &&
          replayed.rule === row.rule &&
          replayed.holdReason === row.hold_reason;
        return same ? [] : [{ row, replayed }];
      });
      lines.push(
        "",
        `replayed ${decisions.length} recorded decisions with this checkout's rules: ${changed.length} change`,
      );
      for (const { row, replayed } of changed) {
        lines.push(
          `  ${row.decided_at}  ${row.thread_id}  ${row.outcome} ${row.rule} ${row.hold_reason ?? ""} -> ${replayed.outcome} ${replayed.rule ?? ""} ${replayed.holdReason ?? ""}`,
        );
      }
    }

    if (input.json !== undefined) {
      NodeFS.writeFileSync(input.json, rows.map((row) => JSON.stringify(row)).join("\n") + "\n");
      lines.push("", `wrote ${rows.length} settles to ${input.json}`);
    }
    return lines.join("\n");
  } finally {
    db.close();
  }
}

const settleAuditCommand = Command.make(
  "settle-audit",
  {
    database: Flag.String("db").pipe(
      Flag.optional,
      Flag.withDescription("statev2.sqlite to read. Defaults to the T3 home's userdata."),
    ),
    days: Flag.Int("days").pipe(Flag.withDefault(7), Flag.withDescription("Days to look back.")),
    reopenHours: Flag.Int("reopen-hours").pipe(
      Flag.withDefault(24),
      Flag.withDescription("A reopen by you within this many hours marks a settle as wrong."),
    ),
    json: Flag.String("json").pipe(
      Flag.optional,
      Flag.withDescription("Write one JSON line per settle, with the request and reply text."),
    ),
    replay: Flag.Boolean("replay").pipe(
      Flag.withDefault(false),
      Flag.withDescription("Rerun this checkout's rules on every recorded decision."),
    ),
  },
  ({ database, days, reopenHours, json, replay }) =>
    DateTime.now.pipe(
      Effect.map((now) =>
        audit({
          database: Option.getOrElse(database, defaultDatabase),
          days,
          reopenHours,
          json: Option.getOrUndefined(json),
          replay,
          nowMs: DateTime.toEpochMillis(now),
        }),
      ),
      Effect.flatMap(Console.log),
    ),
).pipe(Command.withDescription("Label past auto-settles and replay recorded settle decisions."));

if (import.meta.main) {
  Command.run(settleAuditCommand, { version: "0.0.0" }).pipe(
    Effect.provide(NodeServices.layer),
    NodeRuntime.runMain,
  );
}
