import * as NodeChildProcess from "node:child_process";
import * as NodeEvents from "node:events";
import * as NodeOS from "node:os";
import * as NodeURL from "node:url";

import { assert, it } from "vite-plus/test";

const guardPath = NodeURL.fileURLToPath(new URL("./exit-with-parent.mjs", import.meta.url));

// Starts the guard the way dev-electron.mjs does, then a long-lived sibling that
// stands in for the app and does not share the test's stdout.
const parentSource = `
const { spawn } = require("node:child_process");
const [guardPath, watcherSource] = process.argv.slice(1);
const guard = spawn(process.execPath, [guardPath, process.execPath, "-e", watcherSource], {
  stdio: ["pipe", "inherit", "inherit"],
  detached: true,
});
const sibling = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
console.log(JSON.stringify({ guard: guard.pid, sibling: sibling.pid }));
setInterval(() => {}, 1000);
`;
// Like vp, which runs the real watcher as its own child. Both keep the test's
// stdout open, so it ends only once both have exited.
const watcherSource = `
const { spawn } = require("node:child_process");
const inner = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "inherit" });
console.log(JSON.stringify({ watcher: [process.pid, inner.pid] }));
setInterval(() => {}, 1000);
`;

function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

it
  // oxlint-disable-next-line t3code/no-global-process-runtime -- Process groups and SIGKILL are POSIX-only.
  .skipIf(NodeOS.platform() === "win32")(
  "exit-with-parent stops the command and its children when the parent is SIGKILLed",
  async ({ onTestFinished }) => {
    const parent = NodeChildProcess.spawn(
      process.execPath,
      ["-e", parentSource, guardPath, watcherSource],
      { stdio: ["ignore", "pipe", "inherit"] },
    );
    const pids = {};
    // Runs after a timeout too, so a regression cannot leave the fixtures running.
    onTestFinished(() => {
      parent.kill("SIGKILL");
      parent.stdout.destroy();
      for (const target of [-pids.guard, pids.sibling]) {
        try {
          process.kill(target, "SIGKILL");
        } catch {
          // Never started, or already gone.
        }
      }
    });
    const started = Promise.withResolvers();
    let output = "";
    parent.stdout.setEncoding("utf8");
    parent.stdout.on("data", (chunk) => {
      output += chunk;
      const lines = output.split("\n");
      output = lines.pop();
      for (const line of lines) Object.assign(pids, JSON.parse(line));
      if (pids.watcher !== undefined && pids.sibling !== undefined) started.resolve();
    });
    const stdoutClosed = NodeEvents.once(parent.stdout, "end");
    await started.promise;

    parent.kill("SIGKILL");

    // Ends once the watcher and its child have exited; a leak times out here.
    await stdoutClosed;
    // The sibling started after the guard, so it never held the guard's pipe.
    assert.isTrue(isAlive(pids.sibling));
  },
);
