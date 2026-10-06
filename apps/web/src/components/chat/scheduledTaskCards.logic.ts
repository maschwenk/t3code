import type { ScheduledTask } from "@t3tools/contracts";

export interface ScheduledTaskCardAnchor {
  /** The assistant message whose metadata row closes a turn. */
  readonly messageId: string;
  /** When that message last changed; a schedule made during the turn predates it. */
  readonly updatedAt: string;
}

export interface ScheduledTaskCardPlacement {
  readonly byMessageId: ReadonlyMap<string, ReadonlyArray<ScheduledTask>>;
  /** Schedules made after the last finished reply, shown at the end of the conversation. */
  readonly trailing: ReadonlyArray<ScheduledTask>;
}

const EMPTY_PLACEMENT: ScheduledTaskCardPlacement = { byMessageId: new Map(), trailing: [] };

/**
 * Places each schedule bound to a thread under the reply that ends the turn it
 * was created in, like the agent's confirmation in Codex. Anchors are in
 * timeline order. A schedule older than the loaded history gets no card, so
 * paging in old turns never pins it to the wrong reply.
 */
export function placeScheduledTaskCards(input: {
  readonly tasks: ReadonlyArray<ScheduledTask>;
  readonly anchors: ReadonlyArray<ScheduledTaskCardAnchor>;
  /** Creation time of the oldest loaded timeline row, or null when nothing is loaded. */
  readonly oldestLoadedAt: string | null;
}): ScheduledTaskCardPlacement {
  if (input.tasks.length === 0 || input.oldestLoadedAt === null) return EMPTY_PLACEMENT;
  const oldestMs = Date.parse(input.oldestLoadedAt);
  const anchors = input.anchors.map((anchor) => ({
    messageId: anchor.messageId,
    ms: Date.parse(anchor.updatedAt),
  }));
  const byMessageId = new Map<string, ScheduledTask[]>();
  const trailing: ScheduledTask[] = [];
  for (const task of input.tasks.toSorted((a, b) => a.createdAt.localeCompare(b.createdAt))) {
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
