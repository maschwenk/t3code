import {
  scheduledTaskLifecycle,
  type EnvironmentId,
  type ScheduledTask,
  type TimestampFormat,
} from "@t3tools/contracts";
import { scopeThreadRef } from "@t3tools/client-runtime/environment";
import {
  isAtomCommandInterrupted,
  squashAtomCommandFailure,
} from "@t3tools/client-runtime/state/runtime";
import { createFileRoute, useNavigate } from "@tanstack/react-router";
import {
  CalendarClockIcon,
  MessageSquareIcon,
  MoreHorizontalIcon,
  PauseIcon,
  PlayIcon,
  PlusIcon,
  Trash2Icon,
} from "lucide-react";
import { useMemo, useState } from "react";

import { openScheduledTaskEditor } from "../components/chat/ScheduledTaskCards";
import {
  scheduledTaskStatusText,
  sortScheduledTasksByUpcoming,
} from "@t3tools/client-runtime/scheduled-tasks";
import { Button } from "../components/ui/button";
import {
  Empty,
  EmptyDescription,
  EmptyHeader,
  EmptyMedia,
  EmptyTitle,
} from "../components/ui/empty";
import { Menu, MenuItem, MenuPopup, MenuSeparator, MenuTrigger } from "../components/ui/menu";
import { SidebarInset } from "../components/ui/sidebar";
import { stackedThreadToast, toastManager } from "../components/ui/toast";
import { WorkspaceBreadcrumb, WorkspaceBreadcrumbItem } from "../components/WorkspaceBreadcrumb";
import { WorkspacePageContainer } from "../components/WorkspacePageContainer";
import { WorkspacePageHeader } from "../components/WorkspacePageHeader";
import { isElectron } from "../env";
import { useEnvironmentSettings } from "../hooks/useSettings";
import { useEscapeToGoBack } from "../hooks/useNavigateBack";
import { useProjects, useThreadShell } from "../state/entities";
import {
  useEnvironments,
  usePrimaryEnvironmentId,
  type EnvironmentPresentation,
} from "../state/environments";
import { useEnvironmentQuery } from "../state/query";
import { serverEnvironment } from "../state/server";
import { useAtomCommand } from "../state/use-atom-command";
import { buildThreadRouteParams } from "../threadRoutes";
import { formatUpcomingTimestamp } from "../timestampFormat";

export const Route = createFileRoute("/_chat/scheduled")({
  component: ScheduledRouteView,
});

/** Every schedule across connected environments, soonest first, like Codex's Scheduled view. */
function ScheduledRouteView() {
  useEscapeToGoBack();
  const { environments } = useEnvironments();
  const primaryEnvironmentId = usePrimaryEnvironmentId();
  const connected = useMemo(
    () =>
      environments.filter(
        (environment) =>
          environment.connection.phase === "connected" && environment.serverConfig !== null,
      ),
    [environments],
  );
  const newTaskEnvironmentId =
    connected.find((environment) => environment.environmentId === primaryEnvironmentId)
      ?.environmentId ?? connected[0]?.environmentId;
  return (
    <SidebarInset className="h-dvh min-h-0 overflow-hidden overscroll-y-none">
      <div className="flex min-h-0 min-w-0 flex-1 flex-col bg-background">
        <WorkspacePageHeader electron={isElectron} className="relative bg-background">
          <WorkspaceBreadcrumb ariaLabel="Scheduled breadcrumb">
            <WorkspaceBreadcrumbItem current>
              <h1 className="truncate">Scheduled</h1>
            </WorkspaceBreadcrumbItem>
          </WorkspaceBreadcrumb>
          <div className="min-w-0 flex-1" />
          <span className="[-webkit-app-region:no-drag]">
            <Button
              size="xs"
              variant="outline"
              disabled={newTaskEnvironmentId === undefined}
              onClick={() =>
                newTaskEnvironmentId &&
                openScheduledTaskEditor({ environmentId: newTaskEnvironmentId, task: null })
              }
            >
              <PlusIcon className="size-3" />
              New task
            </Button>
          </span>
        </WorkspacePageHeader>
        <div className="topbar-scroll-fade scrollbar-gutter-both min-h-0 flex-1 overflow-y-auto">
          <WorkspacePageContainer>
            {connected.length === 0 ? (
              <Empty>
                <EmptyHeader>
                  <EmptyMedia variant="icon">
                    <CalendarClockIcon />
                  </EmptyMedia>
                  <EmptyTitle>No environments connected</EmptyTitle>
                  <EmptyDescription>
                    Connect an environment to see its scheduled tasks.
                  </EmptyDescription>
                </EmptyHeader>
              </Empty>
            ) : (
              connected.map((environment) => (
                <EnvironmentSchedules
                  key={environment.environmentId}
                  environment={environment}
                  showHeading={connected.length > 1}
                />
              ))
            )}
          </WorkspacePageContainer>
        </div>
      </div>
    </SidebarInset>
  );
}

