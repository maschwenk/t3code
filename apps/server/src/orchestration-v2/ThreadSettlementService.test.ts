import { SourceControlProviderKind } from "@t3tools/contracts";
import { assert, describe, expect, it } from "@effect/vitest";
import * as DateTime from "effect/DateTime";
import {
  DEFAULT_SERVER_SETTINGS,
  MessageId,
  ProjectId,
  EventId,
  ProviderInstanceId,
  RuntimeRequestId,
  RunId,
  ScheduledTaskId,
  TextGenerationError,
  ThreadId,
  TurnItemId,
  type OrchestrationProjectShell,
  type OrchestrationV2AppThread,
  type OrchestrationV2Command,
  type OrchestrationV2ConversationMessage,
  type OrchestrationV2DomainEvent,
  type OrchestrationV2Run,
  type OrchestrationV2ShellSnapshot,
  type OrchestrationV2ThreadProjection,
  type OrchestrationV2ThreadShell,
  type PullRequestSummary,
  type ServerSettings as ContractServerSettings,
  type ServerSettingsPatch,
} from "@t3tools/contracts";
import type { SettlementReplyCheckInput } from "@t3tools/provider-core/server/textGeneration";
import { applyServerSettingsPatch } from "@t3tools/shared/serverSettings";
import * as NodeSqliteClient from "@t3tools/shared/nodeSqliteClient";
import * as SecureRandom from "effect/crypto/SecureRandom";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import * as PlatformError from "effect/PlatformError";
import * as PubSub from "effect/PubSub";
import * as Queue from "effect/Queue";
import * as Ref from "effect/Ref";
import * as Stream from "effect/Stream";
import * as SqlClient from "effect/sql/SqlClient";
import { TestClock } from "effect/testing";

import * as GitManager from "../git/GitManager.ts";
import * as SettlementDecisions from "../persistence/SettlementDecisions.ts";
import * as SqlitePersistence from "../persistence/Sqlite.ts";
import * as ProjectSetupScriptRunner from "../project/ProjectSetupScriptRunner.ts";
import * as PullRequestService from "../pullRequest/PullRequestService.ts";
import * as ServerActivation from "../serverActivation.ts";
import * as ServerSettings from "../serverSettings.ts";
import * as TerminalManager from "../terminal/Manager.ts";
import * as TextGeneration from "../textGeneration/TextGeneration.ts";
import * as CompletionNotificationTriage from "./CompletionNotificationTriage.ts";
import * as ProjectStore from "./ProjectStore.ts";
import * as Orchestrator from "./Orchestrator.ts";
import * as ProjectionStore from "./ProjectionStore.ts";
import * as ThreadSettlementService from "./ThreadSettlementService.ts";

const NOW_MS = Date.parse("2026-06-10T12:00:00.000Z");
const DAY_MS = 24 * 60 * 60 * 1_000;

function at(offsetMs: number): DateTime.Utc {
  return DateTime.makeUnsafe(NOW_MS + offsetMs);
}

type SettlementShell = OrchestrationV2ThreadShell &
  Pick<
    ProjectionStore.ProjectionSettlementCandidate,
    "latestUserAuthoredMessageAt" | "automatedRunWindows"
  >;

function shell(overrides: Partial<SettlementShell> = {}): SettlementShell {
  return {
    id: ThreadId.make("thread-1"),
    projectId: ProjectId.make("project-1"),
    title: "Thread",
    providerInstanceId: ProviderInstanceId.make("codex"),
    modelSelection: { instanceId: ProviderInstanceId.make("codex"), model: "gpt-5.4" },
    runtimeMode: "full-access",
    interactionMode: "default",
    worktreePath: null,
    activeProviderThreadId: null,
    lineage: {
      rootThreadId: ThreadId.make("thread-1"),
      parentThreadId: null,
      relationshipToParent: null,
    },
    forkedFrom: null,
    createdBy: "user",
    creationSource: "web",
    activeRunId: null,
    latestVisibleMessage: null,
    hasActionableProposedPlan: false,
    itemCount: 0,
    visibleItemCount: 0,
    lastVisitedAt: null,
    deletedAt: null,
    branch: null,
    linkedPullRequest: null,
    status: "idle",
    activityRunStatus: null,
    pendingRuntimeRequest: null,
    pendingBackgroundTasks: [],
    latestRunId: null,
    latestRunRequestedAt: null,
    latestRunStartedAt: null,
    latestRunCompletedAt: null,
    latestUserMessageAt: null,
    latestUserAuthoredMessageAt: overrides.latestUserMessageAt ?? null,
    createdAt: at(-30 * DAY_MS),
    updatedAt: at(-10 * DAY_MS),
    archivedAt: null,
    settledOverride: null,
    settledAt: null,
    snoozedUntil: null,
    snoozedAt: null,
    pinnedAt: null,
    ...overrides,
  };
}

function persistedLink(
  state: "open" | null,
  linkedAt: DateTime.Utc,
): NonNullable<SettlementShell["pullRequests"]>[number] {
  return {
    host: "example.test",
    repository: "owner/repository",
    number: 42,
    url: "https://example.test/owner/repository/pull/42",
    source: "manual",
    linkedAt: DateTime.formatIso(linkedAt),
    snapshot:
      state === null
        ? null
        : {
            state,
            title: "Pull request",
            headBranch: "feature",
            baseBranch: "main",
            isDraft: false,
            updatedAt: DateTime.formatIso(linkedAt),
            syncedAt: DateTime.formatIso(linkedAt),
          },
    stack: null,
  };
}

describe("isAutoSettlementCandidate", () => {
  it("settles a thread whose only background work is a command left running", () => {
    expect(
      ThreadSettlementService.isAutoSettlementCandidate(
        shell({
          pendingBackgroundTasks: [
            { taskId: "dev", kind: "command", description: "vp run dev --share" },
          ],
        }),
        NOW_MS,
      ),
    ).toBe(true);
    // A pull request watch whose checks finished holds nothing, yet still keeps the thread.
    expect(
      ThreadSettlementService.isAutoSettlementCandidate(
        shell({
          pendingBackgroundTasks: [
            { taskId: "pull-request-watch:github.com/acme/app#1", kind: "monitor" },
          ],
        }),
        NOW_MS,
      ),
    ).toBe(false);
  });

  it("never settles, or keeps snoozed, a thread whose guest is waiting on the owner", () => {
    expect(
      ThreadSettlementService.isAutoSettlementCandidate(
        shell({ pendingGuestMessageCount: 1 }),
        NOW_MS,
      ),
    ).toBe(false);
    const snoozed = shell({
      snoozedUntil: at(60 * 60 * 1_000),
      snoozedAt: at(-60 * 60 * 1_000),
      pendingGuestMessageCount: 1,
    });
    expect(ThreadSettlementService.isSnoozed(snoozed, NOW_MS)).toBe(false);
  });

  it("keeps snoozed threads parked until a fresh failure or timer wake", () => {
    const snoozed = shell({
      snoozedUntil: at(60 * 60 * 1_000),
      snoozedAt: at(-60 * 60 * 1_000),
    });
    expect(ThreadSettlementService.isAutoSettlementCandidate(snoozed, NOW_MS)).toBe(false);
    expect(
      ThreadSettlementService.isAutoSettlementCandidate(
        shell({ ...snoozed, status: "failed", latestRunCompletedAt: at(-30 * 60 * 1_000) }),
        NOW_MS,
      ),
    ).toBe(true);
    expect(
      ThreadSettlementService.isAutoSettlementCandidate(
        shell({ ...snoozed, status: "failed", latestRunCompletedAt: at(-2 * 60 * 60 * 1_000) }),
        NOW_MS,
      ),
    ).toBe(false);
    expect(
      ThreadSettlementService.isAutoSettlementCandidate(
        shell({ ...snoozed, status: "failed", latestRunCompletedAt: snoozed.snoozedAt }),
        NOW_MS,
      ),
    ).toBe(false);
    expect(
      ThreadSettlementService.isAutoSettlementCandidate(
        shell({ ...snoozed, status: "failed", latestRunCompletedAt: null }),
        NOW_MS,
      ),
    ).toBe(false);
    expect(
      ThreadSettlementService.isAutoSettlementCandidate(
        shell({ ...snoozed, snoozedUntil: at(-1) }),
        NOW_MS,
      ),
    ).toBe(true);
  });
});

describe("resolveAutoSettlementAt", () => {
  it("keeps threads with a PR from inactivity settlement only when asked", () => {
    const input = {
      thread: shell({
        latestUserMessageAt: at(-4 * DAY_MS),
        linkedPullRequest: {
          projectId: ProjectId.make("project-1"),
          repository: "owner/repo",
          number: 1,
          url: "https://example.test/owner/repo/pull/1",
        },
      }),
      pullRequest: null,
      nowMs: NOW_MS,
      autoSettleAfterDays: 3,
      autoSettleOnMerge: true,
      autoSettleKeepPullRequests: true,
    };
    expect(ThreadSettlementService.resolveAutoSettlementAt(input)).toBeNull();
    expect(
      ThreadSettlementService.resolveAutoSettlementAt({
        ...input,
        autoSettleKeepPullRequests: false,
      }),
    ).toEqual(at(-4 * DAY_MS));
    expect(
      ThreadSettlementService.resolveAutoSettlementAt({
        ...input,
        pullRequest: { state: "merged", mergedAt: DateTime.formatIso(at(-1)) },
      }),
    ).toEqual(at(-4 * DAY_MS));
  });

  it("settles an idle thread with an open persisted link only while retention is off", () => {
    const input = {
      thread: shell({
        latestUserMessageAt: at(-4 * DAY_MS),
        pullRequests: [persistedLink("open", at(-5 * DAY_MS))],
      }),
      pullRequest: null,
      nowMs: NOW_MS,
      autoSettleAfterDays: 3,
      autoSettleOnMerge: true,
      autoSettleKeepPullRequests: false,
    };
    expect(ThreadSettlementService.resolveAutoSettlementAt(input)).toEqual(at(-4 * DAY_MS));
    expect(
      ThreadSettlementService.resolveAutoSettlementAt({
        ...input,
        autoSettleKeepPullRequests: true,
      }),
    ).toBeNull();
    // The open link outranks a merged lookup, so only inactivity can settle it.
    expect(
      ThreadSettlementService.resolveAutoSettlementAt({
        ...input,
        pullRequest: { state: "merged", mergedAt: DateTime.formatIso(at(-1)) },
        autoSettleAfterDays: null,
      }),
    ).toBeNull();
  });

  it("keeps an idle thread whose persisted link was never synced", () => {
    expect(
      ThreadSettlementService.resolveAutoSettlementAt({
        thread: shell({
          latestUserMessageAt: at(-4 * DAY_MS),
          pullRequests: [persistedLink(null, at(-5 * DAY_MS))],
        }),
        pullRequest: null,
        nowMs: NOW_MS,
        autoSettleAfterDays: 3,
        autoSettleOnMerge: true,
        autoSettleKeepPullRequests: false,
      }),
    ).toBeNull();
  });

  it("uses the latest activity time when the inactivity window elapses", () => {
    const idle = shell({
      latestUserMessageAt: at(-4 * DAY_MS),
      latestRunRequestedAt: at(-4 * DAY_MS),
      latestRunStartedAt: at(-4 * DAY_MS),
      latestRunCompletedAt: at(-3 * DAY_MS),
    });
    const input = {
      thread: idle,
      pullRequest: null,
      nowMs: NOW_MS,
      autoSettleAfterDays: 2,
      autoSettleOnMerge: true,
    };
    expect(ThreadSettlementService.resolveAutoSettlementAt(input)).toEqual(at(-3 * DAY_MS));
    expect(
      ThreadSettlementService.resolveAutoSettlementAt({ ...input, autoSettleAfterDays: 5 }),
    ).toBeNull();
    expect(
      ThreadSettlementService.resolveAutoSettlementAt({ ...input, autoSettleAfterDays: null }),
    ).toBeNull();
  });

  it("anchors an empty thread's inactivity at its creation time", () => {
    const input = {
      thread: shell({ createdAt: at(-3 * DAY_MS) }),
      pullRequest: null,
      nowMs: NOW_MS,
      autoSettleAfterDays: 2,
      autoSettleOnMerge: false,
    };
    expect(ThreadSettlementService.resolveAutoSettlementAt(input)).toEqual(at(-3 * DAY_MS));
    expect(
      ThreadSettlementService.resolveAutoSettlementAt({
        ...input,
        thread: shell({ createdAt: at(-DAY_MS) }),
      }),
    ).toBeNull();
    expect(
      ThreadSettlementService.resolveAutoSettlementAt({
        ...input,
        thread: { ...input.thread, lastSnoozeWakeAt: at(-DAY_MS) },
      }),
    ).toBeNull();
  });

  it.each(["manual", "timer"])("restarts inactivity on a %s snooze wake", (wake) => {
    const thread = {
      ...shell({ latestRunCompletedAt: at(-4 * DAY_MS) }),
      ...(wake === "manual"
        ? { lastSnoozeWakeAt: at(-1_000) }
        : { snoozedAt: at(-3 * DAY_MS), snoozedUntil: at(-1_000) }),
    };
    const input = {
      thread,
      pullRequest: null,
      nowMs: NOW_MS,
      autoSettleAfterDays: 1,
      autoSettleOnMerge: false,
    };
    expect(ThreadSettlementService.resolveAutoSettlementAt(input)).toBeNull();
    expect(
      ThreadSettlementService.resolveAutoSettlementAt({ ...input, nowMs: NOW_MS + DAY_MS }),
    ).toEqual(at(-1_000));
  });

  it("settles on merge only after the user's last action and preserves the activity time", () => {
    const thread = shell({
      latestUserMessageAt: at(-2 * 60 * 60 * 1_000),
      latestRunCompletedAt: at(-90 * 60 * 1_000),
    });
    const input = {
      thread,
      pullRequest: {
        state: "merged" as const,
        mergedAt: DateTime.formatIso(at(-60 * 60 * 1_000)),
      },
      nowMs: NOW_MS,
      autoSettleAfterDays: null,
      autoSettleOnMerge: true,
    };
    expect(ThreadSettlementService.resolveAutoSettlementAt(input)).toEqual(at(-90 * 60 * 1_000));
    expect(
      ThreadSettlementService.resolveAutoSettlementAt({ ...input, autoSettleOnMerge: false }),
    ).toBeNull();
    expect(
      ThreadSettlementService.resolveAutoSettlementAt({
        ...input,
        pullRequest: { state: "merged", mergedAt: DateTime.formatIso(at(-3 * 60 * 60 * 1_000)) },
      }),
    ).toBeNull();
    expect(
      ThreadSettlementService.resolveAutoSettlementAt({
        ...input,
        thread: shell(),
        pullRequest: { state: "closed", closedAt: DateTime.formatIso(at(-1)) },
        autoSettleOnMerge: false,
      }),
    ).toEqual(shell().createdAt);
  });

  it("settles on merge after agent-started runs, but not after the user writes again", () => {
    const woken = shell({
      latestUserMessageAt: at(-30 * 60 * 1_000),
      latestUserAuthoredMessageAt: at(-2 * 60 * 60 * 1_000),
      latestRunRequestedAt: at(-30 * 60 * 1_000),
      latestRunCompletedAt: at(-29 * 60 * 1_000),
    });
    const input = {
      thread: woken,
      pullRequest: { state: "merged" as const, mergedAt: DateTime.formatIso(at(-60 * 60 * 1_000)) },
      nowMs: NOW_MS,
      autoSettleAfterDays: null,
      autoSettleOnMerge: true,
    };
    expect(ThreadSettlementService.resolveAutoSettlementAt(input)).toEqual(at(-29 * 60 * 1_000));
    expect(
      ThreadSettlementService.resolveAutoSettlementAt({
        ...input,
        thread: { ...woken, latestUserAuthoredMessageAt: at(-30 * 60 * 1_000) },
      }),
    ).toBeNull();
  });

  it("does not settle on pull requests that were already merged when linked", () => {
    const link = (number: number, linkedAt: DateTime.Utc, mergedAt: DateTime.Utc) => ({
      host: "example.test",
      repository: "owner/repository",
      number,
      url: `https://example.test/owner/repository/pull/${number}`,
      source: "agent" as const,
      linkedAt: DateTime.formatIso(linkedAt),
      snapshot: {
        state: "merged" as const,
        title: "Pull request",
        headBranch: `feature-${number}`,
        baseBranch: "main",
        isDraft: false,
        updatedAt: DateTime.formatIso(mergedAt),
        syncedAt: DateTime.formatIso(linkedAt),
        mergedAt: DateTime.formatIso(mergedAt),
      },
      stack: null,
    });
    const recorded = link(1, at(-50 * 60 * 1_000), at(-55 * 60 * 1_000));
    const input = {
      thread: shell({
        latestUserMessageAt: at(-2 * 60 * 60 * 1_000),
        latestRunCompletedAt: at(-45 * 60 * 1_000),
        pullRequests: [recorded],
      }),
      pullRequest: null,
      nowMs: NOW_MS,
      autoSettleAfterDays: null,
      autoSettleOnMerge: true,
    };
    expect(ThreadSettlementService.resolveAutoSettlementAt(input)).toBeNull();
    expect(
      ThreadSettlementService.resolveAutoSettlementAt({
        ...input,
        thread: {
          ...input.thread,
          pullRequests: [recorded, link(2, at(-90 * 60 * 1_000), at(-40 * 60 * 1_000))],
        },
      }),
    ).toEqual(at(-45 * 60 * 1_000));
  });

  it("settles on a merge an automated run made, but not on a pull request it closed", () => {
    const minutes = (count: number) => at(count * 60 * 1_000);
    const link = (number: number, state: "merged" | "closed", finishedAt: DateTime.Utc) => ({
      host: "example.test",
      repository: "owner/repository",
      number,
      url: `https://example.test/owner/repository/pull/${number}`,
      source: "agent" as const,
      linkedAt: DateTime.formatIso(minutes(-240)),
      snapshot: {
        state,
        title: "Pull request",
        headBranch: `feature-${number}`,
        baseBranch: "main",
        isDraft: false,
        updatedAt: DateTime.formatIso(finishedAt),
        syncedAt: DateTime.formatIso(finishedAt),
        ...(state === "merged"
          ? { mergedAt: DateTime.formatIso(finishedAt) }
          : { closedAt: DateTime.formatIso(finishedAt) }),
      },
      stack: null,
    });
    const settle = (pullRequests: ReadonlyArray<ReturnType<typeof link>>) =>
      ThreadSettlementService.resolveAutoSettlementAt({
        thread: shell({
          latestUserMessageAt: minutes(-120),
          latestRunStartedAt: minutes(-60),
          latestRunCompletedAt: minutes(-50),
          automatedRunWindows: [{ startedAt: minutes(-60), completedAt: minutes(-50) }],
          pullRequests,
        }),
        pullRequest: null,
        nowMs: NOW_MS,
        autoSettleAfterDays: null,
        autoSettleOnMerge: true,
      });

    // A background wake merges its work and then closes a diagnostic pull request: the merge decides.
    const diagnostic = link(2, "closed", minutes(-55));
    expect(settle([link(1, "merged", minutes(-58)), diagnostic])).toEqual(minutes(-50));
    expect(settle([link(1, "merged", minutes(-150)), diagnostic])).toBeNull();

    // The sweep's lookup of the thread's own reference returns the same closed pull request.
    const reference = {
      projectId: ProjectId.make("project-1"),
      repository: "owner/repository",
      number: 2,
      url: diagnostic.url,
    };
    for (const lookedUp of [{ linkedPullRequest: reference }, { branchPullRequest: reference }]) {
      expect(
        ThreadSettlementService.resolveAutoSettlementAt({
          thread: shell({
            latestUserMessageAt: minutes(-120),
            latestRunStartedAt: minutes(-60),
            latestRunCompletedAt: minutes(-50),
            automatedRunWindows: [{ startedAt: minutes(-60), completedAt: minutes(-50) }],
            pullRequests: [diagnostic],
            ...lookedUp,
          }),
          pullRequest: { state: "closed", closedAt: DateTime.formatIso(minutes(-55)) },
          nowMs: NOW_MS,
          autoSettleAfterDays: null,
          autoSettleOnMerge: true,
        }),
      ).toBeNull();
    }
  });
});

