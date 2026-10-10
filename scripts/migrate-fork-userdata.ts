// @effect-diagnostics nodeBuiltinImport:off - standalone one-shot tool, kept dependency-free like setup-worktree.ts.
/**
 * Move a dev server's T3 home (its `.t3/userdata`) under `~/.t3`, where an
 * installed desktop build looks for it. One-time cutover from running the dev
 * runner as the daily app to running an installed fork build
 * (scripts/install-fork-desktop.ts).
 *
 *   node scripts/migrate-fork-userdata.ts [--from <t3 home>] [--to <t3 home>]
 *
 * `--from` defaults to the main checkout's `.t3`, `--to` to `~/.t3`. Refuses to
 * run while something holds the source database open, renames the existing
 * destination userdata aside instead of deleting it, and skips server logs.
 * Claude config directories are outside the T3 home and are not touched.
 */
import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

const repoRoot = NodePath.dirname(import.meta.dirname);
const args = process.argv.slice(2);

function flagValue(name: string): string | undefined {
  const index = args.indexOf(name);
  if (index === -1) return undefined;
  const value = args[index + 1];
  if (!value) throw new Error(`${name} needs a path.`);
  return NodePath.resolve(value);
}

function mainCheckout(): string {
  const commonDir = NodeChildProcess.spawnSync(
    "git",
    ["rev-parse", "--path-format=absolute", "--git-common-dir"],
    {
      cwd: repoRoot,
      encoding: "utf8",
    },
  );
  if (commonDir.status !== 0) throw new Error("Not inside a git checkout; pass --from.");
  return NodePath.dirname(commonDir.stdout.trim());
}

const from = flagValue("--from") ?? NodePath.join(mainCheckout(), ".t3");
const to = flagValue("--to") ?? NodePath.join(NodeOS.homedir(), ".t3");
const sourceUserdata = NodePath.join(from, "userdata");
const destinationUserdata = NodePath.join(to, "userdata");

if (!NodeFS.existsSync(NodePath.join(sourceUserdata, "statev2.sqlite"))) {
  throw new Error(`${sourceUserdata} has no statev2.sqlite; nothing to migrate.`);
}
if (NodePath.resolve(from) === NodePath.resolve(to)) {
  throw new Error("--from and --to are the same directory.");
}

const openHandles = NodeChildProcess.spawnSync(
  "lsof",
  ["-t", NodePath.join(sourceUserdata, "statev2.sqlite")],
  {
    encoding: "utf8",
  },
);
if (openHandles.stdout.trim() !== "") {
  throw new Error(
    `Processes ${openHandles.stdout.trim().split("\n").join(", ")} still have ${sourceUserdata} open. Quit the dev app first.`,
  );
}

NodeFS.mkdirSync(to, { recursive: true });
if (NodeFS.existsSync(destinationUserdata)) {
  const backup = `${destinationUserdata}.backup-${new Date().toISOString().replaceAll(":", "-")}`;
  NodeFS.renameSync(destinationUserdata, backup);
  console.log(`[fork-migrate] Moved the existing ${destinationUserdata} to ${backup}`);
}

// Everything the app needs lives in userdata: settings and provider
// instances (settings.json), client and desktop settings, keybindings,
// themes, the thread database, attachments, browser extensions, and the
// mode-0600 secrets, which are raw bytes rather than app-bound ciphertext.
// Server logs are the one large directory nothing reads back.
const copy = NodeChildProcess.spawnSync(
  "rsync",
  ["-a", "--exclude", "logs/", `${sourceUserdata}/`, `${destinationUserdata}/`],
  { stdio: "inherit" },
);
if (copy.status !== 0) throw new Error(`rsync exited with ${copy.status ?? "signal"}.`);
console.log(`[fork-migrate] Copied ${sourceUserdata} to ${destinationUserdata} (without logs)`);

// Downloaded tool binaries (headless Chrome) are large and re-fetchable; carry
// them over only when the destination has none.
const sourceTools = NodePath.join(from, "tools");
const destinationTools = NodePath.join(to, "tools");
if (NodeFS.existsSync(sourceTools) && !NodeFS.existsSync(destinationTools)) {
  const copyTools = NodeChildProcess.spawnSync("ditto", [sourceTools, destinationTools], {
    stdio: "inherit",
  });
  if (copyTools.status === 0)
    console.log(`[fork-migrate] Copied ${sourceTools} to ${destinationTools}`);
}

// Provider instances point at Claude config directories by path, outside the
// T3 home. Show them so a missing one is obvious before the first launch.
const settingsPath = NodePath.join(destinationUserdata, "settings.json");
if (NodeFS.existsSync(settingsPath)) {
  const settings = JSON.parse(NodeFS.readFileSync(settingsPath, "utf8")) as {
    providerInstances?: Record<string, { driver?: string; config?: { homePath?: string } }>;
  };
  for (const [id, instance] of Object.entries(settings.providerInstances ?? {})) {
    const homePath = instance.config?.homePath?.trim();
    if (!homePath) {
      console.log(`[fork-migrate] provider ${id} (${instance.driver ?? "?"}): default config dir`);
      continue;
    }
    const resolved = homePath.startsWith("~/")
      ? NodePath.join(NodeOS.homedir(), homePath.slice(2))
      : homePath;
    const status = NodeFS.existsSync(resolved) ? "ok" : "MISSING";
    console.log(`[fork-migrate] provider ${id} (${instance.driver ?? "?"}): ${resolved} ${status}`);
  }
}

console.log(`[fork-migrate] Done. The source at ${sourceUserdata} was left in place.`);
