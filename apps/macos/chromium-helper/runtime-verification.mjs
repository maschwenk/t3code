import * as NodeCrypto from "node:crypto";
import * as NodeFS from "node:fs";
import * as NodeFSP from "node:fs/promises";
import * as NodePath from "node:path";
import * as NodeChildProcess from "node:child_process";
import * as NodeOS from "node:os";

export function releaseChecksum(text, filename) {
  for (const line of text.split("\n")) {
    const match = /^([a-f0-9]{64})\s+\*?(.+)$/.exec(line.trim());
    if (match?.[2] === filename) return match[1];
  }
  throw new Error(`The official release checksum does not include ${filename}.`);
}
async function digest(path) {
  const hash = NodeCrypto.createHash("sha256");
  for await (const chunk of NodeFS.createReadStream(path)) hash.update(chunk);
  return hash.digest("hex");
}
async function tree(root) {
  const entries = new Map();
  async function visit(directory, relative = "") {
    for (const name of await NodeFSP.readdir(directory)) {
      const path = NodePath.join(directory, name),
        key = relative ? `${relative}/${name}` : name;
      const entry = await NodeFSP.lstat(path);
      if (entry.isSymbolicLink()) entries.set(key, "link:" + (await NodeFSP.readlink(path)));
      else if (entry.isDirectory()) {
        entries.set(key, "directory");
        await visit(path, key);
      } else if (entry.isFile()) entries.set(key, "file:" + (await digest(path)));
      else throw new Error("The runtime contains an unsupported filesystem entry.");
    }
  }
  await visit(root);
  return entries;
}
export async function compareRuntimeTrees(runtime, verified) {
  const [actual, expected] = await Promise.all([tree(runtime), tree(verified)]);
  if (actual.size !== expected.size)
    throw new Error("The supplied runtime differs from the verified official archive.");
  for (const [path, digest] of expected)
    if (actual.get(path) !== digest) {
      throw new Error(
        `The supplied runtime differs from the verified official archive at ${path}.`,
      );
    }
}
export async function verifyRuntime({ runtime, version, archive }) {
  if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error("The Electron version must be pinned.");
  const sourceVersion = (
    await NodeFSP.readFile(NodePath.join(NodePath.dirname(runtime), "version"), "utf8")
  ).trim();
  if (sourceVersion !== version)
    throw new Error(`Expected Electron ${version}; supplied runtime is ${sourceVersion}.`);
  // A valid ad hoc seal is not vendor provenance. Always authenticate the
  // pinned official archive and compare every runtime file and symlink.
  const temporary = await NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "t3-chromium-verify-"));
  try {
    const filename = `electron-v${version}-darwin-arm64.zip`;
    const base = `https://github.com/electron/electron/releases/download/v${version}`;
    const checksums = NodePath.join(temporary, "SHASUMS256.txt");
    NodeChildProcess.execFileSync(
      "/usr/bin/curl",
      [
        "-fsSL",
        "--proto",
        "=https",
        "--proto-redir",
        "=https",
        `${base}/SHASUMS256.txt`,
        "-o",
        checksums,
      ],
      { stdio: "pipe" },
    );
    const expected = releaseChecksum(await NodeFSP.readFile(checksums, "utf8"), filename);
    const zip = archive ?? NodePath.join(temporary, filename);
    if (!archive)
      NodeChildProcess.execFileSync(
        "/usr/bin/curl",
        ["-fsSL", "--proto", "=https", "--proto-redir", "=https", `${base}/${filename}`, "-o", zip],
        { stdio: "pipe" },
      );
    if ((await digest(zip)) !== expected)
      throw new Error("The official Electron arm64 archive checksum does not match.");
    const unpacked = NodePath.join(temporary, "verified");
    NodeChildProcess.execFileSync("/usr/bin/ditto", ["-x", "-k", zip, unpacked], { stdio: "pipe" });
    await compareRuntimeTrees(runtime, NodePath.join(unpacked, "Electron.app"));
    return { version, verification: "official-release-sha256", sha256: expected };
  } finally {
    await NodeFSP.rm(temporary, { recursive: true, force: true });
  }
}