const NOW = "2026-08-28T12:00:00.000Z";
const PROJECT_ID = ProjectId.make("settlement-project");

describe("autoSettlementSettingsKey", () => {
  it("distinguishes a project that inherits the threshold from one that disables it", () => {
    const inherits = ThreadSettlementService.autoSettlementSettingsKey({
      ...DEFAULT_SERVER_SETTINGS,
      projectSettingsOverrides: { [PROJECT_ID]: { sidebarAutoSettleOnMerge: true } },
    });
    const never = ThreadSettlementService.autoSettlementSettingsKey({
      ...DEFAULT_SERVER_SETTINGS,
      projectSettingsOverrides: {
        [PROJECT_ID]: { sidebarAutoSettleOnMerge: true, sidebarAutoSettleAfterDays: null },
      },
    });
    assert.notStrictEqual(inherits, never);
  });
});

type AutoSettleCommand = Extract<OrchestrationV2Command, { readonly type: "thread.auto-settle" }>;

const testCrypto = SecureRandom.make((size) => new Uint8Array(size).fill(1));

function makeProject(
  id: ProjectId = PROJECT_ID,
  workspaceRoot = "/workspace/project",
): OrchestrationProjectShell {
  return {
    id,
    title: `Project ${id}`,
    workspaceRoot,
    defaultModelSelection: null,
    scripts: [],
    createdAt: "2026-08-01T00:00:00.000Z",
    updatedAt: NOW,
  };
}

function makeThread(id: string, overrides: Partial<SettlementShell> = {}): SettlementShell {
  return shell({
    id: ThreadId.make(id),
    projectId: PROJECT_ID,
    title: id,
    createdAt: DateTime.makeUnsafe("2026-08-01T00:00:00.000Z"),
    updatedAt: DateTime.makeUnsafe("2026-08-20T00:00:00.000Z"),
    latestUserMessageAt: DateTime.makeUnsafe("2026-08-20T00:00:00.000Z"),
    ...overrides,
  });
}

type SettlementSnapshot = Omit<OrchestrationV2ShellSnapshot, "threads"> & {
  readonly threads: ReadonlyArray<SettlementShell>;
};

function makeSnapshot(
  threads: ReadonlyArray<SettlementShell>,
  projects: ReadonlyArray<OrchestrationProjectShell> = [makeProject()],
): SettlementSnapshot {
  return {
    schemaVersion: 1,
    snapshotSequence: 1,
    projects,
    threads,
    archivedThreads: [],
  };
}

function makePullRequestSummary(input: {
  readonly projectId: ProjectId;
  readonly repository: string;
  readonly number: number;
  readonly state: "open" | "closed" | "merged";
  readonly updatedAt?: string;
}): PullRequestSummary {
  return {
    provider: SourceControlProviderKind.make("github"),
    projectId: input.projectId,
    repository: input.repository,
    number: input.number,
    title: "Pull request",
    url: `https://example.test/${input.repository}/pull/${input.number}`,
    state: input.state,
    headBranch: "feature",
    baseBranch: "main",
    updatedAt: input.updatedAt ?? NOW,
  };
}

function finishedLink(
  state: "closed" | "merged",
  linkedAt: string,
  finishedAt: string,
): NonNullable<SettlementShell["pullRequests"]>[number] {
  return {
    host: "example.test",
    repository: "owner/repository",
    number: 42,
    url: "https://example.test/owner/repository/pull/42",
    source: "agent",
    linkedAt,
    snapshot: {
      state,
      title: "Pull request",
      headBranch: "feature",
      baseBranch: "main",
      isDraft: false,
      updatedAt: finishedAt,
      syncedAt: finishedAt,
      ...(state === "merged" ? { mergedAt: finishedAt } : { closedAt: finishedAt }),
    },
    stack: null,
  };
}

function makeBranchPullRequest(state: "open" | "closed" | "merged") {
  return {
    number: 42,
    title: "Pull request",
    url: "https://example.test/owner/repository/pull/42",
    baseRef: "main",
    headRef: "feature",
    state,
    repositoryKey: "example.test/owner/repository",
    updatedAt: NOW,
    closedAt: state === "closed" ? NOW : null,
    mergedAt: state === "merged" ? NOW : null,
  } satisfies GitManager.GitBranchPullRequest;
}

function appThread(
  id: string,
  settledOverride: OrchestrationV2AppThread["settledOverride"] = null,
  worktreePath: string | null = null,
): OrchestrationV2AppThread {
  const threadId = ThreadId.make(id);
  return {
    createdBy: "user",
    creationSource: "web",
    id: threadId,
    projectId: PROJECT_ID,
    title: id,
    providerInstanceId: ProviderInstanceId.make("codex"),
    modelSelection: { instanceId: ProviderInstanceId.make("codex"), model: "gpt-5" },
    runtimeMode: "full-access",
    interactionMode: "default",
    branch: null,
    worktreePath,
    activeProviderThreadId: null,
    lineage: { parentThreadId: null, relationshipToParent: null, rootThreadId: threadId },
    forkedFrom: null,
    createdAt: DateTime.makeUnsafe(NOW),
    updatedAt: DateTime.makeUnsafe(NOW),
    archivedAt: null,
    settledOverride,
    settledAt: settledOverride === "settled" ? DateTime.makeUnsafe(NOW) : null,
    lastVisitedAt: null,
    deletedAt: null,
  };
}

/** The records the reply gate reads for a thread's latest run; no `run`, no run at all. */
function latestRunRecords(input: {
  readonly threadId: ThreadId;
  readonly run?: {
    readonly id: RunId;
    readonly status?: OrchestrationV2Run["status"];
    readonly request?: { readonly text: string; readonly by: "user" | "agent" | "scheduled" };
    readonly reply?: string;
    readonly stopped?: boolean;
  };
}): OrchestrationV2ThreadProjection {
  const at = DateTime.makeUnsafe(NOW);
  const projection = ProjectionStore.emptyProjection({
    type: "thread.created",
    id: EventId.make(`event:created:${input.threadId}`),
    threadId: input.threadId,
    occurredAt: at,
    payload: appThread(input.threadId),
  });
  const { run } = input;
  if (run === undefined) return projection;
  const userMessageId = MessageId.make(`message:request:${run.id}`);
  const message = (
    id: MessageId,
    role: "user" | "assistant",
    text: string,
    by: "user" | "agent" | "scheduled",
  ): OrchestrationV2ConversationMessage => ({
    createdBy: by === "agent" ? "agent" : "user",
    creationSource: by === "agent" ? "provider" : "web",
    ...(by === "scheduled" ? { scheduledTaskId: ScheduledTaskId.make("task:monitor") } : {}),
    id,
    threadId: input.threadId,
    runId: run.id,
    nodeId: null,
    role,
    text,
    attachments: [],
    streaming: false,
    createdAt: at,
    updatedAt: at,
  });
  return {
    ...projection,
    runs: [
      {
        id: run.id,
        threadId: input.threadId,
        ordinal: 1,
        providerInstanceId: ProviderInstanceId.make("codex"),
        modelSelection: { instanceId: ProviderInstanceId.make("codex"), model: "gpt-5" },
        providerThreadId: null,
        userMessageId,
        rootNodeId: null,
        activeAttemptId: null,
        status: run.status ?? "completed",
        requestedAt: at,
        startedAt: at,
        completedAt: at,
        checkpointId: null,
        contextHandoffId: null,
      },
    ],
    messages: [
      ...(run.request === undefined
        ? []
        : [message(userMessageId, "user", run.request.text, run.request.by)]),
      ...(run.reply === undefined
        ? []
        : [message(MessageId.make(`message:reply:${run.id}`), "assistant", run.reply, "agent")]),
    ],
    turnItems: run.stopped
      ? [
          {
            id: TurnItemId.make(`turn-item:stop:${run.id}`),
            threadId: input.threadId,
            runId: run.id,
            nodeId: null,
            providerThreadId: null,
            providerTurnId: null,
            nativeItemRef: null,
            parentItemId: null,
            ordinal: 1,
            status: "completed",
            title: "Interrupt requested",
            startedAt: at,
            completedAt: at,
            updatedAt: at,
            type: "run_interrupt_request",
            message: "Stopped by the user",
          },
        ]
      : [],
  };
}

// GitManager rereads git state on request, and by default whenever its
// remembered answer is merged or closed.
function readsFreshGitState(
  options: Parameters<GitManager.GitManager["Service"]["branchPullRequest"]>[1],
): boolean {
  return (
    options?.refresh === true ||
    options?.freshGitState === true ||
    options?.confirmTerminal !== false
  );
}

interface HarnessOptions {
  readonly snapshot: SettlementSnapshot;
  readonly settings?: ContractServerSettings;
  readonly branchPullRequest?: GitManager.GitManager["Service"]["branchPullRequest"];
  readonly pullRequestSummary?: PullRequestService.PullRequestService["Service"]["summary"];
  readonly existingWorktreePaths?: ReadonlyArray<string>;
  readonly unreadablePaths?: ReadonlyArray<string>;
  readonly onDispatch?: (command: AutoSettleCommand) => Effect.Effect<void>;
  readonly onScriptRun?: (
    input: ProjectSetupScriptRunner.ProjectSetupScriptRunnerInput,
  ) => Effect.Effect<void>;
  readonly onCloseIdle?: () => Effect.Effect<void>;
  readonly currentThreads?: ReadonlyArray<OrchestrationV2AppThread>;
  /** What the reply gate reads about each thread's latest run; see `latestRunRecords`. */
  readonly runRecords?: ReadonlyArray<OrchestrationV2ThreadProjection>;
  readonly checkSettlementReply?: TextGeneration.TextGeneration["Service"]["checkSettlementReply"];
  /** Whether notification triage calls a run news; unset, any triage read fails the test. */
  readonly shouldNotify?: CompletionNotificationTriage.CompletionNotificationTriage["Service"]["shouldNotify"];
  readonly projections?: ProjectionStore.ProjectionStoreV2Shape;
}