function EnvironmentSchedules({
  environment,
  showHeading,
}: {
  readonly environment: EnvironmentPresentation;
  readonly showHeading: boolean;
}) {
  const tasksQuery = useEnvironmentQuery(
    serverEnvironment.scheduledTasksLive({ environmentId: environment.environmentId, input: {} }),
  );
  const timestampFormat = useEnvironmentSettings(environment.environmentId).timestampFormat;
  const tasks = useMemo(
    () => sortScheduledTasksByUpcoming(tasksQuery.data?.tasks ?? [], Date.now()),
    [tasksQuery.data],
  );
  const upcoming = tasks.filter((task) => scheduledTaskLifecycle(task, Date.now()) === "active");
  const inactive = tasks.filter((task) => scheduledTaskLifecycle(task, Date.now()) !== "active");
  return (
    <section className="flex flex-col gap-4">
      {showHeading ? (
        <h2 className="text-sm font-medium text-foreground">{environment.label}</h2>
      ) : null}
      {tasksQuery.error ? (
        <p className="text-sm text-destructive">
          Could not load scheduled tasks: {tasksQuery.error}
        </p>
      ) : !tasksQuery.data ? (
        <p className="text-sm text-muted-foreground" role="status">
          Loading scheduled tasks…
        </p>
      ) : tasks.length === 0 ? (
        <Empty>
          <EmptyHeader>
            <EmptyMedia variant="icon">
              <CalendarClockIcon />
            </EmptyMedia>
            <EmptyTitle>Nothing scheduled</EmptyTitle>
            <EmptyDescription>
              Ask an agent in any chat to check something on a schedule, like "every 15 minutes for
              the next 12 hours, check #deploys for new issues".
            </EmptyDescription>
          </EmptyHeader>
        </Empty>
      ) : (
        <>
          <ScheduleList
            title="Upcoming"
            tasks={upcoming}
            environmentId={environment.environmentId}
            timestampFormat={timestampFormat}
          />
          <ScheduleList
            title="Paused and ended"
            tasks={inactive}
            environmentId={environment.environmentId}
            timestampFormat={timestampFormat}
          />
        </>
      )}
    </section>
  );
}

function ScheduleList(props: {
  readonly title: string;
  readonly tasks: ReadonlyArray<ScheduledTask>;
  readonly environmentId: EnvironmentId;
  readonly timestampFormat: TimestampFormat;
}) {
  if (props.tasks.length === 0) return null;
  return (
    <div className="flex flex-col gap-1">
      <h3 className="px-2 text-xs font-medium text-muted-foreground">{props.title}</h3>
      <ul className="m-0 flex list-none flex-col p-0">
        {props.tasks.map((task) => (
          <ScheduleRow
            key={task.id}
            task={task}
            environmentId={props.environmentId}
            timestampFormat={props.timestampFormat}
          />
        ))}
      </ul>
    </div>
  );
}

