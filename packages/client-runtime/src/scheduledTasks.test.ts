import { ScheduledTaskId, type ScheduledTask } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import { placeScheduledTaskCards, sortScheduledTasksByUpcoming } from "./scheduledTasks.ts";

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

describe("sortScheduledTasksByUpcoming", () => {
  const base = {
    title: "Watch",
    prompt: "Check",
    enabled: true,
    schedule: { type: "interval", everyMs: 900_000 },
    projectId: "project",
    threadId: null,
    endsAt: "2026-10-06T23:59:59.250Z",
    maxRuns: null,
    createdAt: "2026-10-06T11:00:00.000Z",
    updatedAt: "2026-10-06T11:00:00.000Z",
    lastRunAt: null,
    runCount: 0,
  };
  const task = (id: string, overrides: Record<string, unknown>) =>
    ({ ...base, id: ScheduledTaskId.make(id), ...overrides }) as unknown as ScheduledTask;

  it("lists active schedules by next run ahead of paused and ended ones", () => {
    const ordered = sortScheduledTasksByUpcoming(
      [
        task("ended", { nextRunAt: null }),
        task("paused", { enabled: false, nextRunAt: null }),
        task("later", { nextRunAt: "2026-10-06T13:00:00.000Z" }),
        task("sooner", { nextRunAt: "2026-10-06T12:15:00.000Z" }),
        task("webhook-spent", {
          schedule: { type: "webhook", signature: null },
          nextRunAt: null,
          endsAt: null,
          maxRuns: 2,
          runCount: 2,
        }),
      ],
      Date.parse("2026-10-06T12:00:00.000Z"),
    );
    expect(ordered.map((entry) => entry.id)).toEqual([
      "sooner",
      "later",
      "paused",
      "ended",
      "webhook-spent",
    ]);
  });
});
