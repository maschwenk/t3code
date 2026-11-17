// @effect-diagnostics nodeBuiltinImport:off globalDate:off globalConsole:off - Dependency-free host-side installer with no Effect runtime, like setup-worktree.ts.
/** Build this checkout as "T3 Code (Fork)" (`-fork.<date>.<sha>`: own bundle id, no update feed)
 * and install it into /Applications. macOS only; see "Running your own fork" in development.md.
 *   node scripts/install-fork-desktop.ts [--no-launch] [--skip-build | --build-only]
 *     [--grace <minutes|90s|1h|forever> | --now] [--identity <codesign name>|none] [--allow-no-connect] */
import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeSqlite from "node:sqlite";
import * as NodeUtil from "node:util";

import {
  describeOutcome,
  formatGrace,
  parseGrace,
  readRestartThreads,
  readResumeOutcome,
  readResumeSettings,
  type RestartThread,
  type ResumeOutcome,
  summarizeOutcomes,
  WORKING_RUN_STATUSES,
} from "./lib/fork-install-restarts.ts";
import { loadRepoEnv } from "./lib/public-config.ts";

const PRODUCT_NAME = "T3 Code (Fork)";
const BUNDLE_ID = "com.t3tools.t3code.fork";
const APPLICATIONS_DIR = "/Applications";
const INSTALLED_APP = NodePath.join(APPLICATIONS_DIR, `${PRODUCT_NAME}.app`);
const USERDATA_DIR = NodePath.join(NodeOS.homedir(), ".t3", "userdata");
const STATE_DB = NodePath.join(USERDATA_DIR, "statev2.sqlite");
const SETTINGS_FILE = NodePath.join(USERDATA_DIR, "settings.json");
// How long after the relaunch to wait for the server to continue the turns the quit cut short.
const RESUME_CHECK_MS = 180_000;
const BACKGROUND_INSTALL_FLAG = "--background-install";
const CONNECT_ENV_KEYS = [
  "T3CODE_CLERK_PUBLISHABLE_KEY",
  "T3CODE_CLERK_JWT_TEMPLATE",
  "T3CODE_CLERK_CLI_OAUTH_CLIENT_ID",
  "T3CODE_RELAY_URL",
] as const;

const repoRoot = NodePath.dirname(import.meta.dirname);
const args = process.argv.slice(2);
const launch = !args.includes("--no-launch");
const skipBuild = args.includes("--skip-build");
const buildOnly = args.includes("--build-only");
const allowNoConnect = args.includes("--allow-no-connect");
const installNow = args.includes("--now");
const graceIndex = args.indexOf("--grace");
if (graceIndex !== -1 && !args[graceIndex + 1]) {
  throw new Error("--grace needs minutes, a duration like 90s or 1h, or `forever`.");
}
// Working turns get this long to finish before the install quits the app anyway; the server
// continues the ones it cuts short after the relaunch.
const graceMs = installNow ? 0 : parseGrace(graceIndex === -1 ? undefined : args[graceIndex + 1]);
const backgroundInstall = args.includes(BACKGROUND_INSTALL_FLAG);
if (skipBuild && buildOnly) {
  throw new Error("--skip-build and --build-only together would do nothing.");
}
const identityIndex = args.indexOf("--identity");
const identityArg = identityIndex === -1 ? undefined : args[identityIndex + 1];
if (identityIndex !== -1 && !identityArg) {
  throw new Error("--identity needs a codesign identity name, or `none`.");
}

function run(
  command: string,
  commandArgs: ReadonlyArray<string>,
  options?: { env?: NodeJS.ProcessEnv },
) {
  const result = NodeChildProcess.spawnSync(command, commandArgs, {
    cwd: repoRoot,
    stdio: "inherit",
    env: options?.env ?? process.env,
  });
  if (result.status !== 0) {
    throw new Error(
      `${command} ${commandArgs.join(" ")} exited with ${result.status ?? "signal"}.`,
    );
  }
}

