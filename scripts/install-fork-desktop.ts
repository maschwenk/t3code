// @effect-diagnostics nodeBuiltinImport:off - standalone installer, kept dependency-free like setup-worktree.ts.
/**
 * Build this checkout as a personal "T3 Code (Fork)" desktop app and install
 * it into /Applications, replacing the previous fork build.
 *
 * The build is versioned `<version>-fork.<yyyymmdd>.<sha>`, which gives it its
 * own product name and bundle id (see resolveDesktopAppId in
 * build-desktop-artifact.ts) and no update feed, so it coexists with a stable
 * install and nothing can replace it with an upstream release.
 *
 *   node scripts/install-fork-desktop.ts [--no-launch] [--skip-build]
 *                                        [--identity <codesign name>|none]
 *
 * macOS only. When an "Apple Development" identity is in the keychain the app
 * is signed with it so Keychain and TCC grants survive rebuilds; ad-hoc signed
 * builds re-prompt after every install because their signature changes.
 */
import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

const PRODUCT_NAME = "T3 Code (Fork)";
const BUNDLE_ID = "com.t3tools.t3code.fork";
const APPLICATIONS_DIR = "/Applications";

if (process.platform !== "darwin") {
  throw new Error("install-fork-desktop.ts only supports macOS.");
}

const repoRoot = NodePath.dirname(import.meta.dirname);
const args = process.argv.slice(2);
const launch = !args.includes("--no-launch");
const skipBuild = args.includes("--skip-build");
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

if (!skipBuild) {
  const version = resolveForkVersion();
  NodeFS.rmSync(outputDir, { recursive: true, force: true });
  // A configured update repository would stamp an update feed into the build.
  const env = { ...process.env };
  delete env.T3CODE_DESKTOP_UPDATE_REPOSITORY;
  delete env.GITHUB_REPOSITORY;
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

  const identity = resolveSigningIdentity();
  if (identity) {
    console.log(`[fork-install] Signing with "${identity}"`);
    run("codesign", ["--force", "--deep", "--sign", identity, builtApp]);
  } else {
    console.log("[fork-install] No signing identity; keeping the ad-hoc signature.");
  }

  const installedApp = NodePath.join(APPLICATIONS_DIR, appName);
  if (NodeFS.existsSync(installedApp)) {
    console.log(`[fork-install] Quitting the running ${PRODUCT_NAME}`);
    NodeChildProcess.spawnSync("osascript", ["-e", `tell application id "${BUNDLE_ID}" to quit`]);
    const deadline = Date.now() + 15_000;
    while (Date.now() < deadline && capture("pgrep", ["-f", installedApp]) !== "") {
      NodeChildProcess.spawnSync("sleep", ["0.5"]);
    }
    NodeFS.rmSync(installedApp, { recursive: true, force: true });
  }
  run("ditto", [builtApp, installedApp]);
  console.log(`[fork-install] Installed ${installedApp}`);

  if (launch) {
    run("open", ["-a", installedApp]);
  }
} finally {
  NodeFS.rmSync(extractDir, { recursive: true, force: true });
}