const makeHarness = Effect.fn("makeThreadSettlementHarness")(function* (options: HarnessOptions) {
  const activation = yield* Deferred.make<void>();
  const snapshots = yield* Ref.make(options.snapshot);
  const snapshotReadCount = yield* Ref.make(0);
  const snapshotReads = yield* Queue.unbounded<number>();
  const candidateReads = yield* Ref.make<ReadonlyArray<string | undefined>>([]);
  const settings = yield* Ref.make(options.settings ?? DEFAULT_SERVER_SETTINGS);
  const settingsReadCount = yield* Ref.make(0);
  const settingsChanges = yield* PubSub.unbounded<ContractServerSettings>();
  const mergedPullRequests = yield* PubSub.unbounded<PullRequestService.PullRequestMergeEvent>();
  const pullRequestRefreshes = yield* PubSub.unbounded<number>();
  const commands = yield* Ref.make<ReadonlyArray<AutoSettleCommand>>([]);
  const branchCalls = yield* Ref.make<
    ReadonlyArray<{ readonly cwd: string; readonly branch: string }>
  >([]);
  const summaryCalls = yield* Ref.make<
    ReadonlyArray<{
      readonly projectId: ProjectId;
      readonly repository: string;
      readonly number: number;
    }>
  >([]);
  const summaryRecovery = yield* Ref.make<ReadonlyArray<boolean | undefined>>([]);
  const invalidatedCwds = yield* Ref.make<ReadonlyArray<string>>([]);
  const domainEvents = yield* PubSub.unbounded<OrchestrationV2DomainEvent>();
  const observedEvents = yield* Queue.unbounded<EventId>();
  const closedIdle = yield* Queue.unbounded<{ readonly threadId: string }>();
  const scriptRuns =
    yield* Queue.unbounded<ProjectSetupScriptRunner.ProjectSetupScriptRunnerInput>();
  const runRecords = yield* Ref.make(options.runRecords ?? []);
  const replyChecks = yield* Ref.make<ReadonlyArray<SettlementReplyCheckInput>>([]);
  const triagedRuns = yield* Ref.make<ReadonlyArray<RunId>>([]);

  const updateSettings = (patch: ServerSettingsPatch) =>
    Effect.gen(function* () {
      const next = applyServerSettingsPatch(yield* Ref.get(settings), patch);
      yield* Ref.set(settings, next);
      yield* PubSub.publish(settingsChanges, next);
      return next;
    });

  const branchPullRequest: GitManager.GitManager["Service"]["branchPullRequest"] = (
    input,
    lookupOptions,
  ) =>
    Ref.update(branchCalls, (calls) => [...calls, input]).pipe(
      Effect.andThen(options.branchPullRequest?.(input, lookupOptions) ?? Effect.succeed(null)),
    );
  const pullRequestSummary: PullRequestService.PullRequestService["Service"]["summary"] = (
    input,
    readOptions,
  ) =>
    Effect.gen(function* () {
      yield* Ref.update(summaryCalls, (calls) => [...calls, input]);
      yield* Ref.update(summaryRecovery, (values) => [
        ...values,
        readOptions?.recoverTransientFailure,
      ]);
      return yield* (
        options.pullRequestSummary?.(input, readOptions) ??
          Effect.succeed(
            makePullRequestSummary({
              ...input,
              state: "open",
            }),
          )
      );
    });

  const dispatch: Orchestrator.OrchestratorV2Shape["dispatch"] = (command) => {
    if (command.type !== "thread.auto-settle") {
      return Effect.die(new Error(`Unexpected command: ${command.type}`));
    }
    return Ref.update(commands, (recorded) => [...recorded, command]).pipe(
      Effect.andThen(options.onDispatch?.(command) ?? Effect.void),
      Effect.as({ sequence: 1, storedEvents: [] }),
    );
  };

  const serverSettings = ServerSettings.ServerSettingsService.of({
    start: Effect.void,
    ready: Effect.void,
    getSettings: Ref.update(settingsReadCount, (count) => count + 1).pipe(
      Effect.andThen(Ref.get(settings)),
    ),
    updateSettings,
    updateProviderInstance: () => Effect.die("Unexpected provider mutation"),
    withSettingsSnapshot: (use) => Ref.get(settings).pipe(Effect.flatMap(use)),
    streamChanges: Stream.fromPubSub(settingsChanges),
    subscribeChanges: PubSub.subscribe(settingsChanges).pipe(
      Effect.map((subscription) => Stream.fromSubscription(subscription)),
    ),
  });

  const layerDependencies = Layer.mergeAll(
    Layer.mock(ProjectStore.ProjectStoreV2)({
      listShells: () => Ref.get(snapshots).pipe(Effect.map((snapshot) => snapshot.projects)),
    }),
    Layer.mock(ProjectionStore.ProjectionStoreV2)({
      ...options.projections,
      getSettlementCandidates: (threadId) =>
        Ref.update(candidateReads, (reads) => [...reads, threadId]).pipe(
          Effect.andThen(Ref.updateAndGet(snapshotReadCount, (count) => count + 1)),
          Effect.tap((count) => Queue.offer(snapshotReads, count)),
          Effect.andThen(
            options.projections?.getSettlementCandidates(threadId) ??
              Ref.get(snapshots).pipe(
                Effect.map((snapshot) =>
                  threadId === undefined
                    ? snapshot.threads
                    : snapshot.threads.filter((thread) => thread.id === threadId),
                ),
              ),
          ),
        ),
      getThread: (threadId) => {
        if (options.projections) return options.projections.getThread(threadId);
        const thread = options.currentThreads?.find((candidate) => candidate.id === threadId);
        return thread
          ? Effect.succeed(thread)
          : Effect.die(new Error(`Unexpected thread read: ${threadId}`));
      },
      getThreadRecords: (threadId) =>
        Ref.get(runRecords).pipe(
          Effect.map(
            (records) =>
              records.find((record) => record.thread.id === threadId) ??
              latestRunRecords({ threadId }),
          ),
        ),
    }),
    Layer.mock(TextGeneration.TextGeneration)({
      checkSettlementReply: (input) =>
        Ref.update(replyChecks, (checks) => [...checks, input]).pipe(
          Effect.andThen(
            options.checkSettlementReply?.(input) ??
              Effect.die(new Error("Unexpected settlement reply check")),
          ),
        ),
    }),
    Layer.mock(CompletionNotificationTriage.CompletionNotificationTriage)({
      shouldNotify: (input) =>
        Ref.update(triagedRuns, (runs) => [...runs, input.runId]).pipe(
          Effect.andThen(
            options.shouldNotify?.(input) ?? Effect.die(new Error("Unexpected completion triage")),
          ),
        ),
    }),
    Layer.mock(Orchestrator.OrchestratorV2)({
      streamDomainEvents: Stream.fromPubSub(domainEvents).pipe(
        Stream.tap((event) => Queue.offer(observedEvents, event.id)),
      ),
      dispatch,
    }),
    Layer.mock(TerminalManager.TerminalManager)({
      closeOnSettle: (input) =>
        Queue.offer(closedIdle, input).pipe(Effect.andThen(options.onCloseIdle?.() ?? Effect.void)),
    }),
    Layer.mock(ProjectSetupScriptRunner.ProjectSetupScriptRunner)({
      runForThread: (input) =>
        Queue.offer(scriptRuns, input).pipe(
          Effect.andThen(options.onScriptRun?.(input) ?? Effect.void),
          Effect.as({ status: "no-script" } as const),
        ),
    }),
    Layer.mock(GitManager.GitManager)({
      branchPullRequest,
      invalidateStatus: (cwd) => Ref.update(invalidatedCwds, (cwds) => [...cwds, cwd]),
    }),
    Layer.mock(PullRequestService.PullRequestService)({
      summary: pullRequestSummary,
      subscribeMerges: PubSub.subscribe(mergedPullRequests).pipe(
        Effect.map((subscription) => Stream.fromSubscription(subscription)),
      ),
      subscribeRefreshes: Stream.fromPubSub(pullRequestRefreshes),
    }),
    Layer.succeed(ServerSettings.ServerSettingsService, serverSettings),
    Layer.succeed(ServerActivation.ServerActivation, Deferred.await(activation)),
    Layer.succeed(SecureRandom.SecureRandom, testCrypto),
    FileSystem.layerNoop({
      exists: (path) =>
        options.unreadablePaths?.includes(path)
          ? Effect.fail(
              PlatformError.systemError({
                _tag: "PermissionDenied",
                module: "FileSystem",
                method: "exists",
                pathOrDescriptor: path,
              }),
            )
          : Effect.succeed(options.existingWorktreePaths?.includes(path) ?? false),
    }),
    Path.layer,
  );

  return {
    activation,
    settings,
    snapshots,
    snapshotReadCount,
    settingsReadCount,
    snapshotReads,
    candidateReads,
    commands,
    branchCalls,
    summaryCalls,
    summaryRecovery,
    invalidatedCwds,
    closedIdle,
    scriptRuns,
    runRecords,
    replyChecks,
    triagedRuns,
    observedEvents,
    publishEvent: (event: OrchestrationV2DomainEvent) => PubSub.publish(domainEvents, event),
    updateSettings,
    publishRefresh: PubSub.publish(pullRequestRefreshes, 1),
    publishMerge: PubSub.publish(mergedPullRequests, {
      projectId: PROJECT_ID,
      repository: "owner/repository",
      number: 42,
      mergedAt: NOW,
    }),
    layer: Layer.effect(
      ThreadSettlementService.ThreadSettlementServiceV2,
      ThreadSettlementService.make,
    ).pipe(
      Layer.provide(layerDependencies),
      Layer.provideMerge(SettlementDecisions.layer),
      Layer.provideMerge(NodeSqliteClient.layer({ filename: ":memory:" })),
    ),
  };
});

/** The settlement decision log, oldest first. */
const recordedDecisions = Effect.gen(function* () {
  const sql = yield* SqlClient.SqlClient;
  return yield* sql<{
    readonly thread_id: string;
    readonly outcome: string;
    readonly rule: string;
    readonly hold_reason: string | null;
    readonly run_id: string | null;
    readonly reply_check_json: string | null;
    readonly inputs_json: string;
    readonly server_version: string;
  }>`
    SELECT thread_id, outcome, rule, hold_reason, run_id, reply_check_json, inputs_json,
      server_version
    FROM settlement_decisions ORDER BY id
  `;
});

const startHarness = Effect.fn("startThreadSettlementHarness")(function* (
  reactor: ThreadSettlementService.ThreadSettlementServiceV2["Service"],
  activation: Deferred.Deferred<void>,
  snapshotReads: Queue.Queue<number>,
) {
  yield* reactor.start();
  yield* Deferred.succeed(activation, undefined);
  yield* Queue.take(snapshotReads);
  yield* reactor.drain;
});

const projectionStoreSql = ProjectionStore.layer.pipe(
  Layer.provideMerge(SqlitePersistence.layerMemory),
);

const settledEvent = (thread: OrchestrationV2AppThread): OrchestrationV2DomainEvent => ({
  type: "thread.settled",
  id: EventId.make(`event:settled:${thread.id}`),
  threadId: thread.id,
  occurredAt: DateTime.makeUnsafe(NOW),
  payload: thread,
});

