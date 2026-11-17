// @effect-diagnostics nodeBuiltinImport:off globalDate:off - Host-side helpers for install-fork-desktop.ts, which has no Effect runtime.
/**
 * What a fork install restart does to agent turns. Before the installer quits the app it records
 * the threads with a turn in flight; after the relaunch it checks that the server's own restart
 * continuation (`continueThreadsAfterServerUpdate`) picked each cut turn back up.
 */
import type * as NodeSqlite from "node:sqlite";

/** Run statuses where an agent turn is doing work, so a restart cuts it short. */
export const WORKING_RUN_STATUSES = ["preparing", "queued", "starting", "running"] as const;
/** A run waiting on an approval or answer keeps its question across a restart. */
const WAITING_RUN_STATUS = "waiting";
/** Runs that ended on their own before the app quit. A run cut by the restart becomes `cancelled`. */
const SETTLED_RUN_STATUSES = new Set(["completed", "failed", "interrupted"]);

export const DEFAULT_GRACE_MS = 15 * 60 * 1_000;
const GRACE_UNITS_MS: Record<string, number> = { ms: 1, s: 1_000, m: 60_000, h: 3_600_000 };

/**
 * How long to wait for working turns before installing anyway. A bare number is minutes, `0`
 * installs right away, and `forever` (null) keeps waiting until no turn is working.
 */
export function parseGrace(value: string | undefined): number | null {
  if (value === undefined) return DEFAULT_GRACE_MS;
  if (value === "forever") return null;
  const match = /^(\d+(?:\.\d+)?)(ms|s|m|h)?$/.exec(value.trim());
  if (!match) {
    throw new Error(
      `--grace takes minutes, a duration like 90s or 1h, or "forever"; got "${value}".`,
    );
  }
  return Math.round(Number(match[1]) * GRACE_UNITS_MS[match[2] ?? "m"]!);
}

export function formatGrace(graceMs: number | null): string {
  if (graceMs === null) return "forever";
  if (graceMs % 3_600_000 === 0 && graceMs > 0) return `${graceMs / 3_600_000}h`;
  if (graceMs % 60_000 === 0) return `${graceMs / 60_000}m`;
  return `${Math.round(graceMs / 1_000)}s`;
}

export interface ResumeSettings {
  /** The global `continueThreadsAfterServerUpdate`, on unless the user turned it off. */
  readonly global: boolean;
  /** Per-project overrides of that setting. */
  readonly projects: Readonly<Record<string, boolean>>;
}

export function readResumeSettings(settings: unknown): ResumeSettings {
  const record = isRecord(settings) ? settings : {};
  const projects: Record<string, boolean> = {};
  const overrides = record.projectSettingsOverrides;
  if (isRecord(overrides)) {
    for (const [projectId, override] of Object.entries(overrides)) {
      if (isRecord(override) && typeof override.continueThreadsAfterServerUpdate === "boolean") {
        projects[projectId] = override.continueThreadsAfterServerUpdate;
      }
    }
  }
  return {
    global: record.continueThreadsAfterServerUpdate !== false,
    projects,
  };
}

/** Why the server will not continue a cut turn, mirroring its restart-continuation guard. */
export type ResumeSkipReason = "archived" | "deleted" | "settled" | "snoozed" | "resume off";

export interface RestartThread {
  readonly threadId: string;
  readonly title: string;
  readonly projectId: string;
  readonly projectTitle: string | null;
  readonly runId: string;
  readonly runStatus: string;
  readonly requestedAt: string;
  /** The start of the last message the user sent the thread. */
  readonly lastRequest: string | null;
  /** Waiting on the user's answer or approval: not cut, keeps its question. */
  readonly waitingOnUser: boolean;
  /** A subagent or delegated child, continued in its own thread. */
  readonly child: boolean;
  readonly expectedResume: "yes" | ResumeSkipReason;
}

