import {
  scheduledTaskCadenceLabel,
  scheduledTaskLifecycle,
  type ScheduledTask,
  type ScheduledTaskLifecycle,
} from "@t3tools/contracts";
import * as DateTime from "effect/DateTime";

const isoAt = (ms: number) => DateTime.formatIso(DateTime.makeUnsafe(ms));

export interface ScheduledTaskTiming {
  readonly lifecycle: ScheduledTaskLifecycle;
  /** "Every 15 minutes". */
  readonly cadence: string;
  /** When the next run starts, for active timers. */
  readonly nextRunAt: string | null;
  readonly endsAt: string | null;
  readonly runsLeft: number | null;
}

/** What a schedule card or row needs to say about when a task runs and stops. */
export function scheduledTaskTiming(task: ScheduledTask, nowMs: number): ScheduledTaskTiming {
  const lifecycle = scheduledTaskLifecycle(task, nowMs);
  return {
    lifecycle,
    cadence: scheduledTaskCadenceLabel(task.schedule),
    nextRunAt: lifecycle === "active" ? task.nextRunAt : null,
    endsAt: task.endsAt ?? null,
    runsLeft: task.maxRuns == null ? null : Math.max(0, task.maxRuns - task.runCount),
  };
}

/** "Every 15 minutes · until 1:00 AM · 3 runs left", "Every minute · Ended after 3 runs". */
export function scheduledTaskStatusText(
  task: ScheduledTask,
  formatTime: (iso: string) => string,
  nowMs: number,
): string {
  const timing = scheduledTaskTiming(task, nowMs);
  if (timing.lifecycle === "paused") return `${timing.cadence} · Paused`;
  if (timing.lifecycle === "ended") {
    return `${timing.cadence} · Ended after ${task.runCount} ${task.runCount === 1 ? "run" : "runs"}`;
  }
  const parts = [timing.cadence];
  if (task.schedule.type === "webhook") parts.push("Listening");
  if (timing.endsAt !== null) parts.push(`until ${formatTime(timing.endsAt)}`);
  if (timing.runsLeft !== null) {
    parts.push(`${timing.runsLeft} ${timing.runsLeft === 1 ? "run" : "runs"} left`);
  }
  return parts.join(" · ");
}

/** Active schedules by next run, then paused ones, then ended ones by most recent run. */
export function sortScheduledTasksByUpcoming(
  tasks: ReadonlyArray<ScheduledTask>,
  nowMs: number,
): ReadonlyArray<ScheduledTask> {
  const rank = (task: ScheduledTask) => {
    const lifecycle = scheduledTaskLifecycle(task, nowMs);
    return lifecycle === "active" ? 0 : lifecycle === "paused" ? 1 : 2;
  };
  return [...tasks].sort((a, b) => {
    const byRank = rank(a) - rank(b);
    if (byRank !== 0) return byRank;
    if (rank(a) === 0) {
      // Webhook tasks have no next run; they follow the timers.
      return (a.nextRunAt ?? "\uffff").localeCompare(b.nextRunAt ?? "\uffff");
    }
    return (b.lastRunAt ?? b.updatedAt).localeCompare(a.lastRunAt ?? a.updatedAt);
  });
}

/** How a schedule stops: never, a duration from when it is saved, or at a clock time. */
export type ScheduleEndMode = "never" | "duration" | "at";

/**
 * The end condition a schedule form saves, or why it cannot. `endAt` is the
 * chosen instant for mode "at"; a form passes the saved value back untouched
 * so editing a title cannot restart the schedule's clock.
 */
export function resolveScheduleEnd(
  input: {
    readonly mode: ScheduleEndMode;
    readonly afterHours: string;
    readonly endAt: string | null;
    readonly endAtUnchanged: boolean;
    readonly maxRuns: string;
  },
  nowMs: number,
):
  | { readonly endsAt: string | null; readonly maxRuns: number | null }
  | { readonly error: string } {
  const maxRunsText = input.maxRuns.trim();
  const maxRuns = maxRunsText === "" ? null : Number(maxRunsText);
  if (maxRuns !== null && (!Number.isSafeInteger(maxRuns) || maxRuns < 1)) {
    return { error: "Enter a whole number of runs, or leave it blank." };
  }
  if (input.mode === "never") return { endsAt: null, maxRuns };
  if (input.mode === "duration") {
    const hours = Number(input.afterHours);
    if (!Number.isFinite(hours) || hours <= 0) {
      return { error: "Enter how many hours the schedule should run." };
    }
    return { endsAt: isoAt(nowMs + Math.round(hours * 3_600_000)), maxRuns };
  }
  if (input.endAt !== null && input.endAtUnchanged) return { endsAt: input.endAt, maxRuns };
  const endMs = input.endAt === null ? Number.NaN : Date.parse(input.endAt);
  if (Number.isNaN(endMs)) return { error: "Choose when the schedule should end." };
  if (endMs <= nowMs) return { error: "Choose an end time in the future." };
  return { endsAt: isoAt(endMs), maxRuns };
}

export interface ScheduledTaskCardAnchor {
  /** The assistant message that closes a turn. */
  readonly messageId: string;
  /** When that message last changed; a schedule made during the turn predates it. */
  readonly updatedAt: string;
}

export interface ScheduledTaskCardPlacement {
  readonly byMessageId: ReadonlyMap<string, ReadonlyArray<ScheduledTask>>;
  /** Schedules made after the last finished reply, shown at the end of the conversation. */
  readonly trailing: ReadonlyArray<ScheduledTask>;
}

export const NO_SCHEDULED_TASK_CARDS: ScheduledTaskCardPlacement = {
  byMessageId: new Map(),
  trailing: [],
};

/**
 * Places each schedule bound to a thread under the reply that ends the turn it
 * was created in. Anchors are in timeline order. A schedule older than the
 * loaded history gets no card, so paging in old turns never pins it to the
 * wrong reply.
 */
export function placeScheduledTaskCards(input: {
  readonly tasks: ReadonlyArray<ScheduledTask>;
  readonly anchors: ReadonlyArray<ScheduledTaskCardAnchor>;
  /** Creation time of the oldest loaded timeline entry, or null when nothing is loaded. */
  readonly oldestLoadedAt: string | null;
}): ScheduledTaskCardPlacement {
  if (input.tasks.length === 0 || input.oldestLoadedAt === null) return NO_SCHEDULED_TASK_CARDS;
  const oldestMs = Date.parse(input.oldestLoadedAt);
  const anchors = input.anchors.map((anchor) => ({
    messageId: anchor.messageId,
    ms: Date.parse(anchor.updatedAt),
  }));
  const byMessageId = new Map<string, ScheduledTask[]>();
  const trailing: ScheduledTask[] = [];
  for (const task of [...input.tasks].sort((a, b) => a.createdAt.localeCompare(b.createdAt))) {
    const createdMs = Date.parse(task.createdAt);
    if (!(createdMs >= oldestMs)) continue;
    const anchor = anchors.find((candidate) => candidate.ms >= createdMs);
    if (anchor === undefined) {
      trailing.push(task);
      continue;
    }
    const placed = byMessageId.get(anchor.messageId);
    if (placed) placed.push(task);
    else byMessageId.set(anchor.messageId, [task]);
  }
  return { byMessageId, trailing };
}
