import { ScheduledTaskId, type ScheduledTask } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import { placeScheduledTaskCards } from "./scheduledTaskCards.logic";

const task = (id: string, createdAt: string) =>
  ({ id: ScheduledTaskId.make(id), createdAt }) as Pick<
    ScheduledTask,
    "id" | "createdAt"
  > as ScheduledTask;

describe("placeScheduledTaskCards", () => {
  const anchors = [
    { messageId: "reply-1", updatedAt: "2026-10-06T12:01:00.000Z" },
    { messageId: "reply-2", updatedAt: "2026-10-06T12:10:00.000Z" },
  ];

  it("puts a schedule under the reply that ends the turn it was made in", () => {
    const placement = placeScheduledTaskCards({
      tasks: [task("made-in-turn-2", "2026-10-06T12:09:30.000Z")],
      anchors,
      oldestLoadedAt: "2026-10-06T12:00:00.000Z",
    });
    expect([...placement.byMessageId.keys()]).toEqual(["reply-2"]);
    expect(placement.trailing).toEqual([]);
  });

  it("keeps a schedule made after the last reply at the end of the conversation", () => {
    const placement = placeScheduledTaskCards({
      tasks: [task("from-dialog", "2026-10-06T12:20:00.000Z")],
      anchors,
      oldestLoadedAt: "2026-10-06T12:00:00.000Z",
    });
    expect(placement.trailing.map((entry) => entry.id)).toEqual(["from-dialog"]);
  });

  it("skips a schedule older than the loaded history", () => {
    const placement = placeScheduledTaskCards({
      tasks: [task("old", "2026-10-01T09:00:00.000Z")],
      anchors,
      oldestLoadedAt: "2026-10-06T12:00:00.000Z",
    });
    expect(placement.byMessageId.size).toBe(0);
    expect(placement.trailing).toEqual([]);
  });
});