function ScheduleRow({
  task,
  environmentId,
  timestampFormat,
}: {
  readonly task: ScheduledTask;
  readonly environmentId: EnvironmentId;
  readonly timestampFormat: TimestampFormat;
}) {
  const navigate = useNavigate();
  const threadRef = useMemo(
    () => (task.threadId === null ? null : scopeThreadRef(environmentId, task.threadId)),
    [environmentId, task.threadId],
  );
  const thread = useThreadShell(threadRef);
  const project = useProjects().find(
    (candidate) => candidate.environmentId === environmentId && candidate.id === task.projectId,
  );
  const lifecycle = scheduledTaskLifecycle(task, Date.now());
  const formatTime = (iso: string) => formatUpcomingTimestamp(iso, timestampFormat);
  const [busy, setBusy] = useState(false);
  const setEnabled = useAtomCommand(serverEnvironment.setScheduledTaskEnabled, {
    label: "scheduled view toggle",
  });
  const runNow = useAtomCommand(serverEnvironment.runScheduledTaskNow, {
    label: "scheduled view run now",
  });
  const remove = useAtomCommand(serverEnvironment.deleteScheduledTask, {
    label: "scheduled view delete",
  });
  const act = async (action: "toggle" | "run" | "delete") => {
    if (busy) return;
    setBusy(true);
    const result =
      action === "toggle"
        ? await setEnabled({ environmentId, input: { id: task.id, enabled: !task.enabled } })
        : action === "run"
          ? await runNow({ environmentId, input: { id: task.id } })
          : await remove({ environmentId, input: { id: task.id } });
    setBusy(false);
    if (result._tag === "Failure" && !isAtomCommandInterrupted(result)) {
      toastManager.add(
        stackedThreadToast({
          type: "error",
          title: "Could not update scheduled task",
          description: String(squashAtomCommandFailure(result)),
        }),
      );
    }
  };
  const where = threadRef
    ? (thread?.title ?? "A chat")
    : `New chat each run${project ? ` in ${project.title}` : ""}`;
  return (
    <li className="group flex items-center gap-3 rounded-lg px-2 py-2 hover:bg-accent/50">
      <button
        type="button"
        className="flex min-w-0 flex-1 flex-col items-start text-left"
        onClick={() => openScheduledTaskEditor({ environmentId, task })}
      >
        <span className="w-full truncate text-sm font-medium text-foreground">{task.title}</span>
        <span className="w-full truncate text-xs text-muted-foreground">
          {lifecycle === "active" && task.nextRunAt !== null
            ? `${formatTime(task.nextRunAt)} · `
            : ""}
          {scheduledTaskStatusText(task, formatTime, Date.now())} · {where}
        </span>
      </button>
      {threadRef ? (
        <Button
          size="xs"
          variant="ghost"
          aria-label={`Open the chat for ${task.title}`}
          onClick={() =>
            void navigate({
              to: "/$environmentId/$threadId",
              params: buildThreadRouteParams(threadRef),
            })
          }
        >
          <MessageSquareIcon className="size-3.5" />
          Open chat
        </Button>
      ) : null}
      <Menu>
        <MenuTrigger
          render={
            <Button
              size="icon-sm"
              variant="ghost"
              disabled={busy}
              aria-label={`Actions for ${task.title}`}
            />
          }
        >
          <MoreHorizontalIcon className="size-4" />
        </MenuTrigger>
        <MenuPopup align="end">
          {task.schedule.type === "webhook" ? null : (
            <MenuItem onClick={() => void act("run")}>
              <PlayIcon />
              Run now
            </MenuItem>
          )}
          {lifecycle === "ended" ? null : (
            <MenuItem onClick={() => void act("toggle")}>
              {task.enabled ? <PauseIcon /> : <PlayIcon />}
              {task.enabled ? "Pause" : "Resume"}
            </MenuItem>
          )}
          <MenuSeparator />
          <MenuItem onClick={() => void act("delete")}>
            <Trash2Icon />
            Delete
          </MenuItem>
        </MenuPopup>
      </Menu>
    </li>
  );
}