function capture(command: string, commandArgs: ReadonlyArray<string>): string {
  const result = NodeChildProcess.spawnSync(command, commandArgs, {
    cwd: repoRoot,
    encoding: "utf8",
  });
  return result.status === 0 ? result.stdout.trim() : "";
}

function resolveForkVersion(): string {
  const serverPackage = JSON.parse(
    NodeFS.readFileSync(NodePath.join(repoRoot, "apps/server/package.json"), "utf8"),
  ) as { version: string };
  const sha = capture("git", ["rev-parse", "--short=12", "HEAD"]);
  if (!sha) throw new Error("Could not read the git HEAD commit.");
  const now = new Date();
  const date = `${now.getUTCFullYear()}${String(now.getUTCMonth() + 1).padStart(2, "0")}${String(now.getUTCDate()).padStart(2, "0")}`;
  return `${serverPackage.version}-fork.${date}.${sha}`;
}

function resolveSigningIdentity(): string | undefined {
  if (identityArg === "none") return undefined;
  if (identityArg) return identityArg;
  const identities = capture("security", ["find-identity", "-v", "-p", "codesigning"]);
  // Password managers such as 1Password only connect to browsers with a Developer ID signature.
  const match =
    /"(Developer ID Application: [^"]+)"/.exec(identities) ??
    /"(Apple Development: [^"]+)"/.exec(identities);
  return match?.[1];
}

const outputDir = NodePath.join(repoRoot, "release", "fork");
const installLog = NodePath.join(outputDir, "install.log");
const installerPidFile = NodePath.join(outputDir, "install.pid");

// Agent shells inherit the hosting app's runner environment. Clear it for
// both building and launching: macOS `open` forwards ELECTRON_RUN_AS_NODE,
// which makes the installed app exit without opening a window.
const env = { ...process.env };
delete env.T3CODE_DESKTOP_UPDATE_REPOSITORY;
delete env.GITHUB_REPOSITORY;
delete env.ELECTRON_RUN_AS_NODE;
for (const key of Object.keys(env)) {
  if (
    key.startsWith("T3CODE_DESKTOP_") ||
    key.startsWith("T3CODE_DEV_") ||
    key.startsWith("VITE_") ||
    key === "T3CODE_HOME" ||
    key === "T3CODE_PORT" ||
    key === "PORT"
  ) {
    delete env[key];
  }
}

const repoEnv = loadRepoEnv({ baseEnv: env, repoRoot });
if (!repoEnv.T3CODE_CLERK_PUBLISHABLE_KEY?.trim() && !repoEnv.T3CODE_RELAY_URL?.trim()) {
  const exampleEnv = NodeUtil.parseEnv(
    NodeFS.readFileSync(NodePath.join(repoRoot, ".env.example"), "utf8"),
  );
  for (const key of CONNECT_ENV_KEYS) {
    const value = exampleEnv[key]?.trim();
    if (value) env[key] = value;
  }
  console.log("[fork-install] No T3 Connect config in the env or .env; using .env.example");
}
const connectMarkers = ["T3CODE_RELAY_URL", "T3CODE_CLERK_PUBLISHABLE_KEY"].map(
  (key) => env[key]?.trim() || repoEnv[key]?.trim(),
);

// Clerk keys and the relay URL are compiled into the server and web bundles as
// plain strings, so their absence from app.asar means Connect is off.
function assertConnectCompiledIn(builtApp: string) {
  if (allowNoConnect) return;
  const asar = NodeFS.readFileSync(NodePath.join(builtApp, "Contents/Resources/app.asar"));
  if (connectMarkers.every((marker) => marker && asar.includes(marker))) return;
  throw new Error(
    "This build has T3 Connect compiled out, so other devices could only reach it on the " +
      "local network. Build it with this script instead of build-desktop-artifact.ts, or pass " +
      "--allow-no-connect.",
  );
}

