import { assert, describe, it } from "@effect/vitest";
import * as NodeSqlite from "node:sqlite";

import {
  classifyAppBinaryProcess,
  DEFAULT_GRACE_MS,
  parseGrace,
  readRestartThreads,
  readResumeOutcome,
  readResumeSettings,
  summarizeOutcomes,
} from "./fork-install-restarts.ts";

const NOW = Date.parse("2026-11-17T12:00:00.000Z");

// The columns these helpers read, as the server's migrations define them.
const makeDb = () => {
  const db = new NodeSqlite.DatabaseSync(":memory:");
  db.exec(`
    CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, title TEXT NOT NULL);
    CREATE TABLE orchestration_v2_projection_threads (
      thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL,
      archived_at TEXT, deleted_at TEXT, payload_json TEXT NOT NULL
    );
    CREATE TABLE orchestration_v2_projection_runs (
      run_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, status TEXT NOT NULL,
      requested_at TEXT NOT NULL, payload_json TEXT NOT NULL
    );
    CREATE TABLE orchestration_v2_projection_messages (
      message_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, role TEXT NOT NULL,
      updated_at TEXT NOT NULL, payload_json TEXT NOT NULL
    );
    CREATE TABLE orchestration_v2_effect_outbox (
      effect_id TEXT PRIMARY KEY, status TEXT NOT NULL, last_error TEXT
    );
  `);
  db.prepare(`INSERT INTO projection_projects VALUES (?, ?), (?, ?)`).run(
    "app",
    "t3code",
    "quiet",
    "notes",
  );
  return db;
};

const addThread = (
  db: NodeSqlite.DatabaseSync,
  id: string,
  options: {
    readonly project?: string;
    readonly runStatus?: string;
    readonly archived?: boolean;
    readonly payload?: Record<string, unknown>;
  } = {},
) => {
  db.prepare(`INSERT INTO orchestration_v2_projection_threads VALUES (?, ?, ?, ?, NULL, ?)`).run(
    id,
    options.project ?? "app",
    `Thread ${id}`,
    options.archived ? "2026-11-16T00:00:00.000Z" : null,
    JSON.stringify(options.payload ?? {}),
  );
  db.prepare(`INSERT INTO orchestration_v2_projection_runs VALUES (?, ?, ?, ?, '{}')`).run(
    `run:${id}`,
    id,
    options.runStatus ?? "running",
    "2026-11-17T11:00:00.000Z",
  );
};

describe("parseGrace", () => {
  it("reads minutes, durations and forever", () => {
    assert.strictEqual(parseGrace(undefined), DEFAULT_GRACE_MS);
    assert.strictEqual(parseGrace("0"), 0);
    assert.strictEqual(parseGrace("20"), 20 * 60_000);
    assert.strictEqual(parseGrace("90s"), 90_000);
    assert.strictEqual(parseGrace("1.5h"), 90 * 60_000);
    assert.isNull(parseGrace("forever"));
    assert.throws(() => parseGrace("soon"), /--grace/);
  });
});

describe("classifyAppBinaryProcess", () => {
  const app = "/Applications/T3 Code (Fork).app";
  const tools = "/Users/max/.t3/tools";
  const binary = `${app}/Contents/MacOS/T3 Code (Fork)`;
  const classify = (command: string) => classifyAppBinaryProcess(command, app, tools);

  it("tells the app from the tool daemons that outlive it on its binary", () => {
    assert.strictEqual(classify(binary), "app");
    assert.strictEqual(
      classify(
        `${binary} --require ${app}/Contents/Resources/app.asar/apps/desktop/dist-electron/compileCache.cjs ${app}/Contents/Resources/app.asar/apps/server/dist/bin.mjs --bootstrap-fd 3`,
      ),
      "app",
    );
    // The detached agent-device daemon that kept a Nov 24 install from replacing the app.
    assert.strictEqual(
      classify(
        `${binary} ${tools}/agent-device/0.21.36/node_modules/agent-device/dist/src/internal/daemon.js`,
      ),
      "tool",
    );
    assert.strictEqual(
      classify(
        `${binary} ${tools}/expo-device-hub/0.22.1/node_modules/expo-device-hub/dist/server/cli.mjs`,
      ),
      "tool",
    );
    assert.strictEqual(classify(`/usr/bin/lldb ${binary}`), null);
    assert.strictEqual(classify("/usr/bin/node scripts/install-fork-desktop.ts"), null);
  });
});

