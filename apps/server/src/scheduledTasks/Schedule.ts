import { MIN_SCHEDULED_TASK_INTERVAL_MS, type ScheduledTaskSchedule } from "@t3tools/contracts";
import * as DateTime from "effect/DateTime";
import * as Option from "effect/Option";

const MINUTE_MS = 60_000;

function parseTimeOfDay(value: string): { hour: number; minute: number } | null {
  const match = /^([01]?\d|2[0-3]):([0-5]\d)$/.exec(value.trim());
  if (!match) return null;
  return { hour: Number(match[1]), minute: Number(match[2]) };
}

export function nextScheduledRunAt(
  schedule: ScheduledTaskSchedule,
  from: DateTime.DateTime,
): DateTime.DateTime | null {
  if (schedule.type === "webhook") return null;
  if (schedule.type === "once") {
    const runAt = DateTime.make(schedule.runAt);
    return Option.isSome(runAt) &&
      DateTime.toEpochMillis(runAt.value) > DateTime.toEpochMillis(from)
      ? runAt.value
      : null;
  }
  if (schedule.type === "interval") {
    // Intervals advance elapsed time, including across daylight-saving changes.
    return DateTime.addDuration(from, Math.max(schedule.everyMs, MIN_SCHEDULED_TASK_INTERVAL_MS));
  }

  const time = parseTimeOfDay(schedule.timeOfDay);
  if (time === null) return null;
  const weekdays =
    schedule.weekdays && schedule.weekdays.length > 0 ? new Set(schedule.weekdays) : null;
  for (let offset = 0; offset <= 7; offset += 1) {
    const candidate = DateTime.setParts(DateTime.add(from, { days: offset }), {
      hour: time.hour,
      minute: time.minute,
      second: 0,
      millisecond: 0,
    });
    if (DateTime.toEpochMillis(candidate) <= DateTime.toEpochMillis(from)) continue;
    if (weekdays !== null && !weekdays.has(DateTime.toParts(candidate).weekDay)) continue;
    return candidate;
  }
  return null;
}

/**
 * How late past its end time a due run may still start. The scheduler polls
 * every few seconds, so a run due exactly at the end starts slightly after it.
 */
const SCHEDULE_END_GRACE_MS = MINUTE_MS;

export interface ScheduleEndCondition {
  readonly endsAt?: string | null | undefined;
  readonly maxRuns?: number | null | undefined;
  /** Runs already counted, including one that just finished. */
  readonly runCount: number;
}

/**
 * The next run of a timer within its end condition, or null once the end time
 * or run budget is reached. With `dueAt`, an interval run follows the slot it
 * was due at rather than when it finished, so poll latency cannot push the
 * last run of "every 15 minutes for 12 hours" past the end.
 */
export function nextScheduledRunWithinEnd(
  schedule: ScheduledTaskSchedule,
  from: DateTime.DateTime,
  end: ScheduleEndCondition,
  dueAt?: DateTime.DateTime,
): DateTime.DateTime | null {
  if (end.maxRuns != null && end.runCount >= end.maxRuns) return null;
  let next: DateTime.DateTime | null;
  if (schedule.type === "interval" && dueAt !== undefined) {
    const everyMs = Math.max(schedule.everyMs, MIN_SCHEDULED_TASK_INTERVAL_MS);
    const slot = DateTime.addDuration(dueAt, everyMs);
    next =
      DateTime.toEpochMillis(slot) > DateTime.toEpochMillis(from)
        ? slot
        : DateTime.addDuration(from, everyMs);
  } else {
    next = nextScheduledRunAt(schedule, from);
  }
  if (next === null || end.endsAt == null) return next;
  const endMs = Date.parse(end.endsAt);
  return Number.isFinite(endMs) && DateTime.toEpochMillis(next) <= endMs ? next : null;
}

/** True when a due run is too late to start because its schedule already ended. */
export function isPastScheduleEnd(
  endsAt: string | null | undefined,
  now: DateTime.DateTime,
): boolean {
  if (endsAt == null) return false;
  const endMs = Date.parse(endsAt);
  return !Number.isFinite(endMs) || DateTime.toEpochMillis(now) > endMs + SCHEDULE_END_GRACE_MS;
}

function weekdayKey(weekdays: ReadonlyArray<number> | undefined): string {
  const unique = [...new Set(weekdays ?? [])].toSorted((x, y) => x - y);
  if (unique.length === 0 || unique.length === 7) return "daily";
  return unique.join(",");
}

export function isSameSchedule(a: ScheduledTaskSchedule, b: ScheduledTaskSchedule): boolean {
  if (a.type === "interval") {
    return b.type === "interval" && a.everyMs === b.everyMs;
  }
  if (a.type === "webhook") return b.type === "webhook";
  if (a.type === "once") return b.type === "once" && Date.parse(a.runAt) === Date.parse(b.runAt);
  if (b.type !== "fixed_time") return false;
  // Compare parsed times so padded-hour edits do not reschedule pending runs.
  const aTime = parseTimeOfDay(a.timeOfDay);
  const bTime = parseTimeOfDay(b.timeOfDay);
  return (
    aTime !== null &&
    bTime !== null &&
    aTime.hour === bTime.hour &&
    aTime.minute === bTime.minute &&
    weekdayKey(a.weekdays) === weekdayKey(b.weekdays)
  );
}

const MISSED_FIXED_TIME_GRACE_MS = 10 * MINUTE_MS;

export function isMissedFixedTimeRun(
  schedule: ScheduledTaskSchedule,
  dueAt: DateTime.DateTime,
  now: DateTime.DateTime,
): boolean {
  if (schedule.type !== "fixed_time") return false;
  return DateTime.toEpochMillis(now) - DateTime.toEpochMillis(dueAt) > MISSED_FIXED_TIME_GRACE_MS;
}