if (backgroundInstall) {
  process.on("uncaughtException", (error) => {
    console.error(error);
    alert(`${PRODUCT_NAME} install needs attention`, `${error.message}\n\nLog: ${installLog}`);
    process.exit(1);
  });
} else {
  stopWaitingInstaller();
}

if (!skipBuild) {
  const version = resolveForkVersion();
  NodeFS.rmSync(outputDir, { recursive: true, force: true });
  console.log(`[fork-install] Building ${PRODUCT_NAME} ${version}`);
  run(
    process.execPath,
    [
      NodePath.join(repoRoot, "scripts/build-desktop-artifact.ts"),
      "--platform",
      "mac",
      "--target",
      "dmg",
      "--build-version",
      version,
      "--output-dir",
      outputDir,
    ],
    { env },
  );
}

const zipName = NodeFS.existsSync(outputDir)
  ? NodeFS.readdirSync(outputDir).find((entry) => entry.endsWith(".zip"))
  : undefined;
if (!zipName) {
  throw new Error(`No .zip artifact in ${outputDir}. Run without --skip-build.`);
}

interface ConnectStatus {
  readonly desired: boolean;
  readonly linkMode: string | null;
  readonly reachability:
    | { readonly status: "reachable"; readonly readyConnections: number | null }
    | { readonly status: "unreachable"; readonly reason: string; readonly fix: string }
    | null;
}

function readConnectStatus(installedApp: string): ConnectStatus | null {
  const result = NodeChildProcess.spawnSync(
    NodePath.join(installedApp, "Contents/MacOS", PRODUCT_NAME),
    [
      NodePath.join(installedApp, "Contents/Resources/app.asar/apps/server/dist/bin.mjs"),
      "connect",
      "status",
      "--json",
    ],
    { encoding: "utf8", env: { ...env, ELECTRON_RUN_AS_NODE: "1" }, timeout: 30_000 },
  );
  if (result.status !== 0) return null;
  try {
    return JSON.parse(result.stdout) as ConnectStatus;
  } catch {
    return null;
  }
}

// The background installer has no terminal, so a thrown error alone lands in a log nobody reads.
function alert(title: string, message: string) {
  NodeChildProcess.spawn(
    "osascript",
    [
      "-e",
      "on run argv",
      "-e",
      "display alert (item 1 of argv) message (item 2 of argv) as critical",
      "-e",
      "end run",
      title,
      message,
    ],
    { detached: true, stdio: "ignore" },
  ).unref();
}

// The bundle check proves Connect was compiled in, not that the relaunched app
// brought the saved link back. Wait for the tunnel to answer, as other devices
// would see it. A restart takes about a minute: the old server releases the
// tunnel on quit and the new one re-provisions it.
function assertConnectReachable(installedApp: string) {
  console.log("[fork-install] Waiting for T3 Connect to come back up");
  const deadline = Date.now() + 180_000;
  let status: ConnectStatus | null = null;
  while (Date.now() < deadline) {
    status = readConnectStatus(installedApp);
    if (status?.reachability?.status === "reachable") {
      console.log(
        `[fork-install] T3 Connect is reachable (${status.reachability.readyConnections ?? "?"} connections)`,
      );
      return;
    }
    if (status && (!status.desired || status.linkMode !== "managed")) break;
    NodeChildProcess.spawnSync("sleep", ["5"]);
  }
  const detail =
    status === null
      ? "`t3 connect status` did not answer."
      : !status.desired || status.linkMode !== "managed"
        ? "T3 Connect is turned off on this machine. Turn it on in Settings → Connections."
        : status.reachability?.status === "unreachable"
          ? `${status.reachability.reason} Fix: ${status.reachability.fix}`
          : "The tunnel did not report reachable within 3 minutes.";
  throw new Error(
    `${PRODUCT_NAME} is installed and running, but other devices cannot reach it. ${detail} ` +
      "Pass --allow-no-connect to skip this check.",
  );
}

