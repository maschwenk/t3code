// @effect-diagnostics nodeBuiltinImport:off -- This tests real CLI isolation without constructing an Effect runtime.
import * as NodeChildProcess from "node:child_process";
import * as NodeURL from "node:url";
import { expect, it } from "@effect/vitest";

// These exercise the real CLI dispatch and worker process, without importing
// the native addon, reading applications or requesting OS permissions.
it.each([
  "private-invalid-input",
  JSON.stringify({ kind: "action", text: "private-invalid-input" }),
  "x".repeat(70_000),
])("rejects malformed worker input without echoing it", (input) => {
  const result = NodeChildProcess.spawnSync(
    process.execPath,
    [NodeURL.fileURLToPath(new URL("../bin.ts", import.meta.url)), "__computer-use"],
    {
      input,
      encoding: "utf8",
      timeout: 12_000,
      env: { ...process.env, ELECTRON_RUN_AS_NODE: "1" },
    },
  );
  expect(result.error).toBeUndefined();
  expect(result.status).toBe(0);
  expect(result.stdout).toBe('{"ok":false,"code":"failed"}');
  expect(result.stderr).not.toContain("private-invalid-input");
});
