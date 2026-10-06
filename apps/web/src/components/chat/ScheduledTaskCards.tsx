import { useAtomValue } from "@effect/atom-react";
import type {
  EnvironmentId,
  ScheduledTask,
  ScheduledTaskId,
  ScopedThreadRef,
  TimestampFormat,
} from "@t3tools/contracts";
import { CalendarClockIcon } from "lucide-react";
import { Atom } from "effect/reactivity";
import { createContext, use, useCallback, useMemo } from "react";

import { appAtomRegistry } from "~/rpc/atomRegistry";
import { useThreadShell } from "~/state/entities";
import { useEnvironmentQuery } from "~/state/query";
import { serverEnvironment } from "~/state/server";
import { formatUpcomingTimestamp } from "~/timestampFormat";

import {
  ScheduledTaskEditorDialog,
  scheduledTaskStatusText,
  type ScheduledTaskThreadContext,
} from "../settings/ScheduledTasksSettings";
import { SettingsScopeProvider } from "../settings/SettingsScopeContext";
import { scheduledTaskTiming } from "../settings/scheduledTasksSettings.logic";
import type { MessagesTimelineRow } from "./MessagesTimeline.logic";
import {
  placeScheduledTaskCards,
  type ScheduledTaskCardPlacement,
} from "./scheduledTaskCards.logic";
import { Button } from "../ui/button";

interface ScheduledTaskEditorRequest {
  readonly environmentId: EnvironmentId;
  readonly task: ScheduledTask | null;
  readonly thread?: ScheduledTaskThreadContext | null;
}

/**
 * Which schedule the editor shows, set by any entry point (inline card, run
 * attribution, thread panel, Scheduled view, command palette) and rendered
 * once by the chat layout so it outlives whatever opened it.
 */
const scheduledTaskEditorAtom = Atom.make<ScheduledTaskEditorRequest | null>(null).pipe(
  Atom.keepAlive,
  Atom.withLabel("scheduled-tasks:editor"),
);

export function openScheduledTaskEditor(request: ScheduledTaskEditorRequest): void {
  appAtomRegistry.set(scheduledTaskEditorAtom, request);
}

const ALL_ENVIRONMENTS_SCOPE = {};
const ignoreScopeChange = () => {};

/** Mounted once by the chat layout. */
export function ScheduledTaskEditorHost() {
  const request = useAtomValue(scheduledTaskEditorAtom);
  if (request === null) return null;
  return (
    <SettingsScopeProvider search={ALL_ENVIRONMENTS_SCOPE} onChange={ignoreScopeChange}>
      <ScheduledTaskEditorDialog
        key={`${request.environmentId}:${request.task?.id ?? request.thread?.threadId ?? "new"}`}
        initialEnvironmentId={request.environmentId}
        task={request.task}
        thread={request.thread ?? null}
        onClose={() => appAtomRegistry.set(scheduledTaskEditorAtom, null)}
      />
    </SettingsScopeProvider>
  );
}

/** Opens the editor for a new schedule that posts into this thread. */
export function useScheduleInThread(threadRef: ScopedThreadRef | null): (() => void) | null {
  const shell = useThreadShell(threadRef);
  const open = useCallback(() => {
    if (threadRef === null || shell === null) return;
    openScheduledTaskEditor({
      environmentId: threadRef.environmentId,
      task: null,
      thread: {
        threadId: threadRef.threadId,
        projectId: shell.projectId,
        modelSelection: shell.modelSelection,
        runtimeMode: shell.runtimeMode,
        interactionMode: shell.interactionMode,
      },
    });
  }, [shell, threadRef]);
  return threadRef === null || shell === null ? null : open;
}

interface ThreadScheduledTaskCardsValue extends ScheduledTaskCardPlacement {
  readonly environmentId: EnvironmentId | null;
  readonly timestampFormat: TimestampFormat;
  readonly tasksById: ReadonlyMap<ScheduledTaskId, ScheduledTask>;
}

const ThreadScheduledTaskCardsContext = createContext<ThreadScheduledTaskCardsValue | null>(null);
const NO_CARDS: ScheduledTaskCardPlacement = { byMessageId: new Map(), trailing: [] };
export const ThreadScheduledTaskCardsProvider = ThreadScheduledTaskCardsContext;

