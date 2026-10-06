import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

import {
  desktopDir,
  isDevAppMainProcess,
  resolveMacLauncherPaths,
  resolveDevProtocolClient,
  resolveElectronLaunchCommand,
} from "./electron-launcher.mjs";
import { waitForResources } from "./wait-for-resources.mjs";
import { createLaunchLimiter } from "./launch-limiter.mjs";

const devServerUrl = process.env.VITE_DEV_SERVER_URL?.trim();
if (!devServerUrl) {
  throw new Error("VITE_DEV_SERVER_URL is required for desktop development.");
}

const devServer = new URL(devServerUrl);
const port = Number.parseInt(devServer.port, 10);
if (!Number.isInteger(port) || port <= 0) {
  throw new Error(`VITE_DEV_SERVER_URL must include an explicit port: ${devServerUrl}`);
}

const requiredFiles = [
  "dist-electron/main.cjs",
  "dist-electron/electron/WindowsForegroundFocusWorker.cjs",
  "dist-electron/preload.cjs",
  "dist-electron/snapShot/GlobalShiftShortcutWorker.cjs",
  "dist-electron/snapShot/RegionSnapShotWorker.cjs",
  "dist-electron/snapShot/SnapShotAccessibilityWorker.cjs",
  "../server/dist/bin.mjs",
];
const runtimeDir = NodePath.join(desktopDir, ".electron-runtime");
const runnerPidPath = NodePath.join(runtimeDir, "dev-runner.pid");
// The server bundle is not watched here: the desktop main restarts only its
// backend when the bundle changes. A relaunch request comes from a copy of the
// bundle that macOS started without this runner (see src/main.ts).
const watchedDirectories = [
  { directory: "dist-electron", files: new Set(["main.cjs", "preload.cjs"]) },
  {
    directory: "dist-electron/electron",
    files: new Set(["WindowsForegroundFocusWorker.cjs"]),
  },
  {
    directory: "dist-electron/snapShot",
    files: new Set([
      "GlobalShiftShortcutWorker.cjs",
      "RegionSnapShotWorker.cjs",
      "SnapShotAccessibilityWorker.cjs",
    ]),
  },
  { directory: ".electron-runtime", files: new Set(["relaunch-request"]) },
];
const forcedShutdownTimeoutMs = 1_500;
const restartDebounceMs = 120;
const childTreeGracePeriodMs = 1_200;
const remoteDebuggingPort = process.env.T3CODE_DESKTOP_REMOTE_DEBUGGING_PORT?.trim();
// oxlint-disable-next-line t3code/no-global-process-runtime -- Standalone dev script has no Effect runtime.
const hostPlatform = NodeOS.platform();

NodeChildProcess.execFileSync(
  process.execPath,
  [NodePath.join(desktopDir, "scripts/build-browser-secret.mjs")],
  { stdio: "inherit" },
);

await waitForResources({
  baseDir: desktopDir,
  files: requiredFiles,
  tcpHost: devServer.hostname,
  tcpPort: port,
});

const childEnv = { ...process.env };
delete childEnv.ELECTRON_RUN_AS_NODE;
const devProtocolClient = resolveDevProtocolClient();
if (devProtocolClient) {
  childEnv.T3CODE_DESKTOP_APP_USER_MODEL_ID = devProtocolClient.appBundleId;
  childEnv.T3CODE_DESKTOP_PROTOCOL_REGISTRATION_MANAGED = "1";
}
const electronExecutablePath = resolveElectronLaunchCommand().electronPath;
// The launcher script is not what runs: LaunchServices starts the bundle's own
// Electron executable, so that is the path to look for.
const appExecutablePaths = [
  electronExecutablePath,
  ...(devProtocolClient
    ? [resolveMacLauncherPaths(devProtocolClient.appBundlePath).runtimeElectronBinaryPath]
    : []),
];
// Marks an instance this runner started; src/main.ts hands any other copy of
// the bundle over to the runner instead of letting it fight for the backend port.
const runnerChildArgument = "--t3code-dev-runner-child";
// macOS attributes Accessibility and Screen Recording to the app that
// *launched* a process, not to the process itself. Spawned directly, the app
// would inherit whatever terminal or tool started this runner and lose the
// T3 Code (Dev) grant. Launched through LaunchServices it is its own app.
const launchedThroughLaunchServices = hostPlatform === "darwin" && devProtocolClient !== null;
const appLogPath = NodePath.join(NodePath.dirname(runnerPidPath), "dev-app.log");
// A runner restarts the app for edits and relaunch requests. Several launches
// in a few seconds means something is looping, so stop rather than keep opening apps.
const launchLimiter = createLaunchLimiter({ max: 4, windowMs: 30_000 });
const mainBundlePath = NodePath.join(desktopDir, "dist-electron", "main.cjs");

NodeFS.mkdirSync(runtimeDir, { recursive: true });
NodeFS.writeFileSync(runnerPidPath, String(process.pid));

