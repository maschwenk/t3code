#!/usr/bin/env node
// @effect-diagnostics nodeBuiltinImport:off globalDate:off - Release tooling drives eas-cli and xcodebuild as subprocesses.

// T3 Fork TestFlight builds (`testflight`) and over-the-air updates (`update`, `fingerprint`).
// An update reaches only builds with its native fingerprint, which hashes the app config, so both
// run with apps/mobile/fork-release.env and without the shell's app-config variables.

import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeProcess from "node:process";
import * as NodeURL from "node:url";
import * as NodeUtil from "node:util";

const REPO_ROOT = NodePath.resolve(NodePath.dirname(NodeURL.fileURLToPath(import.meta.url)), "..");
const MOBILE_ROOT = NodePath.join(REPO_ROOT, "apps/mobile");
const RELEASE_ENV_FILE = NodePath.join(MOBILE_ROOT, "fork-release.env");
// One tag per TestFlight build: <prefix>/<fingerprint>/<build number>.
const BUILD_TAG_PREFIX = "fork-ios-testflight";
const EAS_CLI = "eas-cli@27.10.0";

// Inherited variables that feed app.config.ts, fingerprint.config.js or the commit stamp.
const APP_CONFIG_VARIABLE =
  /^(T3CODE_|EXPO_PUBLIC_|VITE_|EAS_BUILD_|APP_VARIANT$|MOBILE_VERSION_POLICY$)/;

export function releaseEnvironment(
  inherited: NodeJS.ProcessEnv,
  releaseFile: string,
): NodeJS.ProcessEnv {
  const kept = Object.entries(inherited).filter(([name]) => !APP_CONFIG_VARIABLE.test(name));
  return { ...Object.fromEntries(kept), ...NodeUtil.parseEnv(releaseFile) };
}

function loadReleaseEnvironment(): NodeJS.ProcessEnv {
  // app.config.ts also reads these files, below the environment; their other keys would leak in.
  for (const name of [".env", ".env.local"]) {
    if (NodeFS.existsSync(NodePath.join(REPO_ROOT, name))) {
      throw new Error(
        `Move ${name} out of the repo root: the app config reads it, so this release's fingerprint would differ from CI's.`,
      );
    }
  }
  return releaseEnvironment(NodeProcess.env, NodeFS.readFileSync(RELEASE_ENV_FILE, "utf8"));
}