describe("ThreadSettlementServiceV2 worker", () => {
  it.effect("skips settings and PR decisions for recent branchless threads", () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(Date.parse(NOW));
      const threads = Array.from({ length: 32 }, (_, index) =>
        makeThread(`recent-${index}`, {
          updatedAt: DateTime.makeUnsafe(NOW),
          latestUserMessageAt: DateTime.makeUnsafe(Date.parse(NOW) - 2 * DAY_MS),
        }),
      );
      const fixture = yield* makeHarness({
        snapshot: makeSnapshot(threads),
        settings: { ...DEFAULT_SERVER_SETTINGS, sidebarAutoSettleAfterDays: 3 },
      });
      yield* Effect.gen(function* () {
        const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
        yield* startHarness(service, fixture.activation, fixture.snapshotReads);
        assert.deepEqual(yield* Ref.get(fixture.commands), []);
        assert.deepEqual(yield* Ref.get(fixture.branchCalls), []);
        assert.equal(yield* Ref.get(fixture.settingsReadCount), 2);
        yield* fixture.updateSettings({ sidebarAutoSettleAfterDays: 1 });
        yield* Queue.take(fixture.snapshotReads);
        yield* service.drain;
        assert.deepEqual(
          new Set((yield* Ref.get(fixture.commands)).map((command) => command.threadId)),
          new Set(threads.map((thread) => thread.id)),
        );
      }).pipe(Effect.provide(fixture.layer));
    }),
  );
  it.effect("settles a merged pull request stored only in the thread links", () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(Date.parse(NOW));
      const thread = makeThread("merged-link", {
        pullRequests: [
          {
            host: "example.test",
            repository: "owner/repository",
            number: 42,
            url: "https://example.test/owner/repository/pull/42",
            source: "manual",
            linkedAt: "2026-08-20T00:00:00.000Z",
            snapshot: {
              state: "merged",
              title: "Pull request",
              headBranch: "feature",
              baseBranch: "main",
              isDraft: false,
              updatedAt: NOW,
              syncedAt: NOW,
              mergedAt: NOW,
            },
            stack: null,
          },
        ],
      });
      const fixture = yield* makeHarness({
        snapshot: makeSnapshot([thread]),
        settings: { ...DEFAULT_SERVER_SETTINGS, sidebarAutoSettleAfterDays: null },
      });

      yield* Effect.gen(function* () {
        const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
        yield* startHarness(service, fixture.activation, fixture.snapshotReads);
        expect((yield* Ref.get(fixture.commands)).map((command) => command.threadId)).toEqual([
          thread.id,
        ]);
      }).pipe(Effect.provide(fixture.layer));
    }),
  );

  it.effect("settles an idle thread with an open persisted link on the inactivity sweep", () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(Date.parse(NOW));
      const thread = makeThread("open-link", {
        pullRequests: [persistedLink("open", DateTime.makeUnsafe("2026-08-20T00:00:00.000Z"))],
      });
      const fixture = yield* makeHarness({
        snapshot: makeSnapshot([thread]),
        settings: {
          ...DEFAULT_SERVER_SETTINGS,
          sidebarAutoSettleAfterDays: 3,
          sidebarAutoSettleKeepPullRequests: false,
        },
      });
      yield* Effect.gen(function* () {
        const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
        yield* startHarness(service, fixture.activation, fixture.snapshotReads);
        expect((yield* Ref.get(fixture.commands)).map((command) => command.threadId)).toEqual([
          thread.id,
        ]);
      }).pipe(Effect.provide(fixture.layer));
    }),
  );

  it.effect("tells the orchestrator which rule settled each thread", () =>
    Effect.scoped(
      Effect.gen(function* () {
        yield* TestClock.setTime(Date.parse(NOW));
        // The thread's own agent closed a pull request it opened after the user's last message,
        // too recently for inactivity to settle it.
        const closed = makeThread("closed-pull-request", {
          latestUserMessageAt: DateTime.makeUnsafe("2026-08-28T10:00:00.000Z"),
          latestRunCompletedAt: DateTime.makeUnsafe("2026-08-28T11:00:00.000Z"),
          pullRequests: [
            finishedLink("closed", "2026-08-28T10:30:00.000Z", "2026-08-28T10:55:00.000Z"),
          ],
        });
        const merged = makeThread("merged-pull-request", {
          pullRequests: [finishedLink("merged", "2026-08-20T00:00:00.000Z", NOW)],
        });
        // Nothing linked: the sweep finds the merged pull request from the thread's branch.
        const onBranch = makeThread("branch-pull-request", {
          branch: "feature",
          latestUserMessageAt: DateTime.makeUnsafe("2026-08-28T10:00:00.000Z"),
        });
        const idle = makeThread("idle");
        // Its pull request merged, but the agent still waits on a watch, which holds it.
        const watched = makeThread("watched-pull-request", {
          pullRequests: [finishedLink("merged", "2026-08-20T00:00:00.000Z", NOW)],
          pendingBackgroundTasks: [
            {
              taskId: "pull-request-watch:example.test/owner/repository#42",
              description: "Watching pull request #42",
              kind: "monitor",
              awaited: true,
            },
          ],
        });
        const fixture = yield* makeHarness({
          snapshot: makeSnapshot([closed, merged, onBranch, idle, watched]),
          settings: {
            ...DEFAULT_SERVER_SETTINGS,
            sidebarAutoSettleAfterDays: 3,
            sidebarAutoSettleOnMerge: true,
          },
          branchPullRequest: () => Effect.succeed(makeBranchPullRequest("merged")),
        });
        yield* Effect.gen(function* () {
          const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
          yield* startHarness(service, fixture.activation, fixture.snapshotReads);
          const commands = yield* Ref.get(fixture.commands);
          expect(
            new Map(commands.map((command) => [command.threadId, command.settlementSource])),
          ).toEqual(
            new Map([
              [closed.id, "auto_pull_request_closed"],
              [merged.id, "auto_pull_request_merged"],
              [onBranch.id, "auto_branch_pull_request_merged"],
              [idle.id, "auto_inactivity"],
            ]),
          );
          // Each settle is logged with its rule, and so is the rule the watch is holding back.
          const decisions = yield* recordedDecisions;
          expect(
            new Map(
              decisions.map((row) => [row.thread_id, [row.outcome, row.rule, row.hold_reason]]),
            ),
          ).toEqual(
            new Map([
              [closed.id, ["settled", "auto_pull_request_closed", null]],
              [merged.id, ["settled", "auto_pull_request_merged", null]],
              [onBranch.id, ["settled", "auto_branch_pull_request_merged", null]],
              [idle.id, ["settled", "auto_inactivity", null]],
              [watched.id, ["held", "auto_pull_request_merged", "background_work"]],
            ]),
          );
          const watchedRow = decisions.find((row) => row.thread_id === watched.id);
          expect(JSON.parse(watchedRow?.inputs_json ?? "null")?.thread.id).toBe(watched.id);
          expect(decisions.every((row) => row.server_version !== "")).toBe(true);
        }).pipe(Effect.provide(fixture.layer));
      }),
    ),
  );

  it.effect("settles only the project opted in while environment settlement is disabled", () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(Date.parse(NOW));
      const thread = makeThread("project-opt-in", {
        latestRunCompletedAt: DateTime.makeUnsafe("2026-08-25T00:00:00.000Z"),
      });
      const other = makeThread("environment-off", { projectId: ProjectId.make("other-project") });
      const fixture = yield* makeHarness({
        snapshot: makeSnapshot([thread, other]),
        settings: {
          ...DEFAULT_SERVER_SETTINGS,
          sidebarAutoSettleAfterDays: null,
          sidebarAutoSettleOnMerge: false,
          projectSettingsOverrides: { [PROJECT_ID]: { sidebarAutoSettleAfterDays: 2 } },
        },
      });
      yield* Effect.gen(function* () {
        const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
        yield* startHarness(service, fixture.activation, fixture.snapshotReads);
        const commands = yield* Ref.get(fixture.commands);
        expect(commands.map((command) => command.threadId)).toEqual([thread.id]);
      }).pipe(Effect.provide(fixture.layer));
    }),
  );

  it.effect("stops settling the rest of a sweep once auto-settlement is turned off", () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(Date.parse(NOW));
      // Sweeps settle 8 threads at a time, so the ninth starts after a dispatch turned it off.
      const threads = Array.from({ length: 9 }, (_, index) => makeThread(`idle-${index}`));
      let disable: Effect.Effect<unknown> = Effect.void;
      const fixture = yield* makeHarness({
        snapshot: makeSnapshot(threads),
        settings: { ...DEFAULT_SERVER_SETTINGS, sidebarAutoSettleAfterDays: 3 },
        onDispatch: () => disable,
      });
      disable = fixture.updateSettings({ sidebarAutoSettleAfterDays: null });
      yield* Effect.gen(function* () {
        const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
        yield* startHarness(service, fixture.activation, fixture.snapshotReads);
        const settled = (yield* Ref.get(fixture.commands)).map((command) => command.threadId);
        expect(settled).not.toContain(threads[8]!.id);
      }).pipe(Effect.provide(fixture.layer));
    }),
  );

  it.effect(
    "drains idle subagents of a settled parent and retries busy children without PR lookups",
    () =>
      Effect.gen(function* () {
        yield* TestClock.setTime(Date.parse(NOW));
        const store = yield* ProjectionStore.ProjectionStoreV2;
        const parent = appThread("subagent-parent", "settled");
        const child = (id: string, overrides: Partial<OrchestrationV2AppThread> = {}) => ({
          ...appThread(id, null),
          branch: "feature",
          lineage: {
            rootThreadId: parent.id,
            parentThreadId: parent.id,
            relationshipToParent: "subagent" as const,
          },
          ...overrides,
        });
        const empty = child("empty");
        const recent = child("recent");
        const busy = child("busy");
        const marker = appThread("marker", "settled");
        for (const thread of [
          parent,
          empty,
          recent,
          busy,
          marker,
          child("pinned", { pinnedAt: DateTime.makeUnsafe(NOW) }),
          child("opted-out", { autoSettleDisabledAt: DateTime.makeUnsafe(NOW) }),
        ]) {
          yield* store.apply({
            type: "thread.created",
            id: EventId.make(`created:${thread.id}`),
            threadId: thread.id,
            occurredAt: thread.createdAt,
            payload: thread,
          });
        }
        const run = (threadId: ThreadId, status: "running" | "completed"): OrchestrationV2Run => ({
          id: RunId.make(`run:${threadId}`),
          threadId,
          ordinal: 1,
          providerInstanceId: parent.providerInstanceId,
          modelSelection: parent.modelSelection,
          providerThreadId: null,
          userMessageId: MessageId.make(`message:${threadId}`),
          rootNodeId: null,
          activeAttemptId: null,
          status,
          requestedAt: DateTime.makeUnsafe(NOW),
          startedAt: DateTime.makeUnsafe(NOW),
          completedAt: status === "completed" ? DateTime.makeUnsafe(NOW) : null,
          checkpointId: null,
          contextHandoffId: null,
        });
        for (const payload of [run(recent.id, "completed"), run(busy.id, "running")]) {
          yield* store.apply({
            type: "run.created",
            id: EventId.make(`created:${payload.id}`),
            threadId: payload.threadId,
            occurredAt: DateTime.makeUnsafe(NOW),
            payload,
          });
        }
        const fixture = yield* makeHarness({
          snapshot: makeSnapshot([]),
          projections: store,
          settings: { ...DEFAULT_SERVER_SETTINGS, sidebarAutoSettleAfterDays: 2 },
          onDispatch: (command) =>
            store.getThread(command.threadId).pipe(
              Effect.flatMap((thread) =>
                store.apply(
                  settledEvent({
                    ...thread,
                    settledOverride: "settled",
                    settledAt: DateTime.makeUnsafe(NOW),
                  }),
                ),
              ),
              Effect.orDie,
            ),
        });
        yield* Effect.gen(function* () {
          const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
          yield* startHarness(service, fixture.activation, fixture.snapshotReads);
          const commands = yield* Ref.get(fixture.commands);
          expect(commands.map((command) => command.threadId).toSorted()).toEqual([
            empty.id,
            recent.id,
          ]);
          for (const command of commands) {
            expect(command.snapshotAt).toEqual(DateTime.makeUnsafe(NOW));
            expect(command.settledAt).toBeUndefined();
          }
          const finished: OrchestrationV2DomainEvent = {
            type: "run.updated",
            id: EventId.make("busy:completed"),
            threadId: busy.id,
            occurredAt: DateTime.makeUnsafe(NOW),
            payload: run(busy.id, "completed"),
          };
          yield* store.apply(finished);
          yield* fixture.publishEvent(finished);
          // Cleanup of the following event marks delivery of the run event before draining.
          yield* fixture.publishEvent(settledEvent(marker));
          expect(yield* Queue.take(fixture.closedIdle)).toEqual({ threadId: marker.id });
          yield* service.drain;
          expect((yield* Ref.get(fixture.commands)).map((command) => command.threadId)).toEqual([
            empty.id,
            recent.id,
            busy.id,
          ]);
          expect(yield* Ref.get(fixture.branchCalls)).toEqual([]);
          expect(yield* Ref.get(fixture.summaryCalls)).toEqual([]);
        }).pipe(Effect.provide(fixture.layer));
      }).pipe(Effect.provide(projectionStoreSql)),
  );

  it.effect(
    "manual parent settlement drains hidden children with automatic settlement disabled",
    () =>
      Effect.gen(function* () {
        yield* TestClock.setTime(Date.parse(NOW));
        const store = yield* ProjectionStore.ProjectionStoreV2;
        const parent = appThread("manual-parent", null);
        const child = {
          ...appThread("manual-child", null),
          branch: "feature",
          lineage: {
            rootThreadId: parent.id,
            parentThreadId: parent.id,
            relationshipToParent: "subagent" as const,
          },
        };
        const marker = appThread("marker", "settled");
        for (const thread of [parent, child, marker]) {
          yield* store.apply({
            type: "thread.created",
            id: EventId.make(`created:${thread.id}`),
            threadId: thread.id,
            occurredAt: thread.createdAt,
            payload: thread,
          });
        }
        const fixture = yield* makeHarness({
          snapshot: makeSnapshot([]),
          projections: store,
          settings: { ...DEFAULT_SERVER_SETTINGS, sidebarAutoSettleAfterDays: 2 },
          onDispatch: (command) =>
            store.getThread(command.threadId).pipe(
              Effect.flatMap((thread) =>
                store.apply(
                  settledEvent({
                    ...thread,
                    settledOverride: "settled",
                    settledAt: DateTime.makeUnsafe(NOW),
                  }),
                ),
              ),
              Effect.orDie,
            ),
        });
        yield* Effect.gen(function* () {
          const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
          yield* startHarness(service, fixture.activation, fixture.snapshotReads);
          expect(yield* Ref.get(fixture.commands)).toEqual([]);
          expect(yield* Ref.get(fixture.branchCalls)).toEqual([]);
          // Avoid a settings-change sweep: the parent event must trigger the child dispatch.
          yield* Ref.set(fixture.settings, {
            ...DEFAULT_SERVER_SETTINGS,
            sidebarAutoSettleAfterDays: null,
            sidebarAutoSettleOnMerge: false,
          });
          const event = settledEvent({
            ...parent,
            settledOverride: "settled",
            settledAt: DateTime.makeUnsafe(NOW),
          });
          yield* store.apply(event);
          yield* fixture.publishEvent(event);
          yield* fixture.publishEvent(settledEvent(marker));
          expect(yield* Queue.take(fixture.closedIdle)).toEqual({ threadId: parent.id });
          expect(yield* Queue.take(fixture.closedIdle)).toEqual({ threadId: marker.id });
          yield* service.drain;
          expect(yield* Ref.get(fixture.commands)).toEqual([
            expect.objectContaining({
              type: "thread.auto-settle",
              threadId: child.id,
              snapshotAt: child.updatedAt,
            }),
          ]);
          expect(yield* Ref.get(fixture.branchCalls)).toEqual([]);
          expect(yield* Ref.get(fixture.summaryCalls)).toEqual([]);
        }).pipe(Effect.provide(fixture.layer));
      }).pipe(Effect.provide(projectionStoreSql)),
  );

  it.effect(
    "coalesces bulk cleanup wakes and still drains children discovered during a sweep",
    () =>
      Effect.gen(function* () {
        yield* TestClock.setTime(Date.parse(NOW));
        const store = yield* ProjectionStore.ProjectionStoreV2;
        const sweepStarted = yield* Deferred.make<void>();
        const releaseSweep = yield* Deferred.make<void>();
        const childSettled = yield* Deferred.make<void>();
        const parent = appThread("bulk-parent", null);
        const child = {
          ...appThread("bulk-child", null),
          lineage: {
            parentThreadId: parent.id,
            rootThreadId: parent.id,
            relationshipToParent: "subagent" as const,
          },
        };
        const marker = appThread("bulk-marker", "settled");
        const parents = [
          parent,
          ...Array.from({ length: 233 }, (_, i) => appThread(`bulk-parent-${i}`, null)),
        ];
        for (const thread of [...parents, child, marker]) {
          yield* store.apply({
            type: "thread.created",
            id: EventId.make(`created:${thread.id}`),
            threadId: thread.id,
            occurredAt: thread.createdAt,
            payload: thread,
          });
        }
        let blockNextSweep = false;
        const fixture = yield* makeHarness({
          snapshot: makeSnapshot([]),
          settings: {
            ...DEFAULT_SERVER_SETTINGS,
            sidebarAutoSettleAfterDays: null,
            sidebarAutoSettleOnMerge: false,
          },
          projections: {
            ...store,
            getSettlementCandidates: (threadId) =>
              Effect.gen(function* () {
                const candidates = yield* store.getSettlementCandidates(threadId);
                if (blockNextSweep) {
                  blockNextSweep = false;
                  yield* Deferred.succeed(sweepStarted, undefined);
                  yield* Deferred.await(releaseSweep);
                }
                return candidates;
              }),
          },
          onDispatch: (command): Effect.Effect<void> =>
            Effect.gen(function* () {
              const thread = yield* store.getThread(command.threadId);
              const event = settledEvent({
                ...thread,
                settledOverride: "settled",
                settledAt: DateTime.makeUnsafe(NOW),
              });
              yield* store.apply(event);
              yield* fixture.publishEvent(event);
              yield* Deferred.succeed(childSettled, undefined);
            }).pipe(Effect.orDie),
        });
        yield* Effect.gen(function* () {
          const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
          yield* startHarness(service, fixture.activation, fixture.snapshotReads);
          yield* Ref.set(fixture.candidateReads, []);
          blockNextSweep = true;
          yield* fixture.publishEvent(settledEvent(marker));
          yield* Deferred.await(sweepStarted);

          for (const [i, thread] of parents.entries()) {
            const type = (["thread.settled", "thread.archived", "thread.deleted"] as const)[i % 3]!;
            const event: OrchestrationV2DomainEvent = {
              type,
              id: EventId.make(`bulk:${thread.id}`),
              threadId: thread.id,
              occurredAt: DateTime.makeUnsafe(NOW),
              payload: {
                ...thread,
                ...(type === "thread.settled"
                  ? { settledOverride: "settled" as const, settledAt: DateTime.makeUnsafe(NOW) }
                  : type === "thread.archived"
                    ? { archivedAt: DateTime.makeUnsafe(NOW) }
                    : { deletedAt: DateTime.makeUnsafe(NOW) }),
              },
            };
            yield* store.apply(event);
            yield* fixture.publishEvent(event);
          }
          const markDelivery = (id: string) =>
            fixture
              .publishEvent({
                type: "thread.created",
                id: EventId.make(id),
                threadId: marker.id,
                occurredAt: marker.createdAt,
                payload: marker,
              })
              .pipe(
                // The next event is observed only after the previous handler has finished enqueueing.
                Effect.andThen(
                  Queue.take(fixture.observedEvents).pipe(
                    Effect.repeat({ until: (seen) => seen === id }),
                  ),
                ),
              );
          yield* markDelivery("bulk-delivered");
          yield* Deferred.succeed(releaseSweep, undefined);
          yield* Deferred.await(childSettled);
          yield* markDelivery("child-delivered");
          yield* service.drain;

          expect(yield* Ref.get(fixture.candidateReads)).toEqual([undefined, undefined, undefined]);
          expect((yield* Ref.get(fixture.commands)).map((command) => command.threadId)).toEqual([
            child.id,
          ]);
          expect((yield* store.getThread(child.id)).settledOverride).toBe("settled");
          expect(yield* Ref.get(fixture.branchCalls)).toEqual([]);
          expect(yield* Ref.get(fixture.summaryCalls)).toEqual([]);
        }).pipe(Effect.provide(fixture.layer));
      }).pipe(Effect.provide(projectionStoreSql)),
  );

  it.effect("looks up a branch in its worktree only while the worktree has .git", () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(Date.parse(NOW));
      const fixture = yield* makeHarness({
        snapshot: makeSnapshot([
          makeThread("linked-worktree", {
            branch: "linked",
            worktreePath: "/worktrees/linked",
            latestUserMessageAt: DateTime.makeUnsafe("2026-08-27T00:00:00.000Z"),
          }),
          // A folder that outlived its .git makes git fail with not_a_repository.
          makeThread("emptied-worktree", {
            branch: "emptied",
            worktreePath: "/worktrees/emptied",
            latestUserMessageAt: DateTime.makeUnsafe("2026-08-27T00:00:00.000Z"),
          }),
        ]),
        existingWorktreePaths: [
          "/worktrees/linked",
          "/worktrees/linked/.git",
          "/worktrees/emptied",
        ],
      });

      yield* Effect.gen(function* () {
        const reactor = yield* ThreadSettlementService.ThreadSettlementServiceV2;
        yield* startHarness(reactor, fixture.activation, fixture.snapshotReads);
        const cwdByBranch = Object.fromEntries(
          (yield* Ref.get(fixture.branchCalls)).map((call) => [call.branch, call.cwd]),
        );
        expect(cwdByBranch).toEqual({
          linked: "/worktrees/linked",
          emptied: "/workspace/project",
        });
      }).pipe(Effect.provide(fixture.layer));
    }),
  );

  it.effect("does not settle a thread whose worktree cannot be checked", () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(Date.parse(NOW));
      const fixture = yield* makeHarness({
        snapshot: makeSnapshot(
          [
            makeThread("unreadable-worktree", {
              branch: "unreadable",
              worktreePath: "/worktrees/unreadable",
              latestUserMessageAt: DateTime.makeUnsafe("2026-08-27T00:00:00.000Z"),
            }),
            // A merged linked pull request still needs the branch recheck before settling.
            makeThread("unreadable-linked-worktree", {
              branch: "feature",
              worktreePath: "/worktrees/unreadable-linked",
              latestUserMessageAt: DateTime.makeUnsafe("2026-08-27T00:00:00.000Z"),
              linkedPullRequest: {
                projectId: PROJECT_ID,
                repository: "owner/repository",
                number: 41,
                url: "https://example.test/owner/repository/pull/41",
              },
            }),
            makeThread("readable-worktree", {
              branch: "readable",
              worktreePath: "/worktrees/readable",
              latestUserMessageAt: DateTime.makeUnsafe("2026-08-27T00:00:00.000Z"),
            }),
          ],
          [
            {
              ...makeProject(),
              repositoryIdentity: {
                canonicalKey: "example.test/owner/repository",
                locator: {
                  source: "git-remote",
                  remoteName: "origin",
                  remoteUrl: "https://example.test/owner/repository.git",
                },
                provider: SourceControlProviderKind.make("github"),
                owner: "owner",
                name: "repository",
              },
            },
          ],
        ),
        existingWorktreePaths: ["/worktrees/readable", "/worktrees/readable/.git"],
        unreadablePaths: ["/worktrees/unreadable/.git", "/worktrees/unreadable-linked/.git"],
        pullRequestSummary: (input) =>
          Effect.succeed({
            ...makePullRequestSummary({ ...input, state: "merged" }),
            mergedAt: NOW,
          }),
        branchPullRequest: (input) =>
          input.cwd.startsWith("/worktrees/unreadable")
            ? Effect.die(new Error("git: permission denied"))
            : Effect.succeed(makeBranchPullRequest("merged")),
      });

      yield* Effect.gen(function* () {
        const reactor = yield* ThreadSettlementService.ThreadSettlementServiceV2;
        yield* startHarness(reactor, fixture.activation, fixture.snapshotReads);
        expect((yield* Ref.get(fixture.commands)).map((command) => command.threadId)).toEqual([
          ThreadId.make("readable-worktree"),
        ]);
      }).pipe(Effect.provide(fixture.layer));
    }),
  );

  it.effect("reevaluates immediately after a pull request merge", () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(Date.parse(NOW));
      const periodicLookupStarted = yield* Deferred.make<void>();
      const releasePeriodicLookup = yield* Deferred.make<void>();
      const mergedThreadSettled = yield* Deferred.make<void>();
      const branchLookupCount = yield* Ref.make(0);
      const fixture = yield* makeHarness({
        snapshot: makeSnapshot([
          makeThread("merged-in-app", {
            latestUserMessageAt: DateTime.makeUnsafe("2026-08-27T00:00:00.000Z"),
            linkedPullRequest: {
              projectId: PROJECT_ID,
              repository: "Owner/Repository",
              number: 42,
              url: "https://example.test/owner/repository/pull/42",
            },
          }),
          makeThread("slow-periodic-lookup", {
            branch: "another-feature",
            latestUserMessageAt: DateTime.makeUnsafe("2026-08-27T00:00:00.000Z"),
          }),
        ]),
        branchPullRequest: () =>
          Ref.updateAndGet(branchLookupCount, (count) => count + 1).pipe(
            Effect.flatMap((count) =>
              count === 1
                ? Effect.succeed(makeBranchPullRequest("open"))
                : Deferred.succeed(periodicLookupStarted, undefined).pipe(
                    Effect.andThen(Deferred.await(releasePeriodicLookup)),
                    Effect.as(makeBranchPullRequest("open")),
                  ),
            ),
          ),
        onDispatch: () => Deferred.succeed(mergedThreadSettled, undefined),
      });

      yield* Effect.gen(function* () {
        const reactor = yield* ThreadSettlementService.ThreadSettlementServiceV2;
        yield* startHarness(reactor, fixture.activation, fixture.snapshotReads);
        yield* fixture.updateSettings({ sidebarAutoSettleAfterDays: 4 });
        yield* Deferred.await(periodicLookupStarted);

        yield* fixture.publishMerge;
        yield* Deferred.await(mergedThreadSettled);

        assert.deepStrictEqual(
          (yield* Ref.get(fixture.commands)).map((command) => command.threadId),
          [ThreadId.make("merged-in-app")],
        );
        yield* Deferred.succeed(releasePeriodicLookup, undefined);
        yield* reactor.drain;
      }).pipe(Effect.provide(fixture.layer));
    }),
  );

  it.effect("settles a merged thread when its background work ends, during a slow full sweep", () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(Date.parse(NOW));
      const periodicLookupStarted = yield* Deferred.make<void>();
      const releasePeriodicLookup = yield* Deferred.make<void>();
      const settled = yield* Deferred.make<void>();
      const branchLookupCount = yield* Ref.make(0);
      const mergedLink: NonNullable<SettlementShell["pullRequests"]>[number] = {
        ...persistedLink("open", DateTime.makeUnsafe("2026-08-20T00:00:00.000Z")),
        snapshot: {
          state: "merged",
          title: "Pull request",
          headBranch: "feature",
          baseBranch: "main",
          isDraft: false,
          updatedAt: NOW,
          syncedAt: NOW,
          mergedAt: NOW,
        },
      };
      const waiting = makeThread("waiting-on-subagent", {
        pullRequests: [mergedLink],
        pendingBackgroundTasks: [{ taskId: "child", kind: "subagent", description: "Review" }],
      });
      const slow = makeThread("slow-periodic-lookup", {
        branch: "another-feature",
        latestUserMessageAt: DateTime.makeUnsafe("2026-08-27T00:00:00.000Z"),
      });
      const fixture = yield* makeHarness({
        snapshot: makeSnapshot([waiting, slow]),
        branchPullRequest: () =>
          Ref.updateAndGet(branchLookupCount, (count) => count + 1).pipe(
            Effect.flatMap((count) =>
              count === 1
                ? Effect.succeed(makeBranchPullRequest("open"))
                : Deferred.succeed(periodicLookupStarted, undefined).pipe(
                    Effect.andThen(Deferred.await(releasePeriodicLookup)),
                    Effect.as(makeBranchPullRequest("open")),
                  ),
            ),
          ),
        onDispatch: () => Deferred.succeed(settled, undefined),
      });

      yield* Effect.gen(function* () {
        const reactor = yield* ThreadSettlementService.ThreadSettlementServiceV2;
        yield* startHarness(reactor, fixture.activation, fixture.snapshotReads);
        assert.deepStrictEqual(yield* Ref.get(fixture.commands), []);
        yield* fixture.updateSettings({ sidebarAutoSettleAfterDays: 4 });
        yield* Deferred.await(periodicLookupStarted);

        yield* Ref.set(
          fixture.snapshots,
          makeSnapshot([{ ...waiting, pendingBackgroundTasks: [] }, slow]),
        );
        yield* fixture.publishEvent({
          type: "run.background-work-cancelled",
          id: EventId.make("event:background-ended"),
          threadId: waiting.id,
          occurredAt: DateTime.makeUnsafe(NOW),
          payload: { runId: RunId.make("run:waiting"), restartCancelledBackgroundWork: [] },
        });
        yield* Deferred.await(settled);

        assert.deepStrictEqual(
          (yield* Ref.get(fixture.commands)).map((command) => command.threadId),
          [waiting.id],
        );
        yield* Deferred.succeed(releasePeriodicLookup, undefined);
        yield* reactor.drain;
      }).pipe(Effect.provide(fixture.layer));
    }),
  );

  it.effect("settles a stopped thread while another thread's lookup is slow", () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(Date.parse(NOW));
      const slowLookupStarted = yield* Deferred.make<void>();
      const releaseSlowLookup = yield* Deferred.make<void>();
      const settled = yield* Deferred.make<void>();
      const branchLookupCount = yield* Ref.make(0);
      const recent = DateTime.makeUnsafe("2026-08-27T00:00:00.000Z");
      const slow = makeThread("slow-lookup", { branch: "feature", latestUserMessageAt: recent });
      const merged = makeThread("merged", {
        latestUserMessageAt: recent,
        pullRequests: [
          {
            ...persistedLink("open", recent),
            snapshot: {
              state: "merged",
              title: "Pull request",
              headBranch: "feature",
              baseBranch: "main",
              isDraft: false,
              updatedAt: NOW,
              syncedAt: NOW,
              mergedAt: NOW,
            },
          },
        ],
        pendingBackgroundTasks: [{ taskId: "child", kind: "subagent", description: "Review" }],
      });
      const fixture = yield* makeHarness({
        snapshot: makeSnapshot([slow, merged]),
        branchPullRequest: () =>
          Ref.updateAndGet(branchLookupCount, (count) => count + 1).pipe(
            Effect.flatMap((count) =>
              count === 1
                ? Effect.succeed(makeBranchPullRequest("open"))
                : Deferred.succeed(slowLookupStarted, undefined).pipe(
                    Effect.andThen(Deferred.await(releaseSlowLookup)),
                    Effect.as(makeBranchPullRequest("open")),
                  ),
            ),
          ),
        onDispatch: () => Deferred.succeed(settled, undefined),
      });
      const backgroundEnded = (threadId: ThreadId): OrchestrationV2DomainEvent => ({
        type: "run.background-work-cancelled",
        id: EventId.make(`event:background-ended:${threadId}`),
        threadId,
        occurredAt: DateTime.makeUnsafe(NOW),
        payload: { runId: RunId.make(`run:${threadId}`), restartCancelledBackgroundWork: [] },
      });

      yield* Effect.gen(function* () {
        const reactor = yield* ThreadSettlementService.ThreadSettlementServiceV2;
        yield* startHarness(reactor, fixture.activation, fixture.snapshotReads);
        yield* fixture.publishEvent(backgroundEnded(slow.id));
        yield* Deferred.await(slowLookupStarted);
        // More events for the slow thread coalesce into one more pass, not more sweeps.
        for (let index = 0; index < 9; index++) {
          yield* fixture.publishEvent(backgroundEnded(slow.id));
        }

        yield* Ref.set(
          fixture.snapshots,
          makeSnapshot([slow, { ...merged, pendingBackgroundTasks: [] }]),
        );
        yield* fixture.publishEvent(backgroundEnded(merged.id));
        yield* Deferred.await(settled);

        assert.deepStrictEqual(
          (yield* Ref.get(fixture.commands)).map((command) => command.threadId),
          [merged.id],
        );
        yield* Deferred.succeed(releaseSlowLookup, undefined);
        yield* reactor.drain;
        // The startup sweep, the first per-thread sweep, and one coalesced rerun.
        assert.strictEqual(yield* Ref.get(branchLookupCount), 3);
      }).pipe(Effect.provide(fixture.layer));
    }),
  );

  it.effect.each([
    { kind: "an unlinked", linked: false },
    { kind: "a quiet linked", linked: true },
  ])("settles $kind branch thread its agent merged from a shell, past the cache", ({ linked }) =>
    Effect.gen(function* () {
      yield* TestClock.setTime(Date.parse(NOW));
      const thread = makeThread("shell-merged", {
        branch: "saved-feature",
        latestUserMessageAt: DateTime.makeUnsafe("2026-08-27T00:00:00.000Z"),
        ...(linked
          ? {
              branchPullRequest: {
                projectId: PROJECT_ID,
                repository: "owner/repository",
                number: 42,
                url: "https://example.test/owner/repository/pull/42",
              },
            }
          : {}),
      });
      const fixture = yield* makeHarness({
        snapshot: makeSnapshot([thread]),
        // The host already merged it; only a fresh read sees that past the cached open lookup.
        branchPullRequest: (_input, lookupOptions) =>
          Effect.succeed(makeBranchPullRequest(lookupOptions?.refresh ? "merged" : "open")),
        pullRequestSummary: (input, readOptions) =>
          Effect.succeed({
            ...makePullRequestSummary({
              ...input,
              state: readOptions?.bypassCache ? "merged" : "open",
              updatedAt: DateTime.formatIso(DateTime.makeUnsafe(Date.parse(NOW) - 2 * DAY_MS)),
            }),
            ...(readOptions?.bypassCache ? { mergedAt: NOW } : {}),
          }),
      });
      const at = DateTime.makeUnsafe(NOW);
      const runId = RunId.make("run:shell-merged");
      const runEnded: OrchestrationV2DomainEvent = {
        type: "run.background-work-cancelled",
        id: EventId.make("event:shell-merged:run-ended"),
        threadId: thread.id,
        occurredAt: at,
        payload: { runId, restartCancelledBackgroundWork: [] },
      };

      yield* Effect.gen(function* () {
        const reactor = yield* ThreadSettlementService.ThreadSettlementServiceV2;
        yield* startHarness(reactor, fixture.activation, fixture.snapshotReads);
        yield* fixture.publishEvent(runEnded);
        yield* Queue.take(fixture.snapshotReads);
        yield* reactor.drain;
        assert.deepStrictEqual(yield* Ref.get(fixture.commands), []);

        yield* fixture.publishEvent({
          type: "turn-item.updated",
          id: EventId.make("event:shell-merged:command"),
          threadId: thread.id,
          runId,
          occurredAt: at,
          payload: {
            id: TurnItemId.make("item:shell-merged:command"),
            threadId: thread.id,
            runId,
            nodeId: null,
            providerThreadId: null,
            providerTurnId: null,
            nativeItemRef: null,
            parentItemId: null,
            ordinal: 1,
            status: "completed",
            title: null,
            startedAt: at,
            completedAt: at,
            updatedAt: at,
            type: "command_execution",
            input: "gh pr merge 42 --squash",
          },
        });
        yield* Queue.take(fixture.snapshotReads);
        yield* reactor.drain;
        assert.deepStrictEqual(
          (yield* Ref.get(fixture.commands)).map((command) => command.threadId),
          [thread.id],
        );
      }).pipe(Effect.provide(fixture.layer));
    }),
  );

  it.effect(
    "settles branch threads on a pull request merge without waiting for the next sweep",
    () =>
      Effect.gen(function* () {
        yield* TestClock.setTime(Date.parse(NOW));
        const state = yield* Ref.make<"open" | "merged">("open");
        const mergedThreadSettled = yield* Deferred.make<void>();
        const fixture = yield* makeHarness({
          snapshot: makeSnapshot([
            makeThread("branch-thread", {
              branch: "saved-feature",
              latestUserMessageAt: DateTime.makeUnsafe("2026-08-27T00:00:00.000Z"),
            }),
          ]),
          branchPullRequest: () => Ref.get(state).pipe(Effect.map(makeBranchPullRequest)),
          onDispatch: () => Deferred.succeed(mergedThreadSettled, undefined),
        });

        yield* Effect.gen(function* () {
          const reactor = yield* ThreadSettlementService.ThreadSettlementServiceV2;
          yield* startHarness(reactor, fixture.activation, fixture.snapshotReads);
          assert.deepStrictEqual(yield* Ref.get(fixture.commands), []);
          assert.deepStrictEqual(yield* Ref.get(fixture.invalidatedCwds), []);

          yield* Ref.set(state, "merged");
          yield* fixture.publishMerge;
          yield* Deferred.await(mergedThreadSettled);

          assert.deepStrictEqual(
            (yield* Ref.get(fixture.commands)).map((command) => command.threadId),
            [ThreadId.make("branch-thread")],
          );
          assert.deepStrictEqual(yield* Ref.get(fixture.invalidatedCwds), ["/workspace/project"]);
          yield* reactor.drain;
        }).pipe(Effect.provide(fixture.layer));
      }),
  );

  it.effect("reads a quiet open branch pull request every 5 minutes", () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(Date.parse(NOW));
      const fixture = yield* makeHarness({
        snapshot: makeSnapshot([
          makeThread("active-branch", {
            branch: "feature",
            latestUserMessageAt: DateTime.makeUnsafe("2026-08-27T00:00:00.000Z"),
            branchPullRequest: {
              projectId: PROJECT_ID,
              repository: "owner/repository",
              number: 42,
              url: "https://example.test/owner/repository/pull/42",
            },
          }),
        ]),
        pullRequestSummary: (input) =>
          Effect.succeed(
            makePullRequestSummary({
              ...input,
              state: "open",
              updatedAt: DateTime.formatIso(DateTime.makeUnsafe(Date.parse(NOW) - 2 * DAY_MS)),
            }),
          ),
      });

      yield* Effect.gen(function* () {
        const reactor = yield* ThreadSettlementService.ThreadSettlementServiceV2;
        yield* startHarness(reactor, fixture.activation, fixture.snapshotReads);
        assert.strictEqual((yield* Ref.get(fixture.summaryCalls)).length, 1);

        for (let minute = 0; minute < 4; minute++) {
          yield* TestClock.adjust("1 minute");
          yield* Queue.take(fixture.snapshotReads);
          yield* reactor.drain;
        }
        assert.strictEqual((yield* Ref.get(fixture.summaryCalls)).length, 1);

        yield* TestClock.adjust("1 minute");
        yield* Queue.take(fixture.snapshotReads);
        yield* reactor.drain;
        assert.strictEqual((yield* Ref.get(fixture.summaryCalls)).length, 2);

        // An app merge the host completes later sends only a refresh; reads stay on the minute
        // cadence while the pull request still reads open.
        yield* fixture.publishRefresh;
        for (const expected of [3, 4]) {
          yield* TestClock.adjust("1 minute");
          yield* Queue.take(fixture.snapshotReads);
          yield* reactor.drain;
          assert.strictEqual((yield* Ref.get(fixture.summaryCalls)).length, expected);
        }
      }).pipe(Effect.provide(fixture.layer));
    }),
  );

  it.effect.each([
    { when: "after", mergeDuringRead: false },
    { when: "during", mergeDuringRead: true },
  ])(
    "a merge $when a quiet pull request's read, while its thread is not a candidate, rereads it next sweep",
    ({ mergeDuringRead }) =>
      Effect.gen(function* () {
        yield* TestClock.setTime(Date.parse(NOW));
        const thread = makeThread("busy-branch", {
          branch: "feature",
          latestUserMessageAt: DateTime.makeUnsafe("2026-08-27T00:00:00.000Z"),
          branchPullRequest: {
            projectId: PROJECT_ID,
            repository: "owner/repository",
            number: 42,
            url: "https://example.test/owner/repository/pull/42",
          },
        });
        const readStarted = yield* Deferred.make<void>();
        const releaseRead = yield* Deferred.make<void>();
        if (!mergeDuringRead) yield* Deferred.succeed(releaseRead, undefined);
        const fixture = yield* makeHarness({
          snapshot: makeSnapshot([thread]),
          pullRequestSummary: (input) =>
            Deferred.succeed(readStarted, undefined).pipe(
              Effect.andThen(Deferred.await(releaseRead)),
              Effect.as(
                makePullRequestSummary({
                  ...input,
                  state: "open",
                  updatedAt: DateTime.formatIso(DateTime.makeUnsafe(Date.parse(NOW) - 2 * DAY_MS)),
                }),
              ),
            ),
        });

        yield* Effect.gen(function* () {
          const reactor = yield* ThreadSettlementService.ThreadSettlementServiceV2;
          yield* reactor.start();
          yield* Deferred.succeed(fixture.activation, undefined);
          yield* Queue.take(fixture.snapshotReads);
          yield* Deferred.await(readStarted);
          if (!mergeDuringRead) yield* reactor.drain;
          assert.strictEqual((yield* Ref.get(fixture.summaryCalls)).length, 1);

          yield* Ref.set(fixture.snapshots, makeSnapshot([]));
          yield* fixture.publishMerge;
          yield* Queue.take(fixture.snapshotReads);
          yield* Deferred.succeed(releaseRead, undefined);
          yield* reactor.drain;

          yield* Ref.set(fixture.snapshots, makeSnapshot([thread]));
          yield* TestClock.adjust("1 minute");
          yield* Queue.take(fixture.snapshotReads);
          yield* reactor.drain;
          assert.strictEqual((yield* Ref.get(fixture.summaryCalls)).length, 2);
        }).pipe(Effect.provide(fixture.layer));
      }),
  );

  it.effect("rereads a branch without a pull request less often the longer its thread idles", () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(Date.parse(NOW));
      const recent = makeThread("recent-branch", {
        branch: "recent-feature",
        latestUserMessageAt: DateTime.makeUnsafe(Date.parse(NOW) - 30 * 60 * 1_000),
      });
      const old = makeThread("old-branch", {
        branch: "old-feature",
        latestUserMessageAt: DateTime.makeUnsafe(Date.parse(NOW) - 2 * DAY_MS),
      });
      const fixture = yield* makeHarness({ snapshot: makeSnapshot([recent, old]) });
      const branches = Ref.get(fixture.branchCalls).pipe(
        Effect.map((calls) => calls.map((call) => call.branch).sort()),
      );

      yield* Effect.gen(function* () {
        const reactor = yield* ThreadSettlementService.ThreadSettlementServiceV2;
        yield* startHarness(reactor, fixture.activation, fixture.snapshotReads);
        for (let minute = 1; minute <= 29; minute += 1) {
          yield* TestClock.adjust("1 minute");
          yield* Queue.take(fixture.snapshotReads);
          yield* reactor.drain;
        }
        assert.deepStrictEqual(yield* branches, ["old-feature", "recent-feature"]);

        yield* TestClock.adjust("1 minute");
        yield* Queue.take(fixture.snapshotReads);
        yield* reactor.drain;
        assert.deepStrictEqual(yield* branches, [
          "old-feature",
          "recent-feature",
          "recent-feature",
        ]);

        // Work ending in the thread reads its branch at once.
        yield* fixture.publishEvent({
          type: "run.background-work-cancelled",
          id: EventId.make("event:old-branch:run-ended"),
          threadId: old.id,
          occurredAt: DateTime.makeUnsafe(NOW),
          payload: { runId: RunId.make("run:old-branch"), restartCancelledBackgroundWork: [] },
        });
        yield* Queue.take(fixture.snapshotReads);
        yield* reactor.drain;
        assert.deepStrictEqual(yield* branches, [
          "old-feature",
          "old-feature",
          "recent-feature",
          "recent-feature",
        ]);
      }).pipe(Effect.provide(fixture.layer));
    }),
  );

  it.effect("a sweep looks up a few branches without a pull request, not every one", () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(Date.parse(NOW));
      const threads = Array.from({ length: 10 }, (_, index) =>
        makeThread(`idle-${index}`, {
          branch: `idle-${index}`,
          latestUserMessageAt: DateTime.makeUnsafe(Date.parse(NOW) - (index + 10) * 60 * 1_000),
        }),
      );
      const fixture = yield* makeHarness({ snapshot: makeSnapshot(threads) });
      const branches = Ref.get(fixture.branchCalls).pipe(
        Effect.map((calls) => calls.map((call) => call.branch).sort()),
      );

      yield* Effect.gen(function* () {
        const reactor = yield* ThreadSettlementService.ThreadSettlementServiceV2;
        yield* startHarness(reactor, fixture.activation, fixture.snapshotReads);
        // The most recently active first, then the rest in turn, each once.
        assert.deepStrictEqual(yield* branches, ["idle-0", "idle-1", "idle-2", "idle-3"]);
        for (let minute = 1; minute <= 5; minute += 1) {
          yield* TestClock.adjust("1 minute");
          yield* Queue.take(fixture.snapshotReads);
          yield* reactor.drain;
        }
        assert.deepStrictEqual(
          yield* branches,
          threads.map((thread) => thread.branch),
        );
      }).pipe(Effect.provide(fixture.layer));
    }),
  );

  it.effect("a merged branch PR that cannot settle its thread rereads no git state", () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(Date.parse(NOW));
      const freshReads = yield* Ref.make(0);
      const fixture = yield* makeHarness({
        snapshot: makeSnapshot([
          makeThread("worked-after-merge", {
            branch: "merged-feature",
            latestUserAuthoredMessageAt: DateTime.makeUnsafe("2026-08-28T06:00:00.000Z"),
          }),
        ]),
        settings: { ...DEFAULT_SERVER_SETTINGS, sidebarAutoSettleAfterDays: null },
        branchPullRequest: (_input, lookupOptions) =>
          Ref.update(
            freshReads,
            (count) => count + (readsFreshGitState(lookupOptions) ? 1 : 0),
          ).pipe(
            Effect.as({
              ...makeBranchPullRequest("merged"),
              mergedAt: "2026-08-27T00:00:00.000Z",
            }),
          ),
      });

      yield* Effect.gen(function* () {
        const reactor = yield* ThreadSettlementService.ThreadSettlementServiceV2;
        yield* startHarness(reactor, fixture.activation, fixture.snapshotReads);
        yield* TestClock.adjust("1 minute");
        yield* Queue.take(fixture.snapshotReads);
        yield* reactor.drain;

        assert.strictEqual((yield* Ref.get(fixture.branchCalls)).length, 2);
        assert.strictEqual(yield* Ref.get(freshReads), 0);
        assert.deepStrictEqual(yield* Ref.get(fixture.commands), []);
      }).pipe(Effect.provide(fixture.layer));
    }),
  );

  it.effect("a remembered merged branch PR settles only after fresh git state agrees", () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(Date.parse(NOW));
      const freshState = yield* Ref.make<"open" | "merged">("open");
      const fixture = yield* makeHarness({
        snapshot: makeSnapshot([makeThread("merged-branch", { branch: "merged-feature" })]),
        settings: { ...DEFAULT_SERVER_SETTINGS, sidebarAutoSettleAfterDays: null },
        branchPullRequest: (_input, lookupOptions) =>
          readsFreshGitState(lookupOptions)
            ? Ref.get(freshState).pipe(Effect.map(makeBranchPullRequest))
            : Effect.succeed(makeBranchPullRequest("merged")),
      });

      yield* Effect.gen(function* () {
        const reactor = yield* ThreadSettlementService.ThreadSettlementServiceV2;
        yield* startHarness(reactor, fixture.activation, fixture.snapshotReads);
        assert.deepStrictEqual(yield* Ref.get(fixture.commands), []);

        yield* Ref.set(freshState, "merged");
        yield* TestClock.adjust("1 minute");
        yield* Queue.take(fixture.snapshotReads);
        yield* reactor.drain;

        assert.deepStrictEqual(
          (yield* Ref.get(fixture.commands)).map((command) => command.threadId),
          [ThreadId.make("merged-branch")],
        );
      }).pipe(Effect.provide(fixture.layer));
    }),
  );

  it.effect("a merge does not settle threads linked to an unrelated pull request", () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(Date.parse(NOW));
      const mergedThreadSettled = yield* Deferred.make<void>();
      const mergeLookupStarted = yield* Deferred.make<void>();
      const releaseMergeLookup = yield* Deferred.make<void>();
      const lookupCount = yield* Ref.make(0);
      const fixture = yield* makeHarness({
        snapshot: makeSnapshot([
          makeThread("merged-in-app", {
            latestUserMessageAt: DateTime.makeUnsafe("2026-08-27T00:00:00.000Z"),
            linkedPullRequest: {
              projectId: PROJECT_ID,
              repository: "owner/repository",
              number: 42,
              url: "https://example.test/owner/repository/pull/42",
            },
          }),
          makeThread("unrelated-linked", {
            latestUserMessageAt: DateTime.makeUnsafe("2026-08-27T00:00:00.000Z"),
            linkedPullRequest: {
              projectId: PROJECT_ID,
              repository: "owner/repository",
              number: 99,
              url: "https://example.test/owner/repository/pull/99",
            },
          }),
        ]),
        pullRequestSummary: (input) =>
          Ref.updateAndGet(lookupCount, (count) => count + 1).pipe(
            Effect.tap((count) =>
              count === 3 ? Deferred.succeed(mergeLookupStarted, undefined) : Effect.void,
            ),
            Effect.tap((count) => (count === 3 ? Deferred.await(releaseMergeLookup) : Effect.void)),
            Effect.map(() => makePullRequestSummary({ ...input, state: "open" })),
          ),
        onDispatch: () => Deferred.succeed(mergedThreadSettled, undefined),
      });

      yield* Effect.gen(function* () {
        const reactor = yield* ThreadSettlementService.ThreadSettlementServiceV2;
        yield* startHarness(reactor, fixture.activation, fixture.snapshotReads);
        assert.deepStrictEqual(yield* Ref.get(fixture.commands), []);

        yield* fixture.publishMerge;
        yield* Deferred.await(mergeLookupStarted);
        yield* Deferred.await(mergedThreadSettled);
        yield* Deferred.succeed(releaseMergeLookup, undefined);
        yield* reactor.drain;

        assert.deepStrictEqual(
          (yield* Ref.get(fixture.commands)).map((command) => command.threadId),
          [ThreadId.make("merged-in-app")],
        );
        assert.deepStrictEqual(
          (yield* Ref.get(fixture.summaryCalls))
            .map((call) => call.number)
            .toSorted((left, right) => left - right),
          [42, 99, 99],
        );
      }).pipe(Effect.provide(fixture.layer));
    }),
  );
});

