import * as NodeFSP from "node:fs/promises";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodeModule from "node:module";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";
import * as NodeChildProcess from "node:child_process";
import { verifyRuntime } from "./chromium-helper/runtime-verification.mjs";
import { smokeRuntime } from "./chromium-helper/runtime-smoke.mjs";

// Authenticate the pinned official arm64 archive and compare runtime bytes.
// Only the output copy is signed; the caller chooses the Apple signing identity.
export async function buildChromiumHelper({
  output,
  runtime,
  archive,
  signIdentity = "-",
  bundleOnly = false,
}) {
  // oxlint-disable-next-line t3code/no-global-process-runtime -- Standalone packager has no Effect runtime.
  const hostPlatform = NodeOS.platform();
  // oxlint-disable-next-line t3code/no-global-process-runtime -- Standalone packager has no Effect runtime.
  const hostArchitecture = NodeOS.arch();
  if (hostPlatform !== "darwin" || hostArchitecture !== "arm64")
    throw new Error("Apple Silicon macOS is required.");
  if (!output) throw new Error("Pass --output with a dedicated helper packaging directory.");
  const repo = NodePath.resolve(NodePath.dirname(NodeURL.fileURLToPath(import.meta.url)), "../..");
  const source = NodePath.join(repo, "apps/macos/chromium-helper");
  const destination = NodePath.resolve(output);
  if (destination === repo || destination === source || !destination.endsWith("chromium-helper")) {
    throw new Error("The output directory must be dedicated to chromium-helper.");
  }
  await NodeFSP.mkdir(destination, { recursive: true });
  let appRoot, runtimeEvidence;
  if (!bundleOnly) {
    if (!runtime || !NodePath.resolve(runtime).endsWith(".app"))
      throw new Error("Supply --runtime /absolute/path/Electron.app; no runtime is downloaded.");
    const executable = NodePath.join(NodePath.resolve(runtime), "Contents/MacOS/Electron");
    const machine = NodeChildProcess.execFileSync("/usr/bin/file", ["-b", executable], {
      encoding: "utf8",
    });
    if (!machine.includes("Mach-O") || !machine.includes("arm64"))
      throw new Error("The runtime must contain a real arm64 Electron executable.");
    const desktopPackage = JSON.parse(
      await NodeFSP.readFile(NodePath.join(repo, "apps/desktop/package.json"), "utf8"),
    );
    runtimeEvidence = await verifyRuntime({
      runtime: NodePath.resolve(runtime),
      version: desktopPackage.dependencies.electron,
      archive,
    });
    appRoot = NodePath.join(destination, "T3 Browser.app");
    if (
      NodePath.resolve(runtime).startsWith(destination + "/") ||
      destination.startsWith(NodePath.resolve(runtime) + "/")
    )
      throw new Error("The runtime and output must be disjoint.");
    await NodeFSP.rm(appRoot, { recursive: true, force: true });
    await NodeFSP.cp(NodePath.resolve(runtime), appRoot, {
      recursive: true,
      dereference: false,
      verbatimSymlinks: true,
    });
    for (const name of ["app.asar", "default_app.asar", "app"]) {
      await NodeFSP.rm(NodePath.join(appRoot, "Contents/Resources", name), {
        recursive: true,
        force: true,
      });
    }
    const plist = NodePath.join(appRoot, "Contents/Info.plist");
    for (const [key, value] of Object.entries({
      CFBundleIdentifier: "com.t3tools.native.browser",
      CFBundleName: "T3 Browser",
      CFBundleDisplayName: "T3 Browser",
    })) {
      NodeChildProcess.execFileSync("/usr/libexec/PlistBuddy", [
        "-c",
        `Set :${key} ${value}`,
        plist,
      ]);
    }
  }
  const assets = bundleOnly
    ? NodePath.join(destination, "app")
    : NodePath.join(appRoot, "Contents/Resources/app");
  await NodeFSP.mkdir(assets, { recursive: true });
  const require = NodeModule.createRequire(NodePath.join(repo, "apps/desktop/package.json"));
  const { build } = await import(
    NodePath.join(NodePath.dirname(require.resolve("vite-plus")), "pack.js")
  );
  const bundled = {
    alwaysBundle: (id) => !id.startsWith("node:") && id !== "electron",
    neverBundle: (id) => id === "electron",
    onlyBundle: false,
  };
  await build({
    config: false,
    entry: [NodePath.join(source, "main.mjs")],
    outDir: assets,
    format: "esm",
    dts: false,
    clean: false,
    platform: "node",
    outExtensions: () => ({ js: ".mjs" }),
    outputOptions: { codeSplitting: false },
    deps: bundled,
    alias: {
      "@effect/platform-node/NodeCrypto": require.resolve("@effect/platform-node/NodeCrypto"),
      "effect/Effect": require.resolve("effect/Effect"),
    },
  });
  for (const entry of [
    NodePath.join(source, "shell-preload.mjs"),
    NodePath.join(source, "guest-input.mjs"),
    NodePath.join(repo, "apps/desktop/src/preview-extension-preload.ts"),
  ]) {
    await build({
      config: false,
      entry: [entry],
      outDir: assets,
      format: "cjs",
      dts: false,
      clean: false,
      platform: "node",
      outExtensions: () => ({ js: ".cjs" }),
      outputOptions: { codeSplitting: false },
      deps: bundled,
    });
  }
  for (const name of ["shell.html", "shell.css", "shell.js"])
    await NodeFSP.cp(NodePath.join(source, name), NodePath.join(assets, name));
  for (const name of ["BrowserAutomation.js", "PlaywrightInjected.js"]) {
    await NodeFSP.cp(
      NodePath.join(repo, "apps/macos/Sources/T3Native/Resources", name),
      NodePath.join(assets, name),
    );
  }
  await NodeFSP.writeFile(
    NodePath.join(assets, "package.json"),
    JSON.stringify(
      { name: "t3-native-browser", version: "1.0.0", type: "module", main: "main.mjs" },
      null,
      2,
    ),
  );
  const licenses = NodePath.join(assets, "Licenses");
  await NodeFSP.mkdir(licenses, { recursive: true });
  await NodeFSP.cp(NodePath.join(repo, "LICENSE"), NodePath.join(licenses, "T3-Code-MIT.txt"));
  // Retain notices for bundled workspace dependencies and the injected runtime.
  for (const name of ["effect", "@effect/platform-node", "fflate", "playwright-core"]) {
    const metadata = (require.resolve.paths(name) ?? [])
      .map((root) => NodePath.join(root, name, "package.json"))
      .find(NodeFS.existsSync);
    if (!metadata) throw new Error(`Missing license metadata for ${name}`);
    for (const file of await NodeFSP.readdir(NodePath.dirname(metadata))) {
      if (/^(license|notice|copyright)/i.test(file))
        await NodeFSP.cp(
          NodePath.join(NodePath.dirname(metadata), file),
          NodePath.join(licenses, `${name.replaceAll("/", "-")}-${file}`),
        );
    }
  }
  if (runtime) {
    const resources = NodePath.join(NodePath.resolve(runtime), "Contents/Resources");
    for (const file of ["LICENSE", "LICENSES.chromium.html"]) {
      if (NodeFS.existsSync(NodePath.join(resources, file)))
        await NodeFSP.cp(NodePath.join(resources, file), NodePath.join(licenses, file));
      else if (NodeFS.existsSync(NodePath.join(NodePath.dirname(NodePath.resolve(runtime)), file)))
        await NodeFSP.cp(
          NodePath.join(NodePath.dirname(NodePath.resolve(runtime)), file),
          NodePath.join(licenses, file),
        );
      else
        throw new Error(
          `The official runtime is missing ${file}; retain the complete distribution notices.`,
        );
    }
  }
  if (appRoot) {
    let entitlements = NodePath.join(source, "entitlements.plist");
    if (signIdentity === "-") {
      // Ad hoc signatures have no Team ID for hardened library validation.
      // Apple identities retain library validation and sign every nested binary.
      entitlements = NodePath.join(destination, "development-entitlements.plist");
      const base = await NodeFSP.readFile(NodePath.join(source, "entitlements.plist"), "utf8");
      await NodeFSP.writeFile(
        entitlements,
        base.replace(
          "</dict>",
          "<key>com.apple.security.cs.disable-library-validation</key><true/></dict>",
        ),
      );
    }
    await signOutput(appRoot, signIdentity, entitlements);
  }
  const runtimeSmoke = appRoot ? await smokeRuntime(appRoot) : null;
  await NodeFSP.writeFile(
    NodePath.join(destination, "manifest.json"),
    JSON.stringify(
      {
        protocol: 1,
        arch: "arm64",
        executable: "T3 Browser.app/Contents/MacOS/Electron",
        app: bundleOnly ? "app" : "T3 Browser.app",
        extensionId: "aeblfdkhhhdcdjpifhhbdiojplfjncoa",
        requiresSigning: false,
        signingIdentity: bundleOnly ? null : signIdentity,
        runtime: runtimeEvidence,
        runtimeSmoke,
      },
      null,
      2,
    ),
  );
  return { assets, app: appRoot ?? null };
}
async function signOutput(root, identity, entitlements) {
  async function visit(directory) {
    for (const entry of await NodeFSP.readdir(directory, { withFileTypes: true })) {
      const path = NodePath.join(directory, entry.name);
      if (entry.isDirectory()) await visit(path);
      else if (entry.isFile()) {
        const file = NodeChildProcess.execFileSync("/usr/bin/file", ["-b", path], {
          encoding: "utf8",
        });
        if (file.includes("Mach-O"))
          NodeChildProcess.execFileSync(
            "/usr/bin/codesign",
            ["--force", "--sign", identity, path],
            {
              stdio: "pipe",
            },
          );
      }
    }
    if (directory.endsWith(".app") || directory.endsWith(".framework")) {
      NodeChildProcess.execFileSync(
        "/usr/bin/codesign",
        [
          "--force",
          "--sign",
          identity,
          "--options",
          "runtime",
          "--entitlements",
          entitlements,
          directory,
        ],
        { stdio: "pipe" },
      );
    }
  }
  await visit(root);
  NodeChildProcess.execFileSync("/usr/bin/codesign", ["--verify", "--deep", "--strict", root], {
    stdio: "pipe",
  });
}
if (
  process.argv[1] &&
  NodePath.resolve(process.argv[1]) === NodeURL.fileURLToPath(import.meta.url)
) {
  const args = process.argv.slice(2),
    value = (name) => {
      const index = args.indexOf(name);
      return index < 0 ? undefined : args[index + 1];
    };
  const result = await buildChromiumHelper({
    output: value("--output"),
    runtime: value("--runtime"),
    archive: value("--official-archive"),
    signIdentity: value("--sign-identity") ?? value("--sign") ?? "-",
    bundleOnly: args.includes("--bundle-only"),
  });
  console.log(`Packaged Chromium helper assets: ${result.assets}`);
}
