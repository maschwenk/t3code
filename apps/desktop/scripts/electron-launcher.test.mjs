import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeChildProcess from "node:child_process";

import { assert, describe, it } from "vite-plus/test";

import {
  makeDevelopmentEnvironmentScript,
  makeDevelopmentBootstrap,
  isDevAppMainProcess,
  makeDevelopmentLauncherScript,
  resolveElectronBinaryPath,
  resolveMacBundleInfoPlistStrings,
  resolveMacCodeSignArguments,
  resolveMacLauncherIconPaths,
  resolveMacLauncherPaths,
  writeDevelopmentLauncherScript,
} from "./electron-launcher.mjs";

describe("electron development launcher", () => {
  it("recognizes only the main process of this bundle's app", () => {
    const executable =
      "/work/t3code/apps/desktop/.electron-runtime/T3 Code (Dev).app/Contents/MacOS/Electron";
    const paths = [executable];
    assert.equal(isDevAppMainProcess(executable, paths), true);
    assert.equal(isDevAppMainProcess(`${executable} --t3code-dev-runner-child`, paths), true);
    // The backend child runs the same executable on the server entry.
    assert.equal(
      isDevAppMainProcess(
        `${executable} /work/t3code/apps/server/dist/bin.mjs --bootstrap-fd 3`,
        paths,
      ),
      false,
    );
    assert.equal(
      isDevAppMainProcess(
        "/work/t3code/apps/desktop/.electron-runtime/T3 Code (Dev).app/Contents/Frameworks/Electron Helper.app/Contents/MacOS/Electron Helper --type=gpu-process",
        paths,
      ),
      false,
    );
    assert.equal(
      isDevAppMainProcess(
        "/other/t3code/apps/desktop/.electron-runtime/T3 Code (Dev).app/Contents/MacOS/Electron",
        paths,
      ),
      false,
    );
  });

  it("boots without shell arguments and preserves the live runner environment", () => {
    const directory = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "t3-bootstrap-"));
    try {
      const environmentFilePath = NodePath.join(directory, "env.json");
      const mainEntryPath = NodePath.join(directory, "main.cjs");
      const bootstrapPath = NodePath.join(directory, "index.cjs");
      NodeFS.writeFileSync(
        environmentFilePath,
        JSON.stringify({ T3_TEST_LIVE: "fallback", T3_TEST_FALLBACK: "from file" }),
      );
      NodeFS.writeFileSync(
        mainEntryPath,
        "process.stdout.write(JSON.stringify({ live: process.env.T3_TEST_LIVE, fallback: process.env.T3_TEST_FALLBACK, args: process.argv.slice(2) }));",
      );
      NodeFS.writeFileSync(
        bootstrapPath,
        makeDevelopmentBootstrap({ mainEntryPath, desktopRoot: directory, environmentFilePath }),
      );
      const result = NodeChildProcess.spawnSync(
        process.execPath,
        [bootstrapPath, "t3code-dev://test"],
        { env: { ...process.env, T3_TEST_LIVE: "runner", T3_TEST_FALLBACK: "" }, encoding: "utf8" },
      );
      assert.equal(result.status, 0, result.stderr);
      assert.deepEqual(JSON.parse(result.stdout), {
        live: "runner",
        fallback: "from file",
        args: ["t3code-dev://test", `--t3code-dev-root=${directory}`],
      });
    } finally {
      NodeFS.rmSync(directory, { recursive: true, force: true });
    }
  });
  it("uses captured values only as fallbacks for a live runner environment", () => {
    const environmentScript = makeDevelopmentEnvironmentScript({
      VITE_DEV_SERVER_URL: "http://127.0.0.1:8526",
      T3CODE_PORT: "16566",
      T3CODE_HOME: "/tmp/t3",
      T3CODE_OTLP_PROTOCOL: "http/protobuf",
    });

    assert.include(
      environmentScript,
      "if [ -z \"${VITE_DEV_SERVER_URL:-}\" ]; then export VITE_DEV_SERVER_URL='http://127.0.0.1:8526'; fi",
    );
    assert.include(
      environmentScript,
      "if [ -z \"${T3CODE_OTLP_PROTOCOL:-}\" ]; then export T3CODE_OTLP_PROTOCOL='http/protobuf'; fi",
    );
    assert.notInclude(environmentScript, "\nexport VITE_DEV_SERVER_URL=");
  });

  it("keeps the launcher script free of volatile environment values", () => {
    const script = makeDevelopmentLauncherScript({
      electronBinaryPath: "/repo/node_modules/electron/Electron",
      mainEntryPath: "/repo/apps/desktop/dist-electron/main.cjs",
      desktopRoot: "/repo/apps/desktop",
      environmentFilePath: "/repo/apps/desktop/.electron-runtime/dev-environment.sh",
    });

    assert.include(
      script,
      "if [ -f '/repo/apps/desktop/.electron-runtime/dev-environment.sh' ]; then . '/repo/apps/desktop/.electron-runtime/dev-environment.sh'; fi",
    );
    assert.notInclude(script, "VITE_DEV_SERVER_URL");
    assert.include(
      script,
      "exec '/repo/node_modules/electron/Electron' --t3code-dev-root='/repo/apps/desktop' '/repo/apps/desktop/dist-electron/main.cjs' \"$@\"",
    );
  });

  it("repairs Electron before loading the package entrypoint", () => {
    const calls = [];
    const electronPath = resolveElectronBinaryPath({
      ensureRuntime: () => {
        calls.push("ensure");
      },
      createRequire: () => (specifier) => {
        calls.push(`require:${specifier}`);
        return "/repo/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron";
      },
      moduleUrl: import.meta.url,
    });

    assert.equal(
      electronPath,
      "/repo/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron",
    );
    assert.deepEqual(calls, ["ensure", "require:electron"]);
  });

  it("keeps the native Electron executable name inside the branded macOS bundle", () => {
    const paths = resolveMacLauncherPaths(
      "/repo/apps/desktop/.electron-runtime/T3 Code (Dev).app",
      "T3 Code (Dev)",
    );

    assert.equal(paths.launcherExecutableName, "T3 Code (Dev) Launcher");
    assert.equal(
      paths.launcherBinaryPath,
      "/repo/apps/desktop/.electron-runtime/T3 Code (Dev).app/Contents/MacOS/T3 Code (Dev) Launcher",
    );
    assert.equal(
      paths.runtimeElectronBinaryPath,
      "/repo/apps/desktop/.electron-runtime/T3 Code (Dev).app/Contents/MacOS/Electron",
    );

    const script = makeDevelopmentLauncherScript({
      electronBinaryPath: paths.runtimeElectronBinaryPath,
      mainEntryPath: "/repo/apps/desktop/dist-electron/main.cjs",
      desktopRoot: "/repo/apps/desktop",
      environmentFilePath: "/repo/apps/desktop/.electron-runtime/dev-environment.sh",
    });
    assert.include(
      script,
      "exec '/repo/apps/desktop/.electron-runtime/T3 Code (Dev).app/Contents/MacOS/Electron'",
    );
    assert.notInclude(script, "node_modules/electron");
  });

  it("declares why the macOS app needs protected access", () => {
    const values = resolveMacBundleInfoPlistStrings("T3 Code (Dev) Launcher");

    assert.equal(
      values.NSScreenCaptureUsageDescription,
      "T3 Code captures the active window when you use the snapshot shortcut.",
    );
    assert.equal(
      values.NSDocumentsFolderUsageDescription,
      "T3 Code reads project files you open in the desktop app.",
    );
  });

  it("ad-hoc signs the complete development app bundle", () => {
    assert.deepEqual(resolveMacCodeSignArguments("/runtime/T3 Code (Dev).app"), [
      "--force",
      "--deep",
      "--sign",
      "-",
      "--timestamp=none",
      "/runtime/T3 Code (Dev).app",
    ]);
  });

  it("restores execute permissions on an unchanged launcher", () => {
    const directory = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "t3-launcher-"));
    const launcherPath = NodePath.join(directory, "launcher");
    try {
      writeDevelopmentLauncherScript(launcherPath, "/runtime/Electron");
      NodeFS.chmodSync(launcherPath, 0o644);

      assert.isFalse(writeDevelopmentLauncherScript(launcherPath, "/runtime/Electron"));
      assert.equal(NodeFS.statSync(launcherPath).mode & 0o777, 0o755);
    } finally {
      NodeFS.rmSync(directory, { recursive: true, force: true });
    }
  });

  it("derives launcher icons from canonical development and production assets", () => {
    const development = resolveMacLauncherIconPaths("/runtime", true);
    const production = resolveMacLauncherIconPaths("/runtime", false);

    // The source icons are real repo paths, joined for the host.
    assert.match(development.sourceIconPath, /assets[\\/]dev[\\/]blueprint-macos-1024\.png$/);
    assert.equal(development.generatedIconPath, "/runtime/icon-dev.icns");
    assert.match(production.sourceIconPath, /assets[\\/]prod[\\/]black-macos-1024\.png$/);
    assert.equal(production.generatedIconPath, "/runtime/icon-prod.icns");
  });
});