describe("ThreadSettlementServiceV2 reply check", () => {
  const RUN_ENDED_AT = DateTime.makeUnsafe("2026-08-28T10:00:00.000Z");
  // The user last wrote on 08-20 and the pull request merged at NOW, after the latest run ended.
  const mergedThread = (
    id: string,
    overrides: Partial<SettlementShell> & { readonly latestRunCompletedAt?: DateTime.Utc } = {},
  ) => {
    const completedAt = overrides.latestRunCompletedAt ?? RUN_ENDED_AT;
    return makeThread(id, {
      status: "completed",
      latestRunId: RunId.make(`run:${id}:1`),
      latestRunStartedAt: DateTime.subtract(completedAt, { minutes: 20 }),
      latestRunCompletedAt: completedAt,
      pullRequests: [finishedLink("merged", "2026-08-20T00:00:00.000Z", NOW)],
      ...overrides,
    });
  };
  const records = (
    thread: SettlementShell,
    reply: string,
    run: { readonly by?: "user" | "agent" | "scheduled"; readonly stopped?: boolean } = {},
  ) =>
    latestRunRecords({
      threadId: thread.id,
      run: {
        id: thread.latestRunId!,
        request: { text: `Request for ${thread.id}`, by: run.by ?? "user" },
        reply,
        ...(run.stopped ? { stopped: true } : {}),
      },
    });
  const settings = { ...DEFAULT_SERVER_SETTINGS, sidebarAutoSettleAfterDays: 3 };
  // The model's verdict: a reply that ends in a question needs the user.
  const asksWhenQuestion: TextGeneration.TextGeneration["Service"]["checkSettlementReply"] = (
    input,
  ) => Effect.succeed({ needsUser: input.reply.trimEnd().endsWith("?") });
  const sources = (commands: ReadonlyArray<AutoSettleCommand>) =>
    new Map(commands.map((command) => [command.threadId, command.settlementSource]));
  // Sweeps every candidate again now, without waiting for the minute timer.
  const sweepAgain = (
    fixture: Effect.Success<ReturnType<typeof makeHarness>>,
    service: ThreadSettlementService.ThreadSettlementServiceV2["Service"],
    patch: ServerSettingsPatch,
  ) =>
    Effect.gen(function* () {
      yield* service.drain;
      yield* Queue.clear(fixture.snapshotReads);
      yield* fixture.updateSettings(patch);
      yield* Queue.take(fixture.snapshotReads);
      yield* service.drain;
    });

  it.effect(
    "keeps a merged thread whose last reply needs the user and settles one that does not",
    () =>
      Effect.scoped(
        Effect.gen(function* () {
          yield* TestClock.setTime(Date.parse(NOW));
          const asks = mergedThread("asks");
          const done = mergedThread("done");
          const fixture = yield* makeHarness({
            snapshot: makeSnapshot([asks, done]),
            settings,
            runRecords: [
              records(asks, "Merged. Want me to post the summary in the thread?"),
              records(done, "Merged, and the deploy finished.", { by: "scheduled" }),
            ],
            checkSettlementReply: asksWhenQuestion,
          });
          yield* Effect.gen(function* () {
            const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
            yield* startHarness(service, fixture.activation, fixture.snapshotReads);
            expect(sources(yield* Ref.get(fixture.commands))).toEqual(
              new Map([[done.id, "auto_pull_request_merged"]]),
            );
            const checks = yield* Ref.get(fixture.replyChecks);
            expect(checks.find((check) => check.request === `Request for ${asks.id}`)).toEqual({
              cwd: "/workspace/project",
              request: `Request for ${asks.id}`,
              requestOrigin: "user",
              reply: "Merged. Want me to post the summary in the thread?",
              pullRequestState: "merged",
              pullRequestFinishedAfterReply: true,
              modelSelection: DEFAULT_SERVER_SETTINGS.textGenerationModelSelection,
            });
            expect(
              checks.find((check) => check.request === `Request for ${done.id}`)?.requestOrigin,
            ).toBe("scheduled");
          }).pipe(Effect.provide(fixture.layer));
        }),
      ),
  );

  it.effect("asks the model once per run, and again for the next run", () =>
    Effect.scoped(
      Effect.gen(function* () {
        yield* TestClock.setTime(Date.parse(NOW));
        const asks = mergedThread("asks-once");
        // Found from the branch, not a link: the lookup path is held the same way.
        const onBranch = makeThread("branch-asks-once", {
          branch: "feature",
          status: "completed",
          latestUserMessageAt: DateTime.makeUnsafe("2026-08-28T08:00:00.000Z"),
          latestRunId: RunId.make("run:branch-asks-once:1"),
          latestRunCompletedAt: RUN_ENDED_AT,
        });
        const fixture = yield* makeHarness({
          snapshot: makeSnapshot([asks, onBranch]),
          settings,
          runRecords: [
            records(asks, "Want both, or just one?"),
            records(onBranch, "I'm holding until you say yes. Should I add his paths?"),
          ],
          checkSettlementReply: asksWhenQuestion,
          branchPullRequest: () => Effect.succeed(makeBranchPullRequest("merged")),
        });
        yield* Effect.gen(function* () {
          const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
          yield* startHarness(service, fixture.activation, fixture.snapshotReads);
          yield* sweepAgain(fixture, service, { sidebarAutoSettleAfterDays: 4 });
          yield* sweepAgain(fixture, service, { sidebarAutoSettleAfterDays: 5 });
          assert.deepEqual(yield* Ref.get(fixture.commands), []);
          assert.equal((yield* Ref.get(fixture.replyChecks)).length, 2);

          // A scheduled check-in runs again and reports nothing that needs the user.
          const nextRun = { ...asks, latestRunId: RunId.make("run:asks-once:2") };
          yield* Ref.set(fixture.snapshots, makeSnapshot([nextRun, onBranch]));
          yield* Ref.update(fixture.runRecords, (current) => [
            records(nextRun, "No change since the last check.", { by: "scheduled" }),
            ...current,
          ]);
          yield* sweepAgain(fixture, service, { sidebarAutoSettleAfterDays: 6 });
          expect(sources(yield* Ref.get(fixture.commands))).toEqual(
            new Map([[asks.id, "auto_pull_request_merged"]]),
          );
          assert.equal((yield* Ref.get(fixture.replyChecks)).length, 3);

          // Three sweeps held each first run once, with what the model said; then the next run settled.
          const decisions = (yield* recordedDecisions).map((row) => ({
            thread: row.thread_id,
            run: row.run_id,
            outcome: row.outcome,
            rule: row.rule,
            hold: row.hold_reason,
            check: JSON.parse(row.reply_check_json ?? "null"),
          }));
          const model = `${settings.textGenerationModelSelection.instanceId}:${settings.textGenerationModelSelection.model}`;
          expect(decisions).toEqual([
            {
              thread: asks.id,
              run: asks.latestRunId,
              outcome: "held",
              rule: "auto_pull_request_merged",
              hold: "needs_user",
              check: {
                outcome: "holds",
                reason: "needs_user",
                verdict: { model, requestOrigin: "user", needsUser: true, attempt: 1 },
              },
            },
            {
              thread: onBranch.id,
              run: onBranch.latestRunId,
              outcome: "held",
              rule: "auto_branch_pull_request_merged",
              hold: "needs_user",
              check: {
                outcome: "holds",
                reason: "needs_user",
                verdict: { model, requestOrigin: "user", needsUser: true, attempt: 1 },
              },
            },
            {
              thread: asks.id,
              run: nextRun.latestRunId,
              outcome: "settled",
              rule: "auto_pull_request_merged",
              hold: null,
              check: {
                outcome: "settles",
                verdict: { model, requestOrigin: "scheduled", needsUser: false, attempt: 1 },
              },
            },
          ]);
        }).pipe(Effect.provide(fixture.layer));
      }),
    ),
  );

  it.effect("holds while the model fails, retrying a bounded number of times", () =>
    Effect.scoped(
      Effect.gen(function* () {
        yield* TestClock.setTime(Date.parse(NOW));
        const thread = mergedThread("model-down");
        const calls = yield* Queue.unbounded<void>();
        const fixture = yield* makeHarness({
          snapshot: makeSnapshot([thread]),
          settings,
          runRecords: [records(thread, "Merged, nothing left to do.")],
          checkSettlementReply: () =>
            Queue.offer(calls, undefined).pipe(
              Effect.andThen(
                Effect.fail(
                  new TextGenerationError({
                    operation: "checkSettlementReply",
                    detail: "Request rejected (429)",
                  }),
                ),
              ),
            ),
        });
        yield* Effect.gen(function* () {
          const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
          yield* startHarness(service, fixture.activation, fixture.snapshotReads);
          yield* Queue.take(calls);
          // Sweeps inside the retry delay do not ask again.
          yield* sweepAgain(fixture, service, { sidebarAutoSettleAfterDays: 4 });
          yield* TestClock.adjust("4 minutes");
          yield* service.drain;
          assert.equal((yield* Ref.get(fixture.replyChecks)).length, 1);

          yield* TestClock.adjust("1 minute");
          yield* Queue.take(calls);
          yield* TestClock.adjust("30 minutes");
          yield* Queue.take(calls);
          // Three failures use up the retries; only inactivity can settle this run now.
          yield* TestClock.adjust("2 hours");
          yield* sweepAgain(fixture, service, { sidebarAutoSettleAfterDays: 5 });
          assert.equal((yield* Ref.get(fixture.replyChecks)).length, 3);
          assert.deepEqual(yield* Ref.get(fixture.commands), []);
        }).pipe(Effect.provide(fixture.layer));
      }),
    ),
  );

  it.effect.each([true, false])(
    "does not settle on a merge after the latest run failed, was interrupted, or was stopped (reply check %s)",
    (checkReply) =>
      Effect.scoped(
        Effect.gen(function* () {
          yield* TestClock.setTime(Date.parse(NOW));
          const idleSince = {
            latestRunCompletedAt: DateTime.makeUnsafe("2026-08-26T10:00:00.000Z"),
          };
          const failed = mergedThread("failed-run", { ...idleSince, status: "failed" });
          const interrupted = mergedThread("interrupted-run", {
            ...idleSince,
            status: "interrupted",
          });
          // Stop pressed after the run completed, while its background work still ran.
          const stopped = mergedThread("stopped-run", idleSince);
          const fixture = yield* makeHarness({
            snapshot: makeSnapshot([failed, interrupted, stopped]),
            settings: { ...settings, sidebarAutoSettleReplyCheck: checkReply },
            runRecords: [
              latestRunRecords({
                threadId: failed.id,
                run: { id: failed.latestRunId!, status: "failed", reply: "API Error: 429" },
              }),
              latestRunRecords({
                threadId: interrupted.id,
                run: { id: interrupted.latestRunId!, status: "interrupted", reply: "Stopped." },
              }),
              records(stopped, "All merged and verified.", { stopped: true }),
            ],
          });
          yield* Effect.gen(function* () {
            const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
            yield* startHarness(service, fixture.activation, fixture.snapshotReads);
            assert.deepEqual(yield* Ref.get(fixture.commands), []);

            // Inactivity still settles them.
            yield* sweepAgain(fixture, service, { sidebarAutoSettleAfterDays: 1 });
            expect(sources(yield* Ref.get(fixture.commands))).toEqual(
              new Map([
                [failed.id, "auto_inactivity"],
                [interrupted.id, "auto_inactivity"],
                [stopped.id, "auto_inactivity"],
              ]),
            );
            assert.deepEqual(yield* Ref.get(fixture.replyChecks), []);
          }).pipe(Effect.provide(fixture.layer));
        }),
      ),
  );

  it.effect("settles on merge without asking the model while the reply check is off", () =>
    Effect.scoped(
      Effect.gen(function* () {
        yield* TestClock.setTime(Date.parse(NOW));
        const asks = mergedThread("asks-check-off");
        const fixture = yield* makeHarness({
          snapshot: makeSnapshot([asks]),
          settings: { ...settings, sidebarAutoSettleReplyCheck: false },
          runRecords: [records(asks, "Want me to send it?")],
        });
        yield* Effect.gen(function* () {
          const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
          yield* startHarness(service, fixture.activation, fixture.snapshotReads);
          expect(sources(yield* Ref.get(fixture.commands))).toEqual(
            new Map([[asks.id, "auto_pull_request_merged"]]),
          );
          assert.deepEqual(yield* Ref.get(fixture.replyChecks), []);
        }).pipe(Effect.provide(fixture.layer));
      }),
    ),
  );

  it.effect.each([true, false])(
    "keeps a scheduled report visible when its run reopened a long-merged thread (triage %s)",
    (notificationTriage) =>
      Effect.scoped(
        Effect.gen(function* () {
          yield* TestClock.setTime(Date.parse(NOW));
          // Merged a week before the scheduled run that reopened each thread.
          const mergedLastWeek = {
            pullRequests: [
              finishedLink("merged", "2026-08-20T00:00:00.000Z", "2026-08-21T00:00:00.000Z"),
            ],
          };
          const digest = mergedThread("daily-digest", mergedLastWeek);
          const monitor = mergedThread("quiet-monitor", mergedLastWeek);
          // Merged once the run was under way: the run's own outcome, which settles as before.
          const mergedByRun = mergedThread("merged-by-run");
          const fixture = yield* makeHarness({
            snapshot: makeSnapshot([digest, monitor, mergedByRun]),
            settings: { ...settings, notificationTriage },
            runRecords: [
              records(digest, "Theo's new video compares three models; on X, two launches.", {
                by: "scheduled",
              }),
              records(monitor, "No change since yesterday.", { by: "scheduled" }),
              records(mergedByRun, "Merged it once CI passed.", { by: "scheduled" }),
            ],
            checkSettlementReply: asksWhenQuestion,
            shouldNotify: (input) => Effect.succeed(input.threadId === digest.id),
          });
          yield* Effect.gen(function* () {
            const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
            yield* startHarness(service, fixture.activation, fixture.snapshotReads);
            const settled = new Map([
              [monitor.id, "auto_pull_request_merged"],
              [mergedByRun.id, "auto_pull_request_merged"],
            ]);
            if (!notificationTriage) settled.set(digest.id, "auto_pull_request_merged");
            expect(sources(yield* Ref.get(fixture.commands))).toEqual(settled);
            expect((yield* Ref.get(fixture.triagedRuns)).toSorted()).toEqual(
              notificationTriage ? [digest.latestRunId, monitor.latestRunId].toSorted() : [],
            );
            if (!notificationTriage) return;
            // Triage alone held the digest: the reply check, which would have let it settle, never ran.
            expect(
              (yield* Ref.get(fixture.replyChecks)).map((check) => check.request).toSorted(),
            ).toEqual([`Request for ${monitor.id}`, `Request for ${mergedByRun.id}`].toSorted());
            const held = (yield* recordedDecisions).filter((row) => row.thread_id === digest.id);
            expect(
              held.map((row) => ({
                outcome: row.outcome,
                rule: row.rule,
                hold: row.hold_reason,
                check: JSON.parse(row.reply_check_json ?? "null"),
              })),
            ).toEqual([
              {
                outcome: "held",
                rule: "auto_pull_request_merged",
                hold: "scheduled_news",
                check: { outcome: "holds", reason: "scheduled_news" },
              },
            ]);
          }).pipe(Effect.provide(fixture.layer));
        }),
      ),
  );

  it.effect(
    "still settles a thread on inactivity while its reply keeps the merge from settling it",
    () =>
      Effect.scoped(
        Effect.gen(function* () {
          yield* TestClock.setTime(Date.parse(NOW));
          const asks = mergedThread("asks-then-idle", {
            latestRunCompletedAt: DateTime.makeUnsafe("2026-08-26T10:00:00.000Z"),
          });
          const fixture = yield* makeHarness({
            snapshot: makeSnapshot([asks]),
            settings,
            runRecords: [records(asks, "Should I open the follow-up PR?")],
            checkSettlementReply: asksWhenQuestion,
          });
          yield* Effect.gen(function* () {
            const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
            yield* startHarness(service, fixture.activation, fixture.snapshotReads);
            assert.deepEqual(yield* Ref.get(fixture.commands), []);
            yield* sweepAgain(fixture, service, { sidebarAutoSettleAfterDays: 1 });
            expect(sources(yield* Ref.get(fixture.commands))).toEqual(
              new Map([[asks.id, "auto_inactivity"]]),
            );
            assert.equal((yield* Ref.get(fixture.replyChecks)).length, 1);
          }).pipe(Effect.provide(fixture.layer));
        }),
      ),
  );
});