interface RunRow {
  readonly runId: string;
  readonly threadId: string;
  readonly runStatus: string;
  readonly requestedAt: string;
  readonly title: string;
  readonly projectId: string;
  readonly projectTitle: string | null;
  readonly archivedAt: string | null;
  readonly deletedAt: string | null;
  readonly threadPayload: string;
}

const LAST_REQUEST_CHARS = 200;
// A thread can hold a running turn and a queued one behind it; it is recorded once, by the turn
// furthest along.
const RUN_STATUS_RANK: Record<string, number> = {
  running: 0,
  starting: 1,
  preparing: 2,
  waiting: 3,
  queued: 4,
};

/** Threads with a turn in flight or waiting on the user, read just before the app quits. */
export function readRestartThreads(
  db: NodeSqlite.DatabaseSync,
  settings: ResumeSettings,
  nowMs: number,
): ReadonlyArray<RestartThread> {
  const statuses = [...WORKING_RUN_STATUSES, WAITING_RUN_STATUS];
  const rows = db
    .prepare(
      `SELECT runs.run_id AS runId, runs.thread_id AS threadId, runs.status AS runStatus,
              runs.requested_at AS requestedAt, threads.title AS title,
              threads.project_id AS projectId, projects.title AS projectTitle,
              threads.archived_at AS archivedAt, threads.deleted_at AS deletedAt,
              threads.payload_json AS threadPayload
         FROM orchestration_v2_projection_runs AS runs
         JOIN orchestration_v2_projection_threads AS threads USING (thread_id)
         LEFT JOIN projection_projects AS projects ON projects.project_id = threads.project_id
        WHERE runs.status IN (${statuses.map(() => "?").join(", ")})
        ORDER BY runs.requested_at`,
    )
    .all(...statuses) as unknown as ReadonlyArray<RunRow>;
  const lastMessages = db.prepare(
    `SELECT payload_json AS payload FROM orchestration_v2_projection_messages
      WHERE thread_id = ? AND role = 'user'
      ORDER BY updated_at DESC LIMIT 10`,
  );
  const byThread = new Map<string, RunRow>();
  for (const row of rows) {
    const current = byThread.get(row.threadId);
    if (!current || RUN_STATUS_RANK[row.runStatus]! < RUN_STATUS_RANK[current.runStatus]!) {
      byThread.set(row.threadId, row);
    }
  }
  return [...byThread.values()].map((row) => {
    const thread = parseRecord(row.threadPayload);
    const lineage = isRecord(thread.lineage) ? thread.lineage : {};
    return {
      threadId: row.threadId,
      title: row.title,
      projectId: row.projectId,
      projectTitle: row.projectTitle,
      runId: row.runId,
      runStatus: row.runStatus,
      requestedAt: row.requestedAt,
      lastRequest: lastUserRequest(
        lastMessages.all(row.threadId) as unknown as ReadonlyArray<{ payload: string }>,
      ),
      waitingOnUser: row.runStatus === WAITING_RUN_STATUS,
      child: typeof lineage.parentThreadId === "string",
      expectedResume: resumeSkipReason(row, thread, settings, nowMs) ?? "yes",
    };
  });
}

function resumeSkipReason(
  row: RunRow,
  thread: Record<string, unknown>,
  settings: ResumeSettings,
  nowMs: number,
): ResumeSkipReason | null {
  if (row.deletedAt !== null) return "deleted";
  if (row.archivedAt !== null) return "archived";
  if (thread.settledOverride === "settled") return "settled";
  if (typeof thread.snoozedUntil === "string" && Date.parse(thread.snoozedUntil) > nowMs) {
    return "snoozed";
  }
  if (!(settings.projects[row.projectId] ?? settings.global)) return "resume off";
  return null;
}

/** Skips agent-sent rows (task notices, wakes) that are stored with the user role. */
function lastUserRequest(rows: ReadonlyArray<{ payload: string }>): string | null {
  for (const row of rows) {
    const message = parseRecord(row.payload);
    if (message.createdBy !== "user" || typeof message.text !== "string") continue;
    const text = message.text.replace(/\s+/g, " ").trim();
    if (text.length === 0) continue;
    return text.length > LAST_REQUEST_CHARS ? `${text.slice(0, LAST_REQUEST_CHARS)}…` : text;
  }
  return null;
}

