import {
  EnvironmentId,
  type ProjectId,
  ScheduledTaskId,
  type ScheduledTask,
  type ScheduledTaskUpsertSchedule,
  type ModelSelection,
  type RuntimeMode,
  type ProviderInteractionMode,
  type ServerSettings,
  scheduledTaskCadenceLabel,
  scheduledTaskLifecycle,
  type ScheduledTaskLifecycle,
} from "@t3tools/contracts";
import { parseMaxDeliveryAge } from "@t3tools/client-runtime/scheduled-task-webhook";

import {
  resolveProjectSettings,
  type LegacyProjectSettingsFields,
} from "@t3tools/shared/projectSettings";
import type { ProviderInstanceEntry } from "../../providerInstances";

import type { ResolvedSettingsScope } from "./settingsScope";

/** Project IDs belong to an environment, including when a grouped project spans machines. */
export function matchesScheduledTaskScope(
  scope: ResolvedSettingsScope,
  environmentId: EnvironmentId,
  projectId: ProjectId,
): boolean {
  if (scope.kind === "unavailable" || !scope.environmentIds.includes(environmentId)) return false;
  if (scope.kind === "project" || scope.kind === "checkout") {
    return scope.members.some(
      (member) => member.environmentId === environmentId && member.id === projectId,
    );
  }
  return true;
}

export function validateScheduledTasksSearch(raw: Record<string, unknown>) {
  return {
    ...(typeof raw.environmentId === "string" && raw.environmentId.trim()
      ? { environmentId: EnvironmentId.make(raw.environmentId) }
      : {}),
    ...(typeof raw.taskId === "string" && raw.taskId.trim()
      ? { taskId: ScheduledTaskId.make(raw.taskId) }
      : {}),
  };
}

export type ScheduleMode = "fixed" | "interval" | "webhook";
export type WorkspaceMode = "root" | "worktree" | "existing_worktree";
/** How a timer stops: never, a duration from when it is saved, or at a clock time. */
export type EndMode = "never" | "duration" | "at";

export interface DraftState {
  readonly editingId: string | null;
  readonly title: string;
  readonly prompt: string;
  readonly enabled: boolean;
  readonly scheduleMode: ScheduleMode;
  readonly intervalMinutes: string;
  readonly timeOfDay: string;
  readonly weekdays: ReadonlySet<number>;
  readonly projectId: string;
  readonly threadId: string;
  readonly workspaceMode: WorkspaceMode;
  readonly baseRef: string;
  readonly startFromOrigin: boolean;
  readonly existingWorktreePath: string;
  readonly modelKey: string;
  /** Not editable in the dialog, but preserved so editing an agent-created task keeps its modes. */
  readonly runtimeMode: RuntimeMode;
  readonly interactionMode: ProviderInteractionMode;
  /**
   * The task's original model selection. The picker only edits
   * `instanceId:model`; keeping the source object preserves provider options
   * (reasoning, temperature, …) when the model itself is left unchanged.
   */
  readonly baseModelSelection: ModelSelection | null;
  readonly signatureEnabled: boolean;
  readonly signatureHeader: string;
  readonly signatureEncoding: "hex" | "base64";
  readonly signaturePrefix: string;
  /** Write-only: empty keeps the secret already stored on the server. */
  readonly signatureSecret: string;
  /** Minutes as typed; empty runs every held request regardless of age. */
  readonly maxDeliveryAgeMinutes: string;
  readonly endMode: EndMode;
  /** Hours as typed, for endMode "duration". */
  readonly endAfterHours: string;
  /** A datetime-local value, for endMode "at". */
  readonly endAt: string;
  /**
   * The saved end and how it rendered in the form. An untouched end saves
   * back exactly, so editing a title cannot restart the schedule's clock.
   */
  readonly savedEndsAt: string | null;
  /** Runs as typed; empty means no run limit. */
  readonly maxRuns: string;
}

export const EMPTY_END_FIELDS = {
  endMode: "never",
  endAfterHours: "12",
  endAt: "",
  savedEndsAt: null,
  maxRuns: "",
} as const satisfies Pick<
  DraftState,
  "endMode" | "endAfterHours" | "endAt" | "savedEndsAt" | "maxRuns"
>;