// Rebuild the server bundle on every server edit (about a second).
// --no-clean keeps old chunks in place so the running backend can still load
// them until the desktop main restarts it on the new bundle.
const serverDir = NodePath.join(desktopDir, "../server");
const serverWatch = NodeChildProcess.spawn(
  NodePath.join(serverDir, "node_modules/.bin/vp"),
  ["pack", "--watch", "--no-clean", "--logLevel", "warn"],
  {
    cwd: serverDir,
    env: process.env,
    stdio: ["ignore", "inherit", "inherit"],
    // vp runs the real watcher as its own child, so give the pair a process
    // group that shutdown can signal as a whole.
    detached: hostPlatform !== "win32",
  },
);

function stopServerWatch(signal) {
  try {
    if (hostPlatform !== "win32" && serverWatch.pid !== undefined) {
      process.kill(-serverWatch.pid, signal);
    } else {
      serverWatch.kill(signal);
    }
  } catch {
    // Already exited.
  }
}

let shuttingDown = false;
let restartTimer = null;
let currentApp = null;
let restartQueue = Promise.resolve();
const expectedExits = new WeakSet();
const watchers = [];

function killChildTreeByPid(pid, signal) {
  if (hostPlatform === "win32" || typeof pid !== "number") {
    return;
  }

  NodeChildProcess.spawnSync("pkill", [`-${signal}`, "-P", String(pid)], { stdio: "ignore" });
}

function cleanupStaleDevApps(signal = "TERM") {
  if (hostPlatform === "win32") {
    return;
  }

  NodeChildProcess.spawnSync(
    "pkill",
    [`-${signal}`, "-f", "--", `--t3code-dev-root=${desktopDir}`],
    {
      stdio: "ignore",
    },
  );

  for (const pid of runningDevAppPids()) {
    try {
      process.kill(pid, `SIG${signal}`);
    } catch {
      // Already gone.
    }
  }
}

/**
 * Main processes of this bundle's app. Copies launched through macOS carry no
 * --t3code-dev-root argument (the bundle adds it in JavaScript), so they are
 * found by executable instead.
 */
function runningDevAppPids() {
  if (hostPlatform === "win32") {
    return [];
  }
  const processes = NodeChildProcess.spawnSync("ps", ["-axo", "pid=,command="], {
    encoding: "utf8",
  });
  const pids = [];
  for (const line of processes.stdout?.split("\n") ?? []) {
    const match = /^\s*(\d+)\s+(.*)$/.exec(line);
    const command = match?.[2]?.trim();
    if (command === undefined || !isDevAppMainProcess(command, appExecutablePaths)) continue;
    const pid = Number(match[1]);
    if (pid !== currentApp?.pid) pids.push(pid);
  }
  return pids;
}

/**
 * Stops the instances of this bundle's app that exist now and waits until they
 * are gone. Instances started afterwards, by a newer runner, are left alone.
 */