// pgrep reads its pattern as a regex, where "(Fork)" never matches the literal
// path. -a keeps the app's processes visible when an agent inside it runs this.
function appIsRunning(): boolean {
  const pattern = `${INSTALLED_APP}/Contents/MacOS/`.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return capture("pgrep", ["-a", "-f", pattern]) !== "";
}

function workingAgentTurns(): ReadonlyArray<string> {
  let db: NodeSqlite.DatabaseSync;
  try {
    db = new NodeSqlite.DatabaseSync(STATE_DB, { readOnly: true });
  } catch (error) {
    throw new Error(
      `Could not read agent turns from ${STATE_DB} (${String(error)}). Pass --now to install anyway.`,
      { cause: error },
    );
  }
  try {
    return db
      .prepare(
        `SELECT coalesce(threads.title, runs.thread_id) AS title
           FROM orchestration_v2_projection_runs AS runs
           LEFT JOIN orchestration_v2_projection_threads AS threads USING (thread_id)
          WHERE runs.status IN (${WORKING_RUN_STATUSES.map(() => "?").join(", ")})`,
      )
      .all(...WORKING_RUN_STATUSES)
      .map((row) => String(row.title));
  } finally {
    db.close();
  }
}

// Two quiet checks in a row, because a finished turn can hand straight to a queued one. After
// `limitMs` the install goes ahead anyway; null waits for as long as it takes.
function waitUntilNoAgentIsWorking(limitMs: number | null) {
  const deadline = limitMs === null ? Number.POSITIVE_INFINITY : Date.now() + limitMs;
  let quietChecks = 0;
  let reported = "";
  while (quietChecks < 2 && appIsRunning()) {
    const working = workingAgentTurns();
    quietChecks = working.length === 0 ? quietChecks + 1 : 0;
    if (working.length > 0 && Date.now() >= deadline) {
      console.log(
        `[fork-install] ${formatGrace(limitMs)} grace is up with ${working.length} working agent turn(s); ` +
          "installing anyway. The app continues them after it relaunches.",
      );
      return;
    }
    const summary = working.join(", ");
    if (working.length > 0 && summary !== reported) {
      console.log(`[fork-install] Waiting on ${working.length} working agent turn(s): ${summary}`);
    }
    reported = summary;
    if (quietChecks < 2) NodeChildProcess.spawnSync("sleep", ["5"]);
  }
  console.log("[fork-install] No agent turn is working");
}

interface RestartRecord {
  readonly path: string;
  readonly quitAt: string;
  readonly threads: ReadonlyArray<RestartThread>;
}

function readSettingsFile(): unknown {
  try {
    return JSON.parse(NodeFS.readFileSync(SETTINGS_FILE, "utf8"));
  } catch {
    return {};
  }
}

function threadLabel(thread: RestartThread) {
  return `"${thread.title}"${thread.projectTitle ? ` (${thread.projectTitle})` : ""}`;
}

/**
 * Writes the threads the quit is about to interrupt next to install.log, so a cut turn can be
 * found and checked afterwards. Reading never blocks the install.
 */
function recordRestart(): RestartRecord | null {
  let threads: ReadonlyArray<RestartThread>;
  try {
    const db = new NodeSqlite.DatabaseSync(STATE_DB, { readOnly: true });
    try {
      threads = readRestartThreads(db, readResumeSettings(readSettingsFile()), Date.now());
    } finally {
      db.close();
    }
  } catch (error) {
    console.log(`[fork-install] Could not record working threads: ${String(error)}`);
    return null;
  }
  const quitAt = new Date().toISOString();
  const path = NodePath.join(outputDir, `restart-${quitAt.replace(/[:.]/g, "-")}.json`);
  if (threads.length === 0) return { path, quitAt, threads };
  NodeFS.writeFileSync(path, `${JSON.stringify({ quitAt, threads }, null, 2)}\n`);
  for (const thread of threads) {
    const state = thread.waitingOnUser
      ? "waiting on you, keeps its question"
      : thread.expectedResume === "yes"
        ? "cut short, will be continued"
        : `cut short, will not be continued (${thread.expectedResume})`;
    console.log(`[fork-install] ${threadLabel(thread)}: ${state}`);
  }
  console.log(`[fork-install] Recorded in ${path}`);
  return { path, quitAt, threads };
}

