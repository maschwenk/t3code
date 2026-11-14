import { describe, expect, it } from "@effect/vitest";
import * as DateTime from "effect/DateTime";

import { inferUnsettleCause, replayDecision } from "./settle-audit.ts";

const DECIDED_AT = "2026-11-13T14:13:58.616Z";
const at = (iso: string) => DateTime.makeUnsafe(iso);

// The fields the settle rules read, with the DateTime values the server holds.
const thread = (overrides: Record<string, unknown> = {}) => ({
  id: "thread-1",
  projectId: "project-1",
  branch: null,
  worktreePath: null,
  pullRequests: [],
  linkedPullRequest: null,
  branchPullRequest: null,
  createdAt: at("2026-11-01T00:00:00.000Z"),
  updatedAt: at("2026-11-03T00:00:00.000Z"),
  archivedAt: null,
  settledOverride: null,
  pinnedAt: null,
  snoozedUntil: null,
  snoozedAt: null,
  status: "completed",
  latestRunId: "run-1",
  latestRunRequestedAt: at("2026-11-03T00:00:00.000Z"),
  latestRunStartedAt: at("2026-11-03T00:00:00.000Z"),
  latestRunCompletedAt: at("2026-11-03T00:10:00.000Z"),
  latestUserMessageAt: at("2026-11-03T00:00:00.000Z"),
  latestUserAuthoredMessageAt: at("2026-11-03T00:00:00.000Z"),
  activityRunStatus: null,
  activityRunStartedAt: null,
  pendingRuntimeRequest: null,
  pendingBackgroundTasks: [],
  pendingGuestMessageCount: 0,
  ...overrides,
});

const mergedLink = {
  host: "github.com",
  repository: "acme/app",
  number: 42,
  url: "https://github.com/acme/app/pull/42",
  source: "agent",
  linkedAt: "2026-11-02T00:00:00.000Z",
  snapshot: {
    state: "merged",
    title: "Pull request",
    headBranch: "feature",
    baseBranch: "main",
    isDraft: false,
    updatedAt: "2026-11-13T14:13:37.000Z",
    syncedAt: "2026-11-13T14:13:55.000Z",
    mergedAt: "2026-11-13T14:13:37.000Z",
  },
  stack: null,
};

// Rows as the decision log writes them: inputs and settings through JSON.stringify.
const row = (input: {
  readonly inputs: ReturnType<typeof thread>;
  readonly replyCheck?: unknown;
}) => ({
  id: 1,
  decided_at: DECIDED_AT,
  thread_id: "thread-1",
  outcome: "settled" as const,
  rule: "auto_inactivity",
  hold_reason: null,
  trigger: "full_sweep",
  run_id: "run-1",
  reply_check_json: input.replyCheck === undefined ? null : JSON.stringify(input.replyCheck),
  inputs_json: JSON.stringify({ thread: input.inputs, pullRequest: null }),
  settings_json: JSON.stringify({
    onMerge: true,
    afterDays: 3,
    keepPullRequests: false,
    replyCheck: true,
  }),
  server_version: "0.1.7-test",
});

describe("replayDecision", () => {
  // Each row only replays right if the JSON dates come back as DateTimes.
  it.each([
    {
      name: "an idle thread settles on inactivity",
      inputs: thread(),
      expected: { outcome: "settled", rule: "auto_inactivity", holdReason: null },
    },
    {
      name: "a snooze holds the inactivity rule",
      inputs: thread({ snoozedUntil: at("2026-11-20T00:00:00.000Z"), snoozedAt: at(DECIDED_AT) }),
      expected: { outcome: "held", rule: "auto_inactivity", holdReason: "snoozed" },
    },
    {
      name: "a live watch holds the merge rule",
      inputs: thread({
        pullRequests: [mergedLink],
        pendingBackgroundTasks: [
          { taskId: "pull-request-watch:github.com/acme/app#42", kind: "monitor", awaited: true },
        ],
      }),
      expected: {
        outcome: "held",
        rule: "auto_pull_request_merged",
        holdReason: "background_work",
      },
    },
    {
      name: "the recorded reply check holds the merge rule",
      inputs: thread({
        pullRequests: [mergedLink],
        latestRunCompletedAt: at("2026-11-13T14:10:02.000Z"),
        latestUserMessageAt: at("2026-11-13T13:44:42.000Z"),
        latestUserAuthoredMessageAt: at("2026-11-13T13:44:42.000Z"),
      }),
      replyCheck: { outcome: "holds", reason: "needs_user" },
      expected: { outcome: "held", rule: "auto_pull_request_merged", holdReason: "needs_user" },
    },
  ])("$name", ({ inputs, replyCheck, expected }) => {
    expect(replayDecision(row({ inputs, replyCheck }))).toEqual(expected);
  });
});

describe("inferUnsettleCause", () => {
  it.each([
    [
      "thread.unsettled",
      { createdBy: "agent", scheduledTaskId: "task:check-in" },
      "scheduled_task",
    ],
    ["thread.unsettled", { createdBy: "agent", notification: { summary: "#7" } }, "notification"],
    ["thread.unsettled", { createdBy: "user" }, "user_message"],
    ["thread.unsettled", { createdBy: "agent" }, "agent_message"],
    ["thread.unsettled", null, "user"],
    ["thread.pinned", null, "pin"],
    ["thread.guest-share-updated", null, "guest"],
  ] as const)("%s with %j reads as %s", (eventType, message, cause) => {
    expect(inferUnsettleCause(eventType, message)).toBe(cause);
  });
});