async function stopRunningDevApps() {
  const targets = runningDevAppPids();
  const signalTargets = (signal) => {
    for (const pid of targets) {
      try {
        process.kill(pid, signal);
      } catch {
        // Already gone.
      }
    }
  };
  const anyAlive = () =>
    targets.some((pid) => {
      try {
        process.kill(pid, 0);
        return true;
      } catch {
        return false;
      }
    });
  signalTargets("SIGTERM");
  const deadline = Date.now() + forcedShutdownTimeoutMs;
  while (anyAlive() && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  if (anyAlive()) {
    signalTargets("SIGKILL");
    await new Promise((resolve) => setTimeout(resolve, 300));
  }
}

function startApp() {
  if (shuttingDown || currentApp !== null) {
    return;
  }

  // src/main.ts hands any copy of the bundle without this marker over to the
  // runner. A bundle built before that check exists would hand over the
  // runner's own app, over and over, so refuse to start one.
  if (!NodeFS.readFileSync(mainBundlePath, "utf8").includes(runnerChildArgument)) {
    console.error(
      "[dev-electron] dist-electron/main.cjs does not know the runner handshake; not launching the app until it is rebuilt.",
    );
    return;
  }
  if (!launchLimiter.tryLaunch()) {
    console.error("[dev-electron] the app was launched too often in a short time; stopping.");
    void shutdown(1);
    return;
  }

  const electronArgs = remoteDebuggingPort
    ? [`--remote-debugging-port=${remoteDebuggingPort}`]
    : [];
  if (launchedThroughLaunchServices) {
    // LaunchServices launches are not children of this process, so a leftover
    // instance would survive and a second one would pile up beside it.
    if (runningDevAppPids().length > 0) {
      console.error("[dev-electron] a dev app instance is still running; not launching another.");
      return;
    }
    // -n starts a new instance and -W waits for it, so this process lives
    // exactly as long as the app. The app's output goes to a file because
    // LaunchServices does not give it this terminal.
    const app = NodeChildProcess.spawn(
      "open",
      [
        "-n",
        "-W",
        "-a",
        devProtocolClient.appBundlePath,
        "--stdout",
        appLogPath,
        "--stderr",
        appLogPath,
        "--args",
        runnerChildArgument,
        ...electronArgs,
      ],
      { cwd: desktopDir, stdio: "ignore" },
    );
    currentApp = app;
    app.once("error", () => {
      if (currentApp === app) currentApp = null;
    });
    // No restart on exit: a quit app stays quit, and `open` cannot tell a crash
    // from a quit. An edit or a relaunch request starts it again.
    app.once("exit", () => {
      if (currentApp === app) currentApp = null;
    });
    return;
  }
  const launchArgs = [
    runnerChildArgument,
    ...electronArgs,
    `--t3code-dev-root=${desktopDir}`,
    "dist-electron/main.cjs",
  ];
  const electronCommand = resolveElectronLaunchCommand(launchArgs);
  const app = NodeChildProcess.spawn(electronCommand.electronPath, electronCommand.args, {
    cwd: desktopDir,
    env: childEnv,
    stdio: "inherit",
  });

  currentApp = app;

  app.once("error", () => {
    if (currentApp === app) {
      currentApp = null;
    }

    if (!shuttingDown) {
      scheduleRestart();
    }
  });

  app.once("exit", (code, signal) => {
    if (currentApp === app) {
      currentApp = null;
    }

    const exitedAbnormally = signal !== null || code !== 0;
    if (!shuttingDown && !expectedExits.has(app) && exitedAbnormally) {
      scheduleRestart();
    }
  });
}

async function stopApp() {
  const app = currentApp;
  if (launchedThroughLaunchServices) {
    // Stopping `open` would not stop the app it launched, so stop the app
    // itself and wait for it, even when `open` has already exited.
    currentApp = null;
    await stopRunningDevApps();
    app?.kill("SIGTERM");
    return;
  }

  if (!app) {
    return;
  }

  currentApp = null;
  expectedExits.add(app);

  await new Promise((resolve) => {
    let settled = false;

    const finish = () => {
      if (settled) {
        return;
      }

      settled = true;
      resolve();
    };

    app.once("exit", finish);
    app.kill("SIGTERM");
    killChildTreeByPid(app.pid, "TERM");
    cleanupStaleDevApps();

    setTimeout(() => {
      if (settled) {
        return;
      }

      app.kill("SIGKILL");
      killChildTreeByPid(app.pid, "KILL");
      cleanupStaleDevApps("KILL");
      finish();
    }, forcedShutdownTimeoutMs).unref();
  });
}

function scheduleRestart() {
  if (shuttingDown) {
    return;
  }

  if (restartTimer) {
    clearTimeout(restartTimer);
  }

  restartTimer = setTimeout(() => {
    restartTimer = null;
    restartQueue = restartQueue
      .catch(() => undefined)
      .then(async () => {
        await stopApp();
        if (!shuttingDown) {
          startApp();
        }
      });
  }, restartDebounceMs);
}

function startWatchers() {
  for (const { directory, files } of watchedDirectories) {
    const watcher = NodeFS.watch(
      NodePath.join(desktopDir, directory),
      { persistent: true },
      (_eventType, filename) => {
        if (typeof filename !== "string" || !files.has(filename)) {
          return;
        }

        scheduleRestart();
      },
    );

    watchers.push(watcher);
  }
}

function killChildTree(signal) {
  if (hostPlatform === "win32") {
    return;
  }

  // Kill direct children as a final fallback in case normal shutdown leaves stragglers.
  NodeChildProcess.spawnSync("pkill", [`-${signal}`, "-P", String(process.pid)], {
    stdio: "ignore",
  });
}

async function shutdown(exitCode) {
  if (shuttingDown) return;
  shuttingDown = true;

  if (restartTimer) {
    clearTimeout(restartTimer);
    restartTimer = null;
  }

  for (const watcher of watchers) {
    watcher.close();
  }

  stopServerWatch("SIGTERM");
  // When the pack watcher restarts this script, the new runner takes over the
  // pid file and the app. Stopping it here could close the app it just started.
  let supersededByNewerRunner = false;
  try {
    const owner = NodeFS.readFileSync(runnerPidPath, "utf8");
    supersededByNewerRunner = owner !== String(process.pid);
    if (!supersededByNewerRunner) {
      NodeFS.rmSync(runnerPidPath);
    }
  } catch {
    // Another runner replaced or removed it.
  }
  if (!(launchedThroughLaunchServices && supersededByNewerRunner)) {
    await stopApp();
  } else {
    currentApp?.kill("SIGTERM");
  }
  killChildTree("TERM");
  await new Promise((resolve) => {
    setTimeout(resolve, childTreeGracePeriodMs);
  });
  killChildTree("KILL");
  stopServerWatch("SIGKILL");

  process.exit(exitCode);
}

startWatchers();
if (launchedThroughLaunchServices) {
  await stopRunningDevApps();
} else {
  cleanupStaleDevApps();
}
startApp();

process.once("SIGINT", () => {
  void shutdown(130);
});
process.once("SIGTERM", () => {
  void shutdown(143);
});
process.once("SIGHUP", () => {
  void shutdown(129);
});