function readOutcomes(threads: ReadonlyArray<RestartThread>): ReadonlyArray<ResumeOutcome> | null {
  try {
    const db = new NodeSqlite.DatabaseSync(STATE_DB, { readOnly: true });
    try {
      return threads.map((thread) => readResumeOutcome(db, thread));
    } finally {
      db.close();
    }
  } catch {
    // The relaunched server may hold the database while it migrates; try again.
    return null;
  }
}

/** After the relaunch, waits for the server to continue each cut turn and reports what it did. */
function reportResumes(record: RestartRecord) {
  const cut = record.threads.filter((thread) => !thread.waitingOnUser);
  if (cut.length === 0) return;
  console.log(`[fork-install] Checking that the app continues ${cut.length} cut turn(s)`);
  const deadline = Date.now() + RESUME_CHECK_MS;
  let outcomes: ReadonlyArray<ResumeOutcome> | null = null;
  while (Date.now() < deadline) {
    NodeChildProcess.spawnSync("sleep", ["5"]);
    outcomes = readOutcomes(cut) ?? outcomes;
    if (outcomes && outcomes.every((outcome) => outcome.kind !== "pending")) break;
  }
  if (!outcomes) {
    console.log(`[fork-install] Could not read the database to check the cut turns.`);
    return;
  }
  const checked = cut.map((thread, index) => ({ ...thread, outcome: outcomes[index]! }));
  NodeFS.writeFileSync(
    record.path,
    `${JSON.stringify({ quitAt: record.quitAt, threads: record.threads, checked }, null, 2)}\n`,
  );
  for (const thread of checked) {
    console.log(`[fork-install] ${threadLabel(thread)}: ${describeOutcome(thread.outcome)}`);
    if (thread.outcome.kind === "not resumed" || thread.outcome.kind === "failed") {
      console.log(
        `[fork-install]   continue it yourself: t3 thread send ${thread.threadId} "Continue where you left off."`,
      );
    }
  }
  const summary = summarizeOutcomes(checked.map((thread) => thread.outcome));
  console.log(`[fork-install] Cut turns: ${summary}`);
  notify(`${PRODUCT_NAME} updated`, `Cut turns: ${summary}. Details: ${record.path}`);
}

function notify(title: string, message: string) {
  NodeChildProcess.spawn(
    "osascript",
    [
      "-e",
      "on run argv",
      "-e",
      "display notification (item 2 of argv) with title (item 1 of argv)",
      "-e",
      "end run",
      title,
      message,
    ],
    { detached: true, stdio: "ignore" },
  ).unref();
}

/** A newer run replaces an installer still waiting from an earlier one. */
function stopWaitingInstaller() {
  if (!NodeFS.existsSync(installerPidFile)) return;
  const pid = Number(NodeFS.readFileSync(installerPidFile, "utf8"));
  if (!Number.isInteger(pid) || pid <= 0) return;
  // The pid was recorded at spawn; check the command so a reused pid is left alone.
  if (!capture("ps", ["-p", String(pid), "-o", "command="]).includes(import.meta.filename)) return;
  process.kill(pid, "SIGTERM");
  console.log(
    `[fork-install] Stopped the installer still waiting from an earlier run (pid ${pid})`,
  );
}

/**
 * Quitting the app ends every agent session and terminal inside it, including
 * one running this script, which could die between removing the old app and
 * copying the new one. A detached process outlives the quit, and without --now
 * it also waits out the turn of the agent that started it.
 */