describe("ThreadSettlementServiceV2 terminals", () => {
  it.effect.each(["re-engaged", "deleted"] as const)(
    "skips settlement actions for a thread %s before the event ran",
    (state) =>
      Effect.gen(function* () {
        const settled = appThread("stale-thread", "settled", "/worktrees/stale");
        const current =
          state === "re-engaged"
            ? { ...settled, settledOverride: "active" as const }
            : { ...settled, deletedAt: DateTime.makeUnsafe(NOW) };
        const marker = appThread("marker-thread", "settled", "/worktrees/marker");
        const fixture = yield* makeHarness({
          snapshot: makeSnapshot([]),
          currentThreads: [current, marker],
          existingWorktreePaths: ["/worktrees/stale", "/worktrees/marker"],
        });

        yield* Effect.gen(function* () {
          const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
          yield* startHarness(service, fixture.activation, fixture.snapshotReads);
          yield* fixture.publishEvent(settledEvent(settled));
          yield* fixture.publishEvent(settledEvent(marker));
          assert.deepStrictEqual(yield* Queue.take(fixture.closedIdle), { threadId: marker.id });
          assert.strictEqual((yield* Queue.take(fixture.scriptRuns)).threadId, marker.id);
        }).pipe(Effect.provide(fixture.layer));
      }),
  );

  it.effect("runs the settle script in the thread's own worktree", () =>
    Effect.gen(function* () {
      const shared = appThread("shared-checkout-thread", "settled");
      const missing = appThread("removed-worktree-thread", "settled", "/worktrees/removed");
      const worktree = appThread("worktree-thread", "settled", "/worktrees/thread");
      const fixture = yield* makeHarness({
        snapshot: makeSnapshot([]),
        currentThreads: [shared, missing, worktree],
        existingWorktreePaths: ["/worktrees/thread"],
      });

      yield* Effect.gen(function* () {
        const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
        yield* startHarness(service, fixture.activation, fixture.snapshotReads);
        yield* fixture.publishEvent(settledEvent(shared));
        yield* fixture.publishEvent(settledEvent(missing));
        yield* fixture.publishEvent(settledEvent(worktree));
        const run = yield* Queue.take(fixture.scriptRuns);
        assert.strictEqual(run.threadId, worktree.id);
        assert.strictEqual(run.worktreePath, "/worktrees/thread");
        assert.strictEqual(run.trigger, "settle");
      }).pipe(Effect.provide(fixture.layer));
    }),
  );

  it.effect.each(["re-engaged", "deleted"] as const)(
    "skips the settle script for a thread %s while its shells close",
    (state) =>
      Effect.gen(function* () {
        const settled = appThread("stale-thread", "settled", "/worktrees/stale");
        const marker = appThread("marker-thread", "settled", "/worktrees/marker");
        const currentThreads = [settled, marker];
        const fixture = yield* makeHarness({
          snapshot: makeSnapshot([]),
          currentThreads,
          existingWorktreePaths: ["/worktrees/stale", "/worktrees/marker"],
          onCloseIdle: () =>
            Effect.sync(() => {
              currentThreads[0] =
                state === "re-engaged"
                  ? { ...settled, settledOverride: "active" }
                  : { ...settled, deletedAt: DateTime.makeUnsafe(NOW) };
            }),
        });

        yield* Effect.gen(function* () {
          const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
          yield* startHarness(service, fixture.activation, fixture.snapshotReads);
          yield* fixture.publishEvent(settledEvent(settled));
          yield* fixture.publishEvent(settledEvent(marker));
          assert.strictEqual((yield* Queue.take(fixture.scriptRuns)).threadId, marker.id);
        }).pipe(Effect.provide(fixture.layer));
      }),
  );

  it.effect("skips the settle script for a subagent in its parent's worktree", () =>
    Effect.gen(function* () {
      const parent = appThread("subagent-parent", "settled", "/worktrees/parent");
      const subagent = (id: string, worktreePath: string) => ({
        ...appThread(id, "settled", worktreePath),
        lineage: {
          parentThreadId: parent.id,
          relationshipToParent: "subagent" as const,
          rootThreadId: parent.id,
        },
      });
      const shared = subagent("subagent-shared", "/worktrees/parent");
      const own = subagent("subagent-own", "/worktrees/own");
      const fixture = yield* makeHarness({
        snapshot: makeSnapshot([]),
        currentThreads: [parent, shared, own],
        existingWorktreePaths: ["/worktrees/parent", "/worktrees/own"],
      });

      yield* Effect.gen(function* () {
        const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
        yield* startHarness(service, fixture.activation, fixture.snapshotReads);
        // Events run in order, so the first run belongs to the second event
        // only if the shared-worktree child was skipped. Both still close.
        yield* fixture.publishEvent(settledEvent(shared));
        yield* fixture.publishEvent(settledEvent(own));
        assert.deepStrictEqual(yield* Queue.take(fixture.closedIdle), { threadId: shared.id });
        assert.deepStrictEqual(yield* Queue.take(fixture.closedIdle), { threadId: own.id });
        assert.strictEqual((yield* Queue.take(fixture.scriptRuns)).threadId, own.id);
      }).pipe(Effect.provide(fixture.layer));
    }),
  );

  it.effect("runs the settle script once when a settlement is re-emitted", () =>
    Effect.gen(function* () {
      const repeated = appThread("repeated-thread", "settled", "/worktrees/repeated");
      const marker = appThread("marker-thread", "settled", "/worktrees/marker");
      const fixture = yield* makeHarness({
        snapshot: makeSnapshot([]),
        currentThreads: [repeated, marker],
        existingWorktreePaths: ["/worktrees/repeated", "/worktrees/marker"],
      });

      yield* Effect.gen(function* () {
        const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
        yield* startHarness(service, fixture.activation, fixture.snapshotReads);
        yield* fixture.publishEvent(settledEvent(repeated));
        yield* fixture.publishEvent(settledEvent(repeated));
        yield* fixture.publishEvent(settledEvent(marker));
        assert.strictEqual((yield* Queue.take(fixture.scriptRuns)).threadId, repeated.id);
        assert.strictEqual((yield* Queue.take(fixture.scriptRuns)).threadId, marker.id);
      }).pipe(Effect.provide(fixture.layer));
    }),
  );

  it.effect("retries the settle script on a re-emitted settlement after a failed start", () =>
    Effect.gen(function* () {
      const thread = appThread("failed-start-thread", "settled", "/worktrees/failed-start");
      const starts = yield* Ref.make(0);
      const fixture = yield* makeHarness({
        snapshot: makeSnapshot([]),
        currentThreads: [thread],
        existingWorktreePaths: ["/worktrees/failed-start"],
        onScriptRun: () =>
          Ref.updateAndGet(starts, (count) => count + 1).pipe(
            Effect.flatMap((count) =>
              count === 1 ? Effect.die(new Error("terminal failed to open")) : Effect.void,
            ),
          ),
      });

      yield* Effect.gen(function* () {
        const service = yield* ThreadSettlementService.ThreadSettlementServiceV2;
        yield* startHarness(service, fixture.activation, fixture.snapshotReads);
        yield* fixture.publishEvent(settledEvent(thread));
        yield* fixture.publishEvent(settledEvent(thread));
        assert.strictEqual((yield* Queue.take(fixture.scriptRuns)).threadId, thread.id);
        assert.strictEqual((yield* Queue.take(fixture.scriptRuns)).threadId, thread.id);
      }).pipe(Effect.provide(fixture.layer));
    }),
  );
});