function run(
  command: string,
  args: ReadonlyArray<string>,
  options: {
    readonly cwd?: string;
    readonly env?: NodeJS.ProcessEnv;
    readonly capture?: boolean;
  } = {},
): string {
  const result = NodeChildProcess.spawnSync(command, args, {
    cwd: options.cwd ?? REPO_ROOT,
    env: options.env ?? NodeProcess.env,
    encoding: "utf8",
    stdio: options.capture ? ["ignore", "pipe", "inherit"] : "inherit",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(" ")} exited with ${result.status ?? result.signal}`);
  }
  return result.stdout ?? "";
}

function fingerprint(env: NodeJS.ProcessEnv): string {
  const output = run("npx", ["expo-updates", "fingerprint:generate", "--platform", "ios"], {
    cwd: MOBILE_ROOT,
    env,
    capture: true,
  });
  const { hash } = JSON.parse(output.slice(output.indexOf("{"))) as { hash?: unknown };
  if (typeof hash !== "string" || hash.length === 0) throw new Error("No fingerprint hash.");
  return hash;
}

function buildTags(hash: string): string[] {
  run("git", [
    "fetch",
    "--quiet",
    "origin",
    `refs/tags/${BUILD_TAG_PREFIX}/*:refs/tags/${BUILD_TAG_PREFIX}/*`,
  ]);
  return run("git", ["tag", "--list", `${BUILD_TAG_PREFIX}/${hash}/*`], { capture: true })
    .split("\n")
    .filter(Boolean);
}

function update(env: NodeJS.ProcessEnv): void {
  if (!NodeProcess.env.EXPO_TOKEN) throw new Error("EXPO_TOKEN is not set.");
  const hash = fingerprint(env);
  const builds = buildTags(hash).map((tag) => tag.split("/").pop());
  const message = `${run("git", ["log", "-1", "--pretty=%s"], { capture: true }).trim().slice(0, 120)} (${run("git", ["rev-parse", "--short=9", "HEAD"], { capture: true }).trim()})`;
  run(
    "npx",
    [
      "--yes",
      EAS_CLI,
      "update",
      "--channel",
      env.T3CODE_MOBILE_UPDATE_CHANNEL ?? "",
      // Required non-interactively; the project defines no EAS environment variables.
      "--environment",
      "production",
      "--platform",
      "ios",
      "--message",
      message,
      "--non-interactive",
    ],
    { cwd: MOBILE_ROOT, env },
  );
  const summary =
    builds.length > 0
      ? `Published to TestFlight build ${builds.join(", ")} (fingerprint \`${hash}\`).`
      : `Published for fingerprint \`${hash}\`, but no TestFlight build has it: this change touched native code. Run \`node scripts/mobile-fork-release.ts testflight\` on a Mac.`;
  NodeProcess.stdout.write(`${summary}\n`);
  if (NodeProcess.env.GITHUB_STEP_SUMMARY) {
    NodeFS.appendFileSync(NodeProcess.env.GITHUB_STEP_SUMMARY, `${summary}\n`);
  }
}

function buildNumber(now: Date): string {
  const pad = (value: number) => String(value).padStart(2, "0");
  return `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}${pad(now.getHours())}${pad(now.getMinutes())}`;
}

function testflight(env: NodeJS.ProcessEnv): void {
  if (run("git", ["status", "--porcelain", "--untracked-files=no"], { capture: true }).trim()) {
    throw new Error(
      "Commit or stash tracked changes first: the build and its tag name this commit.",
    );
  }
  const hash = fingerprint(env);
  const number = buildNumber(new Date());
  const ios = NodePath.join(MOBILE_ROOT, "ios");
  run("npx", ["expo", "prebuild", "--clean", "--platform", "ios"], {
    cwd: MOBILE_ROOT,
    env: { ...env, EXPO_NO_GIT_STATUS: "1" },
  });

  // The app and its extensions must share a build number; prebuild writes some as literals.
  for (const target of NodeFS.readdirSync(ios)) {
    const plist = NodePath.join(ios, target, "Info.plist");
    if (!NodeFS.existsSync(plist)) continue;
    const current = run("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleVersion", plist], {
      capture: true,
    }).trim();
    if (!current.startsWith("$(")) {
      run("/usr/libexec/PlistBuddy", ["-c", `Set :CFBundleVersion ${number}`, plist]);
    }
  }

  const workspace = NodeFS.readdirSync(ios).find((name) => name.endsWith(".xcworkspace"));
  if (!workspace) throw new Error("prebuild made no Xcode workspace.");
  const scheme = workspace.replace(/\.xcworkspace$/, "");
  const scratch = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "t3-fork-release-"));
  const archive = NodePath.join(
    NodeOS.homedir(),
    "Library/Developer/Xcode/Archives",
    new Date().toISOString().slice(0, 10),
    `${scheme}-${number}.xcarchive`,
  );
  run(
    "xcodebuild",
    [
      "-workspace",
      NodePath.join(ios, workspace),
      "-scheme",
      scheme,
      "-configuration",
      "Release",
      "-destination",
      "generic/platform=iOS",
      "-archivePath",
      archive,
      "-derivedDataPath",
      NodePath.join(scratch, "DerivedData"),
      "-allowProvisioningUpdates",
      `CURRENT_PROJECT_VERSION=${number}`,
      "archive",
    ],
    { cwd: MOBILE_ROOT, env },
  );

  // Refuse to ship a build that this commit's updates could not reach.
  const app = NodePath.join(archive, "Products/Applications", `${scheme}.app`);
  const built = NodeFS.readFileSync(
    NodePath.join(app, "EXUpdates.bundle/fingerprint"),
    "utf8",
  ).trim();
  if (built !== hash) {
    throw new Error(`The archive's fingerprint ${built} differs from ${hash}; not uploading.`);
  }

  const exportOptions = NodePath.join(scratch, "ExportOptions.plist");
  NodeFS.writeFileSync(
    exportOptions,
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>${env.T3CODE_IOS_TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
`,
  );
  run("xcodebuild", [
    "-exportArchive",
    "-archivePath",
    archive,
    "-exportOptionsPlist",
    exportOptions,
    "-exportPath",
    NodePath.join(scratch, "export"),
    "-allowProvisioningUpdates",
  ]);

  const tag = `${BUILD_TAG_PREFIX}/${hash}/${number}`;
  const commit = run("git", ["rev-parse", "HEAD"], { capture: true }).trim();
  run("git", ["tag", "--annotate", tag, "--message", `TestFlight build ${number} from ${commit}`]);
  run("git", ["push", "origin", `refs/tags/${tag}`]);
  NodeProcess.stdout.write(
    `Uploaded TestFlight build ${number} (fingerprint ${hash}) and pushed ${tag}.\n`,
  );
}

if (import.meta.main) {
  const command = NodeProcess.argv[2];
  const env = loadReleaseEnvironment();
  if (command === "fingerprint") NodeProcess.stdout.write(`${fingerprint(env)}\n`);
  else if (command === "update") update(env);
  else if (command === "testflight") testflight(env);
  else {
    NodeProcess.stderr.write(
      "Usage: node scripts/mobile-fork-release.ts <testflight|update|fingerprint>\n",
    );
    NodeProcess.exit(1);
  }
}
