// @effect-diagnostics nodeBuiltinImport:off -- This tests real CLI isolation without constructing an Effect runtime.
import * as NodeChildProcess from "node:child_process";
import * as NodeURL from "node:url";
import { expect, it } from "@effect/vitest";
import { nativeFailure } from "./nativeWorker.ts";

it.each(["PermissionDeniedError", "AccessibilityNotEnabledError"])(
  "reports %s as a permission blocker without exposing native app text",
  (name) => {
    const cause = new Error("private app text");
    cause.name = name;
    expect(nativeFailure(cause)).toEqual({ ok: false, code: "permissions" });
  },
);

it("does not pass unknown native failures or application text to the agent", () => {
  expect(nativeFailure(new Error("private app text"))).toEqual({ ok: false, code: "failed" });
  expect(nativeFailure("private app text")).toEqual({ ok: false, code: "failed" });
});

it.each(["XA11Y_PERMISSION_DENIED", "XA11Y_ACCESSIBILITY_NOT_ENABLED"])(
  "recognizes an unwrapped %s from a native property getter",
  (tag) => {
    expect(nativeFailure(new Error(`${tag}: private app text`))).toEqual({
      ok: false,
      code: "permissions",
    });
  },
);

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