describe("restart threads", () => {
  it("records cut turns, turns waiting on the user, and why a turn will not be continued", () => {
    const db = makeDb();
    addThread(db, "plain");
    addThread(db, "waiting", { runStatus: "waiting" });
    addThread(db, "snoozed", { payload: { snoozedUntil: "2026-11-17T13:00:00.000Z" } });
    addThread(db, "snooze-over", { payload: { snoozedUntil: "2026-11-17T10:00:00.000Z" } });
    addThread(db, "settled", { payload: { settledOverride: "settled" } });
    addThread(db, "archived", { archived: true });
    addThread(db, "off", { project: "quiet" });
    addThread(db, "child", { payload: { lineage: { parentThreadId: "plain" } } });
    addThread(db, "done", { runStatus: "completed" });
    // A turn queued behind the running one is the same thread, recorded once by its running turn.
    db.prepare(`INSERT INTO orchestration_v2_projection_runs VALUES (?, ?, ?, ?, '{}')`).run(
      "run:plain:next",
      "plain",
      "queued",
      "2026-11-17T11:30:00.000Z",
    );
    const message = db.prepare(
      `INSERT INTO orchestration_v2_projection_messages VALUES (?, 'plain', 'user', ?, ?)`,
    );
    message.run(
      "m1",
      "2026-11-17T10:00:00.000Z",
      JSON.stringify({ createdBy: "user", text: "fix the  build\nplease" }),
    );
    // A wake notice is stored with the user role but was not sent by the user.
    message.run(
      "m2",
      "2026-11-17T11:00:00.000Z",
      JSON.stringify({ createdBy: "agent", text: "Background command finished" }),
    );

    const settings = readResumeSettings({
      projectSettingsOverrides: { quiet: { continueThreadsAfterServerUpdate: false } },
    });
    const threads = readRestartThreads(db, settings, NOW);
    const byId = new Map(threads.map((thread) => [thread.threadId, thread]));

    assert.deepStrictEqual(threads.map((thread) => thread.threadId).toSorted(), [
      "archived",
      "child",
      "off",
      "plain",
      "settled",
      "snooze-over",
      "snoozed",
      "waiting",
    ]);
    assert.deepInclude(byId.get("plain"), {
      runId: "run:plain",
      projectTitle: "t3code",
      lastRequest: "fix the build please",
      waitingOnUser: false,
      child: false,
      expectedResume: "yes",
    });
    assert.isTrue(byId.get("waiting")!.waitingOnUser);
    assert.strictEqual(byId.get("snoozed")!.expectedResume, "snoozed");
    assert.strictEqual(byId.get("snooze-over")!.expectedResume, "yes");
    assert.strictEqual(byId.get("settled")!.expectedResume, "settled");
    assert.strictEqual(byId.get("archived")!.expectedResume, "archived");
    assert.strictEqual(byId.get("off")!.expectedResume, "resume off");
    assert.isTrue(byId.get("child")!.child);
  });

  it("follows the global resume setting unless a project overrides it", () => {
    assert.deepStrictEqual(readResumeSettings({}), { global: true, projects: {} });
    assert.deepStrictEqual(
      readResumeSettings({
        continueThreadsAfterServerUpdate: false,
        projectSettingsOverrides: { app: { continueThreadsAfterServerUpdate: true }, other: {} },
      }),
      { global: false, projects: { app: true } },
    );
  });
});

describe("resume outcomes", () => {
  it("reads the server's restart continuation for each cut turn", () => {
    const db = makeDb();
    for (const id of ["resumed", "starting", "failed", "finished", "snoozed", "declined"]) {
      addThread(
        db,
        id,
        id === "snoozed" ? { payload: { snoozedUntil: "2026-11-17T13:00:00.000Z" } } : {},
      );
    }
    const threads = new Map(
      readRestartThreads(db, readResumeSettings({}), NOW).map((thread) => [
        thread.threadId,
        thread,
      ]),
    );
    const effect = db.prepare(`INSERT INTO orchestration_v2_effect_outbox VALUES (?, ?, ?)`);
    effect.run("effect:restart-continuation:run:resumed", "succeeded", null);
    effect.run("effect:restart-continuation:run:starting", "pending", null);
    effect.run("effect:restart-continuation:run:failed", "failed", "provider unavailable");
    const setRun = db.prepare(
      `UPDATE orchestration_v2_projection_runs SET status = ? WHERE run_id = ?`,
    );
    setRun.run("completed", "run:finished");
    setRun.run("cancelled", "run:snoozed");
    setRun.run("cancelled", "run:declined");

    const outcome = (id: string) => readResumeOutcome(db, threads.get(id)!);
    addThread(db, "queued", { runStatus: "queued" });
    const queued = readRestartThreads(db, readResumeSettings({}), NOW).find(
      (thread) => thread.threadId === "queued",
    )!;
    assert.deepStrictEqual(readResumeOutcome(db, queued), { kind: "pending" });
    setRun.run("running", "run:queued");
    assert.deepStrictEqual(readResumeOutcome(db, queued), { kind: "resumed" });
    assert.deepStrictEqual(outcome("resumed"), { kind: "resumed" });
    assert.deepStrictEqual(outcome("starting"), { kind: "pending" });
    assert.deepStrictEqual(outcome("failed"), { kind: "failed", error: "provider unavailable" });
    assert.deepStrictEqual(outcome("finished"), {
      kind: "finished before quit",
      runStatus: "completed",
    });
    assert.deepStrictEqual(outcome("snoozed"), { kind: "not resumed", reason: "snoozed" });
    assert.deepStrictEqual(outcome("declined"), { kind: "not resumed", reason: "server declined" });

    assert.strictEqual(
      summarizeOutcomes(
        ["resumed", "failed", "snoozed", "declined", "finished"].map((id) => outcome(id)),
      ),
      "1 resumed, 1 failed to resume, 2 not resumed (snoozed, server declined), 1 finished before the quit",
    );
  });
});