/** The local wall-clock value a datetime-local input shows for an instant. */
export function toDateTimeLocalInput(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  const pad = (value: number) => String(value).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

/** The end condition a draft saves, or a message explaining why it cannot. */
export function endFromDraft(
  draft: DraftState,
  nowMs: number,
):
  | { readonly endsAt: string | null; readonly maxRuns: number | null }
  | { readonly error: string } {
  const maxRunsText = draft.maxRuns.trim();
  const maxRuns = maxRunsText === "" ? null : Number(maxRunsText);
  if (maxRuns !== null && (!Number.isSafeInteger(maxRuns) || maxRuns < 1)) {
    return { error: "Enter a whole number of runs, or leave it blank." };
  }
  if (draft.scheduleMode === "webhook" || draft.endMode === "never") {
    return { endsAt: null, maxRuns };
  }
  if (draft.endMode === "duration") {
    const hours = Number(draft.endAfterHours);
    if (!Number.isFinite(hours) || hours <= 0) {
      return { error: "Enter how many hours the schedule should run." };
    }
    return { endsAt: new Date(nowMs + Math.round(hours * 3_600_000)).toISOString(), maxRuns };
  }
  if (draft.savedEndsAt !== null && draft.endAt === toDateTimeLocalInput(draft.savedEndsAt)) {
    return { endsAt: draft.savedEndsAt, maxRuns };
  }
  const endMs = new Date(draft.endAt).getTime();
  if (Number.isNaN(endMs)) return { error: "Choose when the schedule should end." };
  if (endMs <= nowMs) return { error: "Choose an end time in the future." };
  return { endsAt: new Date(endMs).toISOString(), maxRuns };
}

export interface ScheduledTaskTiming {
  readonly lifecycle: ScheduledTaskLifecycle;
  /** "Every 15 minutes". */
  readonly cadence: string;
  /** When the next run starts, for active timers. */
  readonly nextRunAt: string | null;
  /** "until <time>" or "5 runs left" style end, null when the schedule has none. */
  readonly endsAt: string | null;
  readonly runsLeft: number | null;
}

/** What a schedule card or row needs to say about when a task runs and stops. */
export function scheduledTaskTiming(task: ScheduledTask): ScheduledTaskTiming {
  const lifecycle = scheduledTaskLifecycle(task);
  return {
    lifecycle,
    cadence: scheduledTaskCadenceLabel(task.schedule),
    nextRunAt: lifecycle === "active" ? task.nextRunAt : null,
    endsAt: task.endsAt ?? null,
    runsLeft: task.maxRuns == null ? null : Math.max(0, task.maxRuns - task.runCount),
  };
}

/** Active timers by next run, then paused ones, then ended ones by most recent run. */
export function sortScheduledTasksByUpcoming(
  tasks: ReadonlyArray<ScheduledTask>,
): ReadonlyArray<ScheduledTask> {
  const rank = (task: ScheduledTask) => {
    const lifecycle = scheduledTaskLifecycle(task);
    return lifecycle === "active" ? 0 : lifecycle === "paused" ? 1 : 2;
  };
  return tasks.toSorted((a, b) => {
    const byRank = rank(a) - rank(b);
    if (byRank !== 0) return byRank;
    if (rank(a) === 0) {
      // Webhook tasks have no next run; they follow the timers.
      return (a.nextRunAt ?? "\uffff").localeCompare(b.nextRunAt ?? "\uffff");
    }
    return (b.lastRunAt ?? b.updatedAt).localeCompare(a.lastRunAt ?? a.updatedAt);
  });
}

/** GitHub's signature settings, the most common sender. */
export const WEBHOOK_SIGNATURE_DEFAULTS = {
  signatureHeader: "x-hub-signature-256",
  signatureEncoding: "hex",
  signaturePrefix: "sha256=",
} as const;

/** Null when the draft's webhook age limit is invalid; the caller reports it and does not save. */
export function scheduleFromDraft(draft: DraftState): ScheduledTaskUpsertSchedule | null {
  if (draft.scheduleMode === "webhook") {
    const maxDeliveryAgeMinutes = parseMaxDeliveryAge(draft.maxDeliveryAgeMinutes);
    if (maxDeliveryAgeMinutes === undefined) return null;
    const secret = draft.signatureSecret.trim();
    return {
      type: "webhook",
      signature: draft.signatureEnabled
        ? {
            header: draft.signatureHeader.trim(),
            encoding: draft.signatureEncoding,
            prefix: draft.signaturePrefix,
            ...(secret ? { secret } : {}),
          }
        : null,
      maxDeliveryAgeMinutes,
    };
  }
  if (draft.scheduleMode === "interval") {
    const everyMs = Math.round(Number(draft.intervalMinutes) * 60_000);
    return { type: "interval", everyMs };
  }
  const selectedEveryDay = draft.weekdays.size === 0 || draft.weekdays.size === 7;
  return {
    type: "fixed_time",
    timeOfDay: draft.timeOfDay || "09:00",
    ...(selectedEveryDay ? {} : { weekdays: [...draft.weekdays].toSorted() }),
  };
}

export function taskToDraft(task: ScheduledTask): DraftState {
  const schedule = task.schedule;
  const weekdays =
    schedule.type === "fixed_time" && schedule.weekdays && schedule.weekdays.length > 0
      ? new Set(schedule.weekdays)
      : new Set([0, 1, 2, 3, 4, 5, 6]);
  return {
    editingId: task.id,
    title: task.title,
    prompt: task.prompt,
    enabled: task.enabled,
    scheduleMode:
      schedule.type === "interval" ? "interval" : schedule.type === "webhook" ? "webhook" : "fixed",
    intervalMinutes:
      schedule.type === "interval" ? String(Math.max(1, schedule.everyMs / 60_000)) : "15",
    timeOfDay: schedule.type === "fixed_time" ? schedule.timeOfDay : "09:00",
    weekdays,
    projectId: task.projectId,
    threadId: task.threadId ?? "",
    workspaceMode: task.workspaceStrategy.type,
    baseRef: task.workspaceStrategy.type === "worktree" ? task.workspaceStrategy.baseRef : "main",
    startFromOrigin:
      task.workspaceStrategy.type === "worktree"
        ? (task.workspaceStrategy.startFromOrigin ?? false)
        : true,
    existingWorktreePath:
      task.workspaceStrategy.type === "existing_worktree"
        ? task.workspaceStrategy.worktreePath
        : "",
    modelKey: `${task.modelSelection.instanceId}:${task.modelSelection.model}`,
    runtimeMode: task.runtimeMode,
    interactionMode: task.interactionMode,
    baseModelSelection: task.modelSelection,
    ...(schedule.type === "webhook" && schedule.signature !== null
      ? {
          signatureEnabled: true,
          signatureHeader: schedule.signature.header,
          signatureEncoding: schedule.signature.encoding,
          signaturePrefix: schedule.signature.prefix,
        }
      : { signatureEnabled: false, ...WEBHOOK_SIGNATURE_DEFAULTS }),
    signatureSecret: "",
    maxDeliveryAgeMinutes:
      schedule.type === "webhook" && schedule.maxDeliveryAgeMinutes != null
        ? String(schedule.maxDeliveryAgeMinutes)
        : "",
    ...EMPTY_END_FIELDS,
    ...(task.endsAt == null
      ? {}
      : { endMode: "at", endAt: toDateTimeLocalInput(task.endsAt), savedEndsAt: task.endsAt }),
    maxRuns: task.maxRuns == null ? "" : String(task.maxRuns),
  };
}

/** Use configured defaults before the catalog's advertised default model. */
export function scheduledTaskDefaultModel(
  settings: ServerSettings,
  project: (LegacyProjectSettingsFields & { readonly id: ProjectId }) | null,
  entries: readonly ProviderInstanceEntry[],
): ModelSelection | null {
  const available = entries.filter(
    (entry) =>
      entry.enabled &&
      entry.installed &&
      entry.isAvailable &&
      entry.snapshot.auth.status !== "unauthenticated",
  );
  const configured = resolveProjectSettings(settings, project?.id ?? null, project).settings
    .defaultModelSelection;
  for (const selection of [configured, settings.defaultModelSelection]) {
    if (
      selection &&
      available.some(
        (entry) =>
          entry.instanceId === selection.instanceId &&
          entry.models.find((model) => model.slug === selection.model)?.isLegacy !== true,
      )
    )
      return selection;
  }
  const models = available.flatMap((entry) =>
    entry.models
      .filter((model) => !model.isLegacy)
      .map((model) => ({ instanceId: entry.instanceId, model })),
  );
  const fallback = models.find(({ model }) => model.isDefault) ?? models[0];
  return fallback ? { instanceId: fallback.instanceId, model: fallback.model.slug } : null;
}