describe("isSnoozed", () => {
  const snoozed = { snoozedAt: at(-2 * DAY_MS), snoozedUntil: at(DAY_MS) };
  it("defers existing input while new questions and approvals wake the thread", () => {
    const request = {
      id: RuntimeRequestId.make("question"),
      kind: "user_input" as const,
      createdAt: snoozed.snoozedAt,
    };
    expect(
      ThreadSettlementService.isSnoozed(
        shell({ ...snoozed, pendingRuntimeRequest: request }),
        NOW_MS,
      ),
    ).toBe(true);
    expect(
      ThreadSettlementService.isSnoozed(
        shell({ ...snoozed, pendingRuntimeRequest: { ...request, createdAt: at(-DAY_MS) } }),
        NOW_MS,
      ),
    ).toBe(false);
    expect(
      ThreadSettlementService.isSnoozed(
        shell({ ...snoozed, pendingRuntimeRequest: { ...request, kind: "command" } }),
        NOW_MS,
      ),
    ).toBe(false);
    expect(
      ThreadSettlementService.isSnoozed(
        shell({ ...snoozed, snoozedAt: null, pendingRuntimeRequest: request }),
        NOW_MS,
      ),
    ).toBe(false);
  });
  it("keeps a run requested and completed after snoozing parked until the timer", () => {
    const thread = shell({
      ...snoozed,
      status: "completed",
      latestRunRequestedAt: at(-2 * DAY_MS + 1),
      latestRunStartedAt: at(-DAY_MS - 1),
      latestRunCompletedAt: at(-DAY_MS),
    });

    expect(ThreadSettlementService.isSnoozed(thread, NOW_MS)).toBe(true);
    expect(ThreadSettlementService.isAutoSettlementCandidate(thread, NOW_MS)).toBe(false);
    expect(
      ThreadSettlementService.resolveAutoSettlementAt({
        thread,
        pullRequest: { state: "merged", mergedAt: DateTime.formatIso(at(-1)) },
        nowMs: NOW_MS,
        autoSettleAfterDays: null,
        autoSettleOnMerge: true,
      }),
    ).toBeNull();
  });
});
