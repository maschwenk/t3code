// @effect-diagnostics nodeBuiltinImport:off -- Exercises the store against a real temporary directory.
import * as NodeFSP from "node:fs/promises";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

import { strToU8, zipSync } from "fflate";
import { afterEach, beforeEach, describe, expect, it } from "vite-plus/test";

import { ExtensionStore, listProfileExtensions } from "./ExtensionStore.ts";

const ID = "aeblfdkhhhdcdjpifhhbdiojplfjncoa";
const manifest = (version: string, extra: Record<string, unknown> = {}) =>
  JSON.stringify({
    manifest_version: 3,
    name: "__MSG_name__",
    version,
    default_locale: "en",
    ...extra,
  });
const messages = JSON.stringify({ name: { message: "1Password" } });

let root: string;
beforeEach(async () => {
  root = await NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "t3-extension-store-"));
});
afterEach(async () => {
  await NodeFSP.rm(root, { recursive: true, force: true });
});

async function writeExtension(directory: string, version: string, extra?: Record<string, unknown>) {
  await NodeFSP.mkdir(NodePath.join(directory, "_locales", "en"), { recursive: true });
  await NodeFSP.writeFile(NodePath.join(directory, "manifest.json"), manifest(version, extra));
  await NodeFSP.writeFile(NodePath.join(directory, "_locales", "en", "messages.json"), messages);
}

describe("ExtensionStore", () => {
  it("lists only the newest version of each extension in a Chromium profile", async () => {
    const profile = NodePath.join(root, "Default");
    await writeExtension(NodePath.join(profile, "Extensions", ID, "8.9.0_0"), "8.9.0");
    await writeExtension(NodePath.join(profile, "Extensions", ID, "8.10.1_0"), "8.10.1");
    await writeExtension(NodePath.join(profile, "Extensions", "b".repeat(32), "1.0_0"), "1.0", {
      theme: {},
    });

    const found = await listProfileExtensions(profile);
    expect(
      found.map((entry) => [entry.id, entry.description.version, entry.description.name]),
    ).toEqual([[ID, "8.10.1", "1Password"]]);
  });

  it("replaces an installed version and keeps whether it was turned off", async () => {
    const store = new ExtensionStore(NodePath.join(root, "store"));
    const source = { kind: "browser", sourceId: "chrome" } as const;
    const first = NodePath.join(root, "v1");
    await writeExtension(first, "1.0.0");
    await store.installDirectory({ id: ID, sourceDirectory: first, source });
    await store.setEnabled(ID, false);

    const second = NodePath.join(root, "v2");
    await writeExtension(second, "2.0.0");
    const updated = await store.installDirectory({ id: ID, sourceDirectory: second, source });

    expect(updated.version).toBe("2.0.0");
    expect((await store.list()).map((entry) => [entry.version, entry.enabled])).toEqual([
      ["2.0.0", false],
    ]);
    expect(await NodeFSP.readdir(NodePath.join(root, "store", ID))).toEqual(["2.0.0"]);
  });

  it("refuses an archive entry that would land outside the extension", async () => {
    const store = new ExtensionStore(NodePath.join(root, "store"));
    const archive = zipSync({
      "manifest.json": strToU8(manifest("1.0.0")),
      "../../escaped.txt": strToU8("nope"),
    });
    await expect(
      store.installArchive({
        id: ID,
        archive,
        manifestKey: undefined,
        source: { kind: "webStore" },
      }),
    ).rejects.toThrow(/escapes/);
    await expect(NodeFSP.access(NodePath.join(root, "escaped.txt"))).rejects.toThrow();
    expect(await store.list()).toEqual([]);
  });

  it("writes the Web Store key into the manifest so the extension keeps its id", async () => {
    const store = new ExtensionStore(NodePath.join(root, "store"));
    const archive = zipSync({ "manifest.json": strToU8(manifest("3.1.0")) });
    const installed = await store.installArchive({
      id: ID,
      archive,
      manifestKey: "MIIBIjAN",
      source: { kind: "webStore" },
    });
    expect(installed.manifest.key).toBe("MIIBIjAN");
  });
});
