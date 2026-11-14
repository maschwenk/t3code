// Usage: node exit-with-parent.mjs <command> [...args]
// Stops the command and everything it started once stdin closes. Spawn it with
// a stdin pipe and `detached: true`: the pipe closes however the parent exits,
// SIGKILL included, which no handler in the parent can cover.
import * as NodeChildProcess from "node:child_process";
import * as NodeOS from "node:os";

// oxlint-disable-next-line t3code/no-global-process-runtime -- Standalone dev script has no Effect runtime.
const hostPlatform = NodeOS.platform();
const [command, ...args] = process.argv.slice(2);

const child = NodeChildProcess.spawn(command, args, { stdio: ["ignore", "inherit", "inherit"] });

function stop() {
  if (hostPlatform === "win32") {
    child.kill();
    process.exit();
  }
  // Signals this process too, so nothing in the group outlives it.
  process.kill(-process.pid, "SIGTERM");
}

child.once("exit", stop);
process.stdin.once("end", stop);
process.stdin.once("error", stop);
process.stdin.resume();