/** The schedules bound to the open thread, placed against its timeline rows. */
export function useThreadScheduledTaskCards(input: {
  readonly threadRef: ScopedThreadRef | null;
  readonly rows: ReadonlyArray<MessagesTimelineRow>;
  readonly timestampFormat: TimestampFormat;
}): ThreadScheduledTaskCardsValue {
  const { threadRef, rows, timestampFormat } = input;
  const tasksQuery = useEnvironmentQuery(
    threadRef === null
      ? null
      : serverEnvironment.scheduledTasksLive({ environmentId: threadRef.environmentId, input: {} }),
  );
  const allTasks = tasksQuery.data?.tasks;
  const boundTasks = useMemo(
    () =>
      threadRef === null
        ? []
        : (allTasks ?? []).filter((task) => task.threadId === threadRef.threadId),
    [allTasks, threadRef],
  );
  const placement = useMemo(() => {
    // Most threads have no schedules; skip walking rows on every streamed update.
    if (boundTasks.length === 0) return NO_CARDS;
    const anchors = rows.flatMap((row) =>
      row.kind === "assistant-meta" ||
      (row.kind === "message" && row.message.role === "assistant" && row.showAssistantMeta)
        ? [{ messageId: row.message.id, updatedAt: row.message.updatedAt }]
        : [],
    );
    const oldest = rows.find((row) => "createdAt" in row);
    return placeScheduledTaskCards({
      tasks: boundTasks,
      anchors,
      oldestLoadedAt: oldest && "createdAt" in oldest ? oldest.createdAt : null,
    });
  }, [boundTasks, rows]);
  const tasksById = useMemo(
    () => new Map((allTasks ?? []).map((task) => [task.id, task] as const)),
    [allTasks],
  );
  return useMemo(
    () => ({
      ...placement,
      environmentId: threadRef?.environmentId ?? null,
      timestampFormat,
      tasksById,
    }),
    [placement, tasksById, threadRef, timestampFormat],
  );
}

function ScheduledTaskInlineCard({
  task,
  environmentId,
  timestampFormat,
}: {
  readonly task: ScheduledTask;
  readonly environmentId: EnvironmentId;
  readonly timestampFormat: TimestampFormat;
}) {
  const timing = scheduledTaskTiming(task);
  const formatTime = (iso: string) => formatUpcomingTimestamp(iso, timestampFormat);
  const status = scheduledTaskStatusText(task, formatTime);
  return (
    <div
      className="mt-2 flex w-full max-w-md items-center gap-3 rounded-xl border border-border/70 bg-card px-3 py-2.5"
      data-scheduled-task-card={task.id}
    >
      <CalendarClockIcon className="size-4 shrink-0 text-muted-foreground" aria-hidden />
      <div className="min-w-0 flex-1">
        <p className="truncate text-sm font-medium text-foreground">{task.title}</p>
        <p className="truncate text-xs text-muted-foreground">
          {timing.nextRunAt !== null ? `Next ${formatTime(timing.nextRunAt)} · ` : ""}
          {status}
        </p>
      </div>
      <Button
        size="xs"
        variant="outline"
        onClick={() => openScheduledTaskEditor({ environmentId, task })}
      >
        Open
      </Button>
    </div>
  );
}

/** Cards for the schedules made in the turn this reply ends. */
export function ScheduledTaskCardsForMessage({ messageId }: { readonly messageId: string }) {
  const value = use(ThreadScheduledTaskCardsContext);
  const tasks = value?.byMessageId.get(messageId);
  const environmentId = value?.environmentId ?? null;
  if (!value || !tasks || environmentId === null) return null;
  return (
    <div className="flex flex-col gap-1 px-1">
      {tasks.map((task) => (
        <ScheduledTaskInlineCard
          key={task.id}
          task={task}
          environmentId={environmentId}
          timestampFormat={value.timestampFormat}
        />
      ))}
    </div>
  );
}

/** Schedules made after the last finished reply, such as from the schedule dialog. */
export function TrailingScheduledTaskCards() {
  const value = use(ThreadScheduledTaskCardsContext);
  const environmentId = value?.environmentId ?? null;
  if (!value || value.trailing.length === 0 || environmentId === null) return null;
  return (
    <div className="messages-timeline-row-frame">
      <div className="chat-content-lane flex flex-col gap-1 px-1">
        {value.trailing.map((task) => (
          <ScheduledTaskInlineCard
            key={task.id}
            task={task}
            environmentId={environmentId}
            timestampFormat={value.timestampFormat}
          />
        ))}
      </div>
    </div>
  );
}

/** The schedule a run came from, when this client can still see it. */
export function useScheduledTaskForRun(taskId: ScheduledTaskId | undefined) {
  const value = use(ThreadScheduledTaskCardsContext);
  if (!value || taskId === undefined || value.environmentId === null) return null;
  const task = value.tasksById.get(taskId);
  return task ? { task, environmentId: value.environmentId } : null;
}
