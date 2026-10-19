import * as NodeTest from "node:test";
import * as NodeAssert from "node:assert/strict";
import * as NodeCrypto from "node:crypto";
import * as NodeFSP from "node:fs/promises";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import { CommandDecoder, authenticated, pageURL, selectedProfile, identity } from "./protocol.mjs";

NodeTest.test(
  "private pipe accepts split authenticated commands and refuses another launch token",
  () => {
    const token = NodeCrypto.randomBytes(32).toString("hex"),
      decoder = new CommandDecoder(token);
    const line =
      JSON.stringify({
        token,
        id: "request-1",
        method: "open",
        input: { url: "https://example.com/" },
      }) + "\n";
    NodeAssert.deepEqual(decoder.push(line.slice(0, 11)), []);
    NodeAssert.deepEqual(decoder.push(line.slice(11)), [
      { token, id: "request-1", method: "open", input: { url: "https://example.com/" } },
    ]);
    const bad =
      JSON.stringify({
        token: NodeCrypto.randomBytes(32).toString("hex"),
        id: "request-2",
        method: "install",
      }) + "\n";
    NodeAssert.throws(() => decoder.push(bad), /Unauthenticated/);
    NodeAssert.equal(authenticated("x", token), false);
  },
);
NodeTest.test(
  "pipe bounds unfinished lines before parsing and refuses invalid request identities",
  () => {
    const token = NodeCrypto.randomBytes(32).toString("hex");
    NodeAssert.throws(() => new CommandDecoder(token).push("x".repeat(1024 * 1024 + 1)), /exceeds/);
    NodeAssert.throws(
      () =>
        new CommandDecoder(token).push(
          JSON.stringify({ token, id: "request\nforged", method: "open" }) + "\n",
        ),
      /identity/,
    );
    NodeAssert.throws(() => identity(""), /identity/);
  },
);
NodeTest.test(
  "page navigation permits HTTP(S) and refuses credentials or privileged schemes",
  () => {
    NodeAssert.equal(pageURL("https://example.com/a?q=b"), "https://example.com/a?q=b");
    NodeAssert.equal(pageURL("http://localhost:3000"), "http://localhost:3000/");
    NodeAssert.equal(pageURL("about:blank"), "about:blank");
    for (const url of [
      "file:///tmp/a",
      "javascript:alert(1)",
      "data:text/html,a",
      "chrome-extension://a/a",
      "https://user:secret@example.com",
    ]) {
      NodeAssert.throws(() => pageURL(url));
    }
  },
);
NodeTest.test(
  "explicit profile selection uses canonical files and rejects traversal and symlink escapes",
  async () => {
    const directory = await NodeFSP.mkdtemp(
      NodePath.join(NodeOS.tmpdir(), "t3-chromium-profiles-"),
    );
    try {
      const root = NodePath.join(directory, "Chrome"),
        outside = NodePath.join(directory, "outside");
      await NodeFSP.mkdir(NodePath.join(root, "Default"), { recursive: true });
      await NodeFSP.mkdir(outside);
      await NodeFSP.symlink(outside, NodePath.join(root, "Profile 2"));
      NodeAssert.equal(
        await selectedProfile(root, "Default"),
        await NodeFSP.realpath(NodePath.join(root, "Default")),
      );
      await NodeAssert.rejects(selectedProfile(root, "../outside"), /existing browser profile/);
      await NodeAssert.rejects(selectedProfile(root, "Profile 2"), /outside its browser/);
    } finally {
      await NodeFSP.rm(directory, { recursive: true, force: true });
    }
  },
);

import { compareRuntimeTrees, releaseChecksum } from "./runtime-verification.mjs";

NodeTest.test(
  "verified runtime comparison detects changed bytes and rewritten framework symlinks",
  async () => {
    const directory = await NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "t3-electron-tree-"));
    try {
      const a = NodePath.join(directory, "a"),
        b = NodePath.join(directory, "b");
      for (const root of [a, b]) {
        await NodeFSP.mkdir(NodePath.join(root, "Versions/A"), { recursive: true });
        await NodeFSP.writeFile(
          NodePath.join(root, "Versions/A/Electron"),
          "original executable bytes",
        );
        await NodeFSP.symlink("A", NodePath.join(root, "Versions/Current"));
        await NodeFSP.symlink("Versions/Current/Electron", NodePath.join(root, "Electron"));
      }
      await compareRuntimeTrees(a, b);
      await NodeFSP.writeFile(NodePath.join(a, "Versions/A/Electron"), "modified executable bytes");
      await NodeAssert.rejects(compareRuntimeTrees(a, b), /differs/);
      await NodeFSP.writeFile(NodePath.join(a, "Versions/A/Electron"), "original executable bytes");
      await NodeFSP.rm(NodePath.join(a, "Electron"));
      await NodeFSP.symlink(NodePath.join(b, "Versions/A/Electron"), NodePath.join(a, "Electron"));
      await NodeAssert.rejects(compareRuntimeTrees(a, b), /differs/);
    } finally {
      await NodeFSP.rm(directory, { recursive: true, force: true });
    }
  },
);
NodeTest.test(
  "release checksum selection rejects absent architecture and accepts exact release filename",
  () => {
    const checksum = "a".repeat(64),
      file = "electron-v44.4.2-darwin-arm64.zip";
    NodeAssert.equal(releaseChecksum(`${checksum}  ${file}\n`, file), checksum);
    NodeAssert.throws(
      () => releaseChecksum(`${checksum}  electron-v44.4.2-darwin-x64.zip\n`, file),
      /does not include/,
    );
  },
);