export type ResumeOutcome =
  /** The server started the continuation turn. */
  | { readonly kind: "resumed" }
  /** The continuation is queued or starting; the server may still be booting. */
  | { readonly kind: "pending" }
  | { readonly kind: "failed"; readonly error: string | null }
  /** The turn ended on its own before the app quit, so there was nothing to continue. */
  | { readonly kind: "finished before quit"; readonly runStatus: string }
  | { readonly kind: "not resumed"; readonly reason: ResumeSkipReason | "server declined" };

/** Where a recorded thread stands after the relaunch, read from the server's effect outbox. */
export function readResumeOutcome(
  db: NodeSqlite.DatabaseSync,
  thread: RestartThread,
): ResumeOutcome {
  const effect = db
    .prepare(
      `SELECT status, last_error AS lastError FROM orchestration_v2_effect_outbox
        WHERE effect_id = ?`,
    )
    .get(`effect:restart-continuation:${thread.runId}`) as
    | { readonly status: string; readonly lastError: string | null }
    | undefined;
  if (effect) {
    if (effect.status === "succeeded") return { kind: "resumed" };
    if (effect.status === "pending" || effect.status === "running") return { kind: "pending" };
    return { kind: "failed", error: effect.lastError };
  }
  const run = db
    .prepare(`SELECT status FROM orchestration_v2_projection_runs WHERE run_id = ?`)
    .get(thread.runId) as { readonly status: string } | undefined;
  // A turn still queued at the quit had nothing to cut; it counts once it starts.
  if (
    thread.runStatus === "queued" &&
    run &&
    run.status !== "queued" &&
    run.status !== "cancelled"
  ) {
    return { kind: "resumed" };
  }
  if (run && SETTLED_RUN_STATUSES.has(run.status)) {
    return { kind: "finished before quit", runStatus: run.status };
  }
  // Recovery has not reconciled the run yet.
  if (run && (WORKING_RUN_STATUSES as ReadonlyArray<string>).includes(run.status)) {
    return { kind: "pending" };
  }
  return {
    kind: "not resumed",
    reason: thread.expectedResume === "yes" ? "server declined" : thread.expectedResume,
  };
}

export function describeOutcome(outcome: ResumeOutcome): string {
  switch (outcome.kind) {
    case "failed":
      return outcome.error ? `resume failed: ${outcome.error}` : "resume failed";
    case "finished before quit":
      return `finished before the quit (${outcome.runStatus})`;
    case "not resumed":
      return `not resumed (${outcome.reason})`;
    default:
      return outcome.kind;
  }
}

/** One line for the notification, such as "3 resumed, 1 not resumed (snoozed)". */
export function summarizeOutcomes(outcomes: ReadonlyArray<ResumeOutcome>): string {
  const count = (kind: ResumeOutcome["kind"]) => outcomes.filter((o) => o.kind === kind).length;
  const reasons = [
    ...new Set(
      outcomes.flatMap((outcome) => (outcome.kind === "not resumed" ? [outcome.reason] : [])),
    ),
  ];
  const parts = [
    count("resumed") > 0 ? `${count("resumed")} resumed` : null,
    count("pending") > 0 ? `${count("pending")} still starting` : null,
    count("failed") > 0 ? `${count("failed")} failed to resume` : null,
    count("not resumed") > 0 ? `${count("not resumed")} not resumed (${reasons.join(", ")})` : null,
    count("finished before quit") > 0
      ? `${count("finished before quit")} finished before the quit`
      : null,
  ].filter((part) => part !== null);
  return parts.length > 0 ? parts.join(", ") : "no turns were cut";
}

function parseRecord(json: string): Record<string, unknown> {
  try {
    const value: unknown = JSON.parse(json);
    return isRecord(value) ? value : {};
  } catch {
    return {};
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
