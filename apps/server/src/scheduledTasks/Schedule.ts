import { MIN_SCHEDULED_TASK_INTERVAL_MS, type ScheduledTaskSchedule } from "@t3tools/contracts";
import * as DateTime from "effect/DateTime";

const MINUTE_MS = 60_000;

export function parseTimeOfDay(value: string): { hour: number; minute: number } | null {
  const match = /^([01]?\d|2[0-3]):([0-5]\d)$/.exec(value.trim());
  if (!match) return null;
  return { hour: Number(match[1]), minute: Number(match[2]) };
}

export function nextScheduledRunAt(
  schedule: ScheduledTaskSchedule,
  from: DateTime.DateTime,
): DateTime.DateTime | null {
  if (schedule.type === "webhook") return null;
  if (schedule.type === "interval") {
    // Persisted rows created before the one-minute floor remain readable, but
    // they must not retain their old high-frequency execution rate.
    return DateTime.add(from, {
      milliseconds: Math.max(schedule.everyMs, MIN_SCHEDULED_TASK_INTERVAL_MS),
    });
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
    const slot = DateTime.add(dueAt, { milliseconds: everyMs });
    next =
      DateTime.toEpochMillis(slot) > DateTime.toEpochMillis(from)
        ? slot
        : DateTime.add(from, { milliseconds: everyMs });
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

/**
 * Canonical form of a weekday mask, mirroring how `nextScheduledRunAt` reads
 * it: order and duplicates are irrelevant, and an empty/omitted mask means the
 * same as explicitly listing all seven days — daily.
 */
function weekdayKey(weekdays: ReadonlyArray<number> | undefined): string {
  const unique = [...new Set(weekdays ?? [])].toSorted((x, y) => x - y);
  if (unique.length === 0 || unique.length === 7) return "daily";
  return unique.join(",");
}

/** Semantic equality for schedules: true iff both fire at the same times. */
export function isSameSchedule(a: ScheduledTaskSchedule, b: ScheduledTaskSchedule): boolean {
  if (a.type === "interval") {
    return b.type === "interval" && a.everyMs === b.everyMs;
  }
  // Webhook tasks never have a next run, whatever their signature settings.
  if (a.type === "webhook") return b.type === "webhook";
  if (b.type !== "fixed_time") return false;
  // The contract accepts padded and unpadded hours ("9:00" and "09:00"), so
  // compare the parsed time — string equality would treat a format-only edit
  // as a schedule change and recompute the pending run.
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

/**
 * How late a fixed-time run may fire before it counts as missed. Covers poll
 * jitter and short sleeps, while a server booted hours after the slot skips
 * to the next occurrence instead of firing stale work at a random time.
 */
const MISSED_FIXED_TIME_GRACE_MS = 10 * MINUTE_MS;

/**
 * True when a due fixed-time run was missed by more than the grace window and
 * should be rescheduled to its next occurrence instead of firing now.
 * Interval schedules are never considered missed: an overdue interval task
 * catching up with a single run is the desired behaviour.
 */
export function isMissedFixedTimeRun(
  schedule: ScheduledTaskSchedule,
  dueAt: DateTime.DateTime,
  now: DateTime.DateTime,
): boolean {
  if (schedule.type !== "fixed_time") return false;
  return DateTime.toEpochMillis(now) - DateTime.toEpochMillis(dueAt) > MISSED_FIXED_TIME_GRACE_MS;
}

function describeSchedule(schedule: ScheduledTaskSchedule): string {
  if (schedule.type === "webhook") return "On webhook";
  if (schedule.type === "interval") {
    const minutes = schedule.everyMs / MINUTE_MS;
    if (Number.isInteger(minutes)) {
      return `Every ${minutes === 1 ? "minute" : `${minutes} minutes`}`;
    }
    return `Every ${Math.round(schedule.everyMs / 1000)} seconds`;
  }

  const weekdayCount = schedule.weekdays?.length ?? 0;
  const days =
    weekdayCount === 0
      ? "day"
      : weekdayCount === 5 && schedule.weekdays?.every((day) => day >= 1 && day <= 5)
        ? "weekday"
        : "selected day";
  return `At ${schedule.timeOfDay} every ${days}`;
}
