import * as NodeFSP from "node:fs/promises";
import * as NodeFS from "node:fs";
import * as NodeModule from "node:module";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";
import * as NodeCrypto from "node:crypto";
import * as NodeChildProcess from "node:child_process";
import * as NodeOS from "node:os";
import { selectCliRuntimeExternalDependencies } from "../../scripts/lib/cli-external-packages.ts";
import { loadRepoEnv } from "../../scripts/lib/public-config.ts";

// oxlint-disable-next-line t3code/no-global-process-runtime -- Standalone native packager has no Effect runtime.
const hostPlatform = NodeOS.platform();
// oxlint-disable-next-line t3code/no-global-process-runtime -- Standalone native packager has no Effect runtime.
const hostArch = NodeOS.arch();

const repo = NodePath.resolve(NodePath.dirname(NodeURL.fileURLToPath(import.meta.url)), "../..");
const bundle = NodePath.resolve(process.argv[2]);
if (hostPlatform !== "darwin" || hostArch !== "arm64" || !bundle.endsWith(".app")) {
  throw new Error("Package an Apple Silicon .app bundle on macOS.");
}
if (!NodeFS.existsSync(NodePath.join(repo, "node_modules/.bin/vp"))) {
  throw new Error(
    "Run pnpm install --frozen-lockfile in the checkout before building the native app.",
  );
}
NodeChildProcess.execFileSync("pnpm", ["exec", "vp", "run", "--filter", "t3", "build"], {
  cwd: repo,
  stdio: "inherit",
});
const resources = NodePath.join(bundle, "Contents/Resources");
const backend = NodePath.join(resources, "backend");
const server = NodePath.join(backend, "server");
await NodeFSP.mkdir(NodePath.join(server, "apps/server"), { recursive: true });
await NodeFSP.cp(
  NodePath.join(repo, "apps/server/dist"),
  NodePath.join(server, "apps/server/dist"),
  { recursive: true },
);
await NodeFSP.mkdir(NodePath.join(backend, "node/bin"), { recursive: true });
await NodeFSP.cp(process.execPath, NodePath.join(backend, "node/bin/node"));
await NodeFSP.cp(
  NodePath.join(NodePath.dirname(NodePath.dirname(process.execPath)), "LICENSE"),
  NodePath.join(resources, "Licenses/Node-LICENSE.txt"),
);
await NodeFSP.cp(
  NodePath.join(NodePath.dirname(NodePath.dirname(process.execPath)), "LICENSE"),
  NodePath.join(backend, "node/LICENSE"),
);

const packages = new Map();
const modules = NodePath.join(server, "node_modules");
await NodeFSP.mkdir(modules, { recursive: true });
const resolvePackage = async (name, from) => {
  const require = NodeModule.createRequire(from);
  for (const search of require.resolve.paths(name) ?? []) {
    const file = NodePath.join(search, name, "package.json");
    if (NodeFS.existsSync(file)) return NodeFSP.realpath(file);
  }
  throw new Error(`Missing runtime dependency ${name}. Run pnpm install first.`);
};
const linkPackage = async (name, from, targetModules, optional = false) => {
  let source;
  try {
    source = await resolvePackage(name, from);
  } catch (error) {
    if (optional) return;
    throw error;
  }
  let target = packages.get(source);
  if (!target) {
    const metadata = JSON.parse(await NodeFSP.readFile(source, "utf8"));
    const hash = NodeCrypto.createHash("sha256").update(source).digest("hex").slice(0, 12);
    target = NodePath.join(
      modules,
      ".native",
      `${name.replaceAll("/", "+")}@${metadata.version}-${hash}`,
    );
    packages.set(source, target);
    await NodeFSP.cp(NodePath.dirname(source), target, {
      recursive: true,
      dereference: true,
      filter: (file) =>
        NodePath.relative(NodePath.dirname(source), file).split("/")[0] !== "node_modules",
    });
    const children = {
      ...metadata.peerDependencies,
      ...metadata.dependencies,
      ...metadata.optionalDependencies,
    };
    for (const child of Object.keys(children)) {
      await linkPackage(
        child,
        source,
        NodePath.join(target, "node_modules"),
        child in (metadata.optionalDependencies ?? {}) ||
          metadata.peerDependenciesMeta?.[child]?.optional === true,
      );
    }
  }
  const link = NodePath.join(targetModules, name);
  await NodeFSP.mkdir(NodePath.dirname(link), { recursive: true });
  if (!NodeFS.existsSync(link))
    await NodeFSP.symlink(NodePath.relative(NodePath.dirname(link), target), link);
};
const manifest = NodePath.join(repo, "apps/server/package.json");
const serverPackage = JSON.parse(await NodeFSP.readFile(manifest, "utf8"));
for (const name of Object.keys(selectCliRuntimeExternalDependencies(serverPackage.dependencies))) {
  await linkPackage(name, manifest, modules);
}
const env = loadRepoEnv();
const plist = NodePath.join(bundle, "Contents/Info.plist");
for (const [key, name] of Object.entries({
  T3ConnectRelayURL: "T3CODE_RELAY_URL",
  T3ConnectClerkPublishableKey: "T3CODE_CLERK_PUBLISHABLE_KEY",
  T3ConnectOAuthClientID: "T3CODE_CLERK_CLI_OAUTH_CLIENT_ID",
  T3ConnectHostedAppURL: "T3CODE_HOSTED_APP_URL",
})) {
  if (env[name]) {
    let exists = true;
    try {
      NodeChildProcess.execFileSync("/usr/libexec/PlistBuddy", ["-c", `Print :${key}`, plist], {
        stdio: "pipe",
      });
    } catch {
      exists = false;
    }
    NodeChildProcess.execFileSync("/usr/libexec/PlistBuddy", [
      "-c",
      exists ? `Set :${key} ${env[name]}` : `Add :${key} string ${env[name]}`,
      plist,
    ]);
  }
}
const revision = NodeChildProcess.execFileSync(
  "git",
  ["-C", repo, "-c", "core.fsmonitor=false", "rev-parse", "HEAD"],
  { encoding: "utf8" },
).trim();
await NodeFSP.writeFile(
  NodePath.join(backend, "manifest.json"),
  JSON.stringify(
    { revision, node: process.version, arch: hostArch, externalPackages: packages.size },
    null,
    2,
  ),
);
// The app signature seals nested native code after each executable gets its own signature.
const signNative = async (directory) => {
  for (const entry of await NodeFSP.readdir(directory, { withFileTypes: true })) {
    const file = NodePath.join(directory, entry.name);
    if (entry.isDirectory()) await signNative(file);
    else if (entry.isFile()) {
      if (
        file.endsWith(".node") ||
        file.endsWith(".dylib") ||
        entry.name === "node" ||
        entry.name === "spawn-helper"
      ) {
        NodeChildProcess.execFileSync("codesign", ["--force", "--sign", "-", file], {
          stdio: "pipe",
        });
      }
    }
  }
};
await signNative(backend);
console.log(`Packaged arm64 Node and server with ${packages.size} runtime dependencies`);