function installInBackground() {
  const forwarded = args.filter((arg) => arg !== "--skip-build");
  const child = NodeChildProcess.spawn(
    process.execPath,
    [import.meta.filename, "--skip-build", BACKGROUND_INSTALL_FLAG, ...forwarded],
    {
      cwd: repoRoot,
      detached: true,
      stdio: ["ignore", NodeFS.openSync(installLog, "a"), NodeFS.openSync(installLog, "a")],
    },
  );
  child.unref();
  NodeFS.writeFileSync(installerPidFile, String(child.pid));
  console.log(
    graceMs === 0
      ? `[fork-install] Installing from a background process (pid ${child.pid}).`
      : `[fork-install] ${PRODUCT_NAME} is running, so a background process (pid ${child.pid}) ` +
          "installs it once no agent turn is working" +
          (graceMs === null ? "" : `, or after ${formatGrace(graceMs)} at most`) +
          ". Turns waiting on your answer do not hold it up, and the app continues any it cuts short.",
  );
  console.log(`[fork-install] Log: ${installLog}. Cancel: kill ${child.pid}.`);
}

function installBuiltApp(builtApp: string) {
  const identity = resolveSigningIdentity();
  if (identity) {
    console.log(`[fork-install] Signing with "${identity}"`);
    run("codesign", ["--force", "--deep", "--sign", identity, builtApp]);
  } else {
    console.log("[fork-install] No signing identity; keeping the ad-hoc signature.");
  }

  let restart: RestartRecord | null = null;
  if (NodeFS.existsSync(INSTALLED_APP)) {
    if (appIsRunning()) restart = recordRestart();
    console.log(`[fork-install] Quitting the running ${PRODUCT_NAME}`);
    run("osascript", [
      "-e",
      `if application id "${BUNDLE_ID}" is running then tell application id "${BUNDLE_ID}" to quit`,
    ]);
    const deadline = Date.now() + 15_000;
    while (Date.now() < deadline && appIsRunning()) {
      NodeChildProcess.spawnSync("sleep", ["0.5"]);
    }
    if (appIsRunning()) {
      throw new Error(`${PRODUCT_NAME} did not quit; leaving the installed app in place.`);
    }
    NodeFS.rmSync(INSTALLED_APP, { recursive: true, force: true });
  }
  run("ditto", [builtApp, INSTALLED_APP]);
  console.log(`[fork-install] Installed ${INSTALLED_APP}`);

  if (launch) {
    run("open", ["-a", INSTALLED_APP], { env });
    if (restart) reportResumes(restart);
    if (!allowNoConnect) assertConnectReachable(INSTALLED_APP);
  } else if (restart?.threads.some((thread) => !thread.waitingOnUser)) {
    console.log("[fork-install] The app continues the cut turns when it next launches.");
  }
}

if (backgroundInstall && graceMs !== 0) waitUntilNoAgentIsWorking(graceMs);

const extractDir = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "t3code-fork-install-"));
try {
  run("ditto", ["-x", "-k", NodePath.join(outputDir, zipName), extractDir]);
  const appName = NodeFS.readdirSync(extractDir).find((entry) => entry.endsWith(".app"));
  if (!appName) throw new Error(`${zipName} did not contain an .app bundle.`);
  if (appName !== `${PRODUCT_NAME}.app`) {
    throw new Error(
      `Built ${appName}, expected ${PRODUCT_NAME}.app. Is the version a -fork. version?`,
    );
  }
  const builtApp = NodePath.join(extractDir, appName);
  assertConnectCompiledIn(builtApp);
  if (buildOnly) {
    console.log(`[fork-install] Built ${NodePath.join(outputDir, zipName)}; not installing`);
  } else if (!backgroundInstall && appIsRunning()) {
    installInBackground();
  } else {
    installBuiltApp(builtApp);
  }
} finally {
  NodeFS.rmSync(extractDir, { recursive: true, force: true });
}
