// @effect-diagnostics nodeBuiltinImport:off globalDate:off globalConsole:off - Dependency-free host-side installer with no Effect runtime, like setup-worktree.ts.
/**
 * Build this checkout as a personal "T3 Code (Fork)" desktop app and install
 * it into /Applications, replacing the previous fork build.
 *
 * The build is versioned `<version>-fork.<yyyymmdd>.<sha>`, which gives it its
 * own product name and bundle id (see resolveDesktopAppId in
 * build-desktop-artifact.ts) and no update feed, so it coexists with a stable
 * install and nothing can replace it with an upstream release.
 *
 *   node scripts/install-fork-desktop.ts [--no-launch] [--skip-build | --build-only]
 *                                        [--identity <codesign name>|none]
 *                                        [--allow-no-connect]
 *
 * `--build-only` then `--skip-build` splits this in two, so an agent running
 * inside the fork can build while the app is still open and install from a
 * detached script.
 *
 * T3 Connect's public identifiers are compiled into the bundle. When neither
 * the shell nor `.env`/`.env.local` sets them, the build takes them from
 * `.env.example` (the values official releases ship), and the install refuses
 * a bundle without them unless `--allow-no-connect` is passed. Otherwise a
 * fresh checkout silently builds an app with no Connect settings and no relay
 * route for other devices. After launching, it also waits for the relaunched
 * app to report T3 Connect reachable, and fails with a macOS alert if it does
 * not.
 *
 * macOS only (it relies on ditto, codesign, open, and security). When an
 * "Apple Development" identity is in the keychain the app
 * is signed with it so Keychain and TCC grants survive rebuilds; ad-hoc signed
 * builds re-prompt after every install because their signature changes.
 */
import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeUtil from "node:util";

import { loadRepoEnv } from "./lib/public-config.ts";

const PRODUCT_NAME = "T3 Code (Fork)";
const BUNDLE_ID = "com.t3tools.t3code.fork";
const APPLICATIONS_DIR = "/Applications";
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
  const match = /"(Apple Development: [^"]+)"/.exec(identities);
  return match?.[1];
}

const outputDir = NodePath.join(repoRoot, "release", "fork");

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

// An install usually runs from a detached script after the agent that started
// it quit with the app, so a thrown error alone lands in a log nobody reads.
function alertConnectDown(message: string) {
  NodeChildProcess.spawn(
    "osascript",
    [
      "-e",
      "on run argv",
      "-e",
      'display alert "T3 Connect is not running" message (item 1 of argv) as critical',
      "-e",
      "end run",
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
  const message = `${PRODUCT_NAME} is installed and running, but other devices cannot reach it. ${detail}`;
  alertConnectDown(message);
  throw new Error(`${message} Pass --allow-no-connect to skip this check.`);
}

function installBuiltApp(builtApp: string) {
  const identity = resolveSigningIdentity();
  if (identity) {
    console.log(`[fork-install] Signing with "${identity}"`);
    run("codesign", ["--force", "--deep", "--sign", identity, builtApp]);
  } else {
    console.log("[fork-install] No signing identity; keeping the ad-hoc signature.");
  }

  const installedApp = NodePath.join(APPLICATIONS_DIR, NodePath.basename(builtApp));
  if (NodeFS.existsSync(installedApp)) {
    console.log(`[fork-install] Quitting the running ${PRODUCT_NAME}`);
    run("osascript", [
      "-e",
      `if application id "${BUNDLE_ID}" is running then tell application id "${BUNDLE_ID}" to quit`,
    ]);
    const deadline = Date.now() + 15_000;
    while (Date.now() < deadline && capture("pgrep", ["-f", installedApp]) !== "") {
      NodeChildProcess.spawnSync("sleep", ["0.5"]);
    }
    if (capture("pgrep", ["-f", installedApp]) !== "") {
      throw new Error(`${PRODUCT_NAME} did not quit; leaving the installed app in place.`);
    }
    NodeFS.rmSync(installedApp, { recursive: true, force: true });
  }
  run("ditto", [builtApp, installedApp]);
  console.log(`[fork-install] Installed ${installedApp}`);

  if (launch) {
    run("open", ["-a", installedApp], { env });
    if (!allowNoConnect) assertConnectReachable(installedApp);
  }
}

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
  } else {
    installBuiltApp(builtApp);
  }
} finally {
  NodeFS.rmSync(extractDir, { recursive: true, force: true });
}
