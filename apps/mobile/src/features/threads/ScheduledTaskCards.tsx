import type { EnvironmentId, ScheduledTask, ThreadId } from "@t3tools/contracts";
import {
  NO_SCHEDULED_TASK_CARDS,
  placeScheduledTaskCards,
  scheduledTaskStatusText,
  scheduledTaskTiming,
  type ScheduledTaskCardPlacement,
} from "@t3tools/client-runtime/scheduled-tasks";
import { useNavigation } from "@react-navigation/native";
import { createContext, use, useMemo, type ReactNode } from "react";
import { Pressable, View } from "react-native";

import { AppText as Text } from "../../components/AppText";
import { SymbolView } from "../../components/AppSymbol";
import type { ThreadFeedEntry } from "../../lib/threadActivity";
import { useEnvironmentPresentation } from "../../state/presentation";
import { useEnvironmentQuery } from "../../state/query";
import { serverEnvironment } from "../../state/server";
import { editDraft } from "../settings/scheduledTaskDraft";
import { startScheduledTaskEditor } from "../settings/scheduled-task-editor-state";

interface CardsValue extends ScheduledTaskCardPlacement {
  readonly environmentId: EnvironmentId;
}

const CardsContext = createContext<CardsValue | null>(null);

function formatTime(iso: string): string {
  return new Date(iso).toLocaleString([], { weekday: "short", hour: "numeric", minute: "2-digit" });
}

/**
 * Owns the schedule subscription for an open thread, so a schedule change
 * re-renders only this provider and the cards; `children` is the feed its
 * parent already built. Placement stays the same object in threads without
 * schedules.
 */
export function ThreadScheduledTaskCardsProvider(props: {
  readonly environmentId: EnvironmentId;
  readonly threadId: ThreadId;
  readonly feed: ReadonlyArray<ThreadFeedEntry>;
  readonly children: ReactNode;
}) {
  const tasksQuery = useEnvironmentQuery(
    serverEnvironment.scheduledTasksLive({ environmentId: props.environmentId, input: {} }),
  );
  const allTasks = tasksQuery.data?.tasks;
  const boundTasks = useMemo(
    () => (allTasks ?? []).filter((task) => task.threadId === props.threadId),
    [allTasks, props.threadId],
  );
  const placement = useMemo(() => {
    if (boundTasks.length === 0) return NO_SCHEDULED_TASK_CARDS;
    // The last assistant message of each run ends that turn.
    const lastByRun = new Map<string, { messageId: string; updatedAt: string }>();
    for (const entry of props.feed) {
      if (entry.type === "message" && entry.message.role === "assistant" && entry.message.runId) {
        lastByRun.set(entry.message.runId, {
          messageId: entry.message.id,
          updatedAt: entry.message.updatedAt,
        });
      }
    }
    return placeScheduledTaskCards({
      tasks: boundTasks,
      anchors: [...lastByRun.values()].toSorted((a, b) => a.updatedAt.localeCompare(b.updatedAt)),
      oldestLoadedAt: props.feed[0]?.createdAt ?? null,
    });
  }, [boundTasks, props.feed]);
  const value = useMemo(
    () => ({ ...placement, environmentId: props.environmentId }),
    [placement, props.environmentId],
  );
  return <CardsContext value={value}>{props.children}</CardsContext>;
}

function ScheduledTaskCard(props: {
  readonly task: ScheduledTask;
  readonly environmentId: EnvironmentId;
}) {
  const navigation = useNavigation();
  const { presentation } = useEnvironmentPresentation(props.environmentId);
  const nowMs = Date.now();
  const timing = scheduledTaskTiming(props.task, nowMs);
  const status = scheduledTaskStatusText(props.task, formatTime, nowMs);
  const open = () => {
    startScheduledTaskEditor({
      environmentId: props.environmentId,
      environmentLabel: presentation?.entry.target.label ?? "",
      draft: editDraft(props.task),
    });
    navigation.navigate("SettingsSheet", {
      screen: "SettingsContent",
      params: { screen: "SettingsScheduledTaskEdit" },
    });
  };
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={`Open scheduled task ${props.task.title}`}
      onPress={open}
      className="mt-2 flex-row items-center gap-3 rounded-[14px] border border-border-subtle px-3 py-2.5 active:opacity-70"
    >
      <SymbolView name="clock" size={16} tintColorClassName="accent-icon" />
      <View className="min-w-0 flex-1">
        <Text className="text-base font-t3-medium text-foreground" numberOfLines={1}>
          {props.task.title}
        </Text>
        <Text className="text-sm text-foreground-muted" numberOfLines={1}>
          {timing.nextRunAt !== null ? `Next ${formatTime(timing.nextRunAt)} · ` : ""}
          {status}
        </Text>
      </View>
      <Text className="text-sm font-t3-medium text-foreground-muted">Open</Text>
    </Pressable>
  );
}

/** Cards for the schedules made in the turn this reply ends. */
export function ScheduledTaskCardsForMessage({ messageId }: { readonly messageId: string }) {
  const value = use(CardsContext);
  const tasks = value?.byMessageId.get(messageId);
  if (!value || !tasks) return null;
  return tasks.map((task) => (
    <ScheduledTaskCard key={task.id} task={task} environmentId={value.environmentId} />
  ));
}

/** Schedules made after the last finished reply. */
export function TrailingScheduledTaskCards() {
  const value = use(CardsContext);
  if (!value || value.trailing.length === 0) return null;
  return (
    <View className="px-1 pb-4">
      {value.trailing.map((task) => (
        <ScheduledTaskCard key={task.id} task={task} environmentId={value.environmentId} />
      ))}
    </View>
  );
}
