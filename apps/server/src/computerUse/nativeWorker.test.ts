// @effect-diagnostics nodeBuiltinImport:off -- This tests real CLI isolation without constructing an Effect runtime.
import * as NodeChildProcess from "node:child_process";
import * as NodeURL from "node:url";
import { expect, it } from "@effect/vitest";
import {
  agentMenuBar,
  backgroundAction,
  findShortcut,
  identityMatches,
  launchServicesPids,
  nativeFailure,
  relocationMatches,
  systemMenus,
} from "./nativeWorker.ts";
import type { MenuItem } from "./macNative.ts";
import { ComputerUseError, type ElementTarget } from "./protocol.ts";

it.each([
  ["left click", { kind: "click", button: "left", count: 1 }, ["press", "focus"], "press"],
  ["right click", { kind: "click", button: "right", count: 1 }, ["show_menu"], "show_menu"],
  ["double click", { kind: "click", button: "left", count: 2 }, ["press"], undefined],
  ["click without press", { kind: "click", button: "left", count: 1 }, ["focus"], undefined],
  ["listed action", { kind: "perform", action: "raise" }, ["raise", "focus"], "raise"],
  ["unlisted action", { kind: "perform", action: "raise" }, ["focus"], undefined],
  [
    "wheel scroll down",
    { kind: "scroll", dx: 0, dy: 120 },
    ["scroll_down_by_page"],
    "scroll_down_by_page",
  ],
  [
    "wheel scroll left",
    { kind: "scroll", dx: -300, dy: 20 },
    ["scroll_left_by_page"],
    "scroll_left_by_page",
  ],
  [
    "wheel scroll without page actions",
    { kind: "scroll", dx: 0, dy: -120 },
    ["scroll_down_by_page"],
    undefined,
  ],
  ["hover", { kind: "move" }, ["press"], undefined],
] as const)(
  "runs %s in the background only through an advertised action",
  (_, action, available, expected) => {
    expect(backgroundAction(action, available)).toBe(expected);
  },
);

// Trimmed `lsappinfo list` output from macOS 26.
const lsappinfoList = `
 2) "universalaccessd" ASN:0x0-0x8008: 
    bundleID=[ NULL ] 
    pid = 617 !signalled type="BackgroundOnly" flavor=3 Version=[ NULL ]  fileType="????" creator="????" Arch=ARM64 
 5) "Google Chrome" ASN:0x0-0x18018: 
    bundleID="com.google.Chrome"
    pid = 687 type="Foreground" flavor=3 Version="7977.77" fileType="APPL" creator="rimZ" Arch=ARM64 
29) "Google Chrome" ASN:0x0-0xb52b52: 
    bundleID="com.google.Chrome"
    pid = 44889 type="BackgroundOnly" flavor=2 Version="8010.36" fileType="APPL" creator="rimZ" Arch=ARM64 
62) "Rectangle" ASN:0x0-0x4809805: 
    pid = 30619 type="UIElement" flavor=3 Version="100" fileType="APPL" creator="????" Arch=ARM64 
179) "Calculator Helper" ASN:0x0-0x64043ff: 
    pid = 33090 type="UIElement" flavor=3 Version="225" fileType="APPL" Arch=ARM64 sandboxed 
180) "Calculator" ASN:0x0-0x64043fe: 
    bundleID="com.apple.calculator"
    pid = 33082 type="Foreground" flavor=3 Version="225" fileType="APPL" Arch=ARM64 sandboxed 
`;

it.each([
  ["Calculator", [33082]],
  ["Google Chrome", [687]],
  ["Rectangle", [30619]],
  ["universalaccessd", []],
  ["Calc", []],
])("resolves %s to GUI app pids without contacting other apps", (name, pids) => {
  expect(launchServicesPids(lsappinfoList, name)).toEqual(pids);
});

it.each([
  ["Accessibility", "accessibility_permission"],
  ["Screen Recording", "screen_recording_permission"],
])("unwraps the upstream provider initialization failure for %s", (permission, reason) => {
  const cause = new Error(
    `Platform error (-1): Permission denied: Enable ${permission} in System Settings; private app text`,
  );
  cause.name = "PlatformError";
  const response = nativeFailure(cause, "app_lookup");
  expect(response).toEqual({
    ok: false,
    code: "permissions",
    detail: { stage: "app_lookup", reason },
  });
  if (response.ok) throw new Error("Expected permission failure");
  expect(new ComputerUseError(response).message).not.toContain("private app text");
});

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
  expect(JSON.parse(result.stdout)).toEqual({
    ok: false,
    code: "failed",
    detail: { stage: "request", reason: "unknown" },
  });
  expect(result.stderr).not.toContain("private-invalid-input");
});

const field: ElementTarget = {
  ref: 3,
  role: "text_field",
  name: "To",
  value: "a@b",
  enabled: true,
  editable: true,
  actions: [],
  bounds: { x: 10, y: 10, width: 200, height: 20 },
  description: null,
  states: [],
  depth: 1,
  path: [0, 2],
  stableId: null,
};
const row: ElementTarget = {
  ...field,
  role: "row",
  name: "Inbox",
  value: "3 unread",
  editable: false,
};

it("keeps a text field's identity while its value changes, but not a row's", () => {
  expect(identityMatches({ ...field, value: "a@b.com" }, field)).toBe(true);
  expect(identityMatches({ ...row, value: "4 unread" }, row)).toBe(false);
  expect(identityMatches({ ...field, bounds: { ...field.bounds!, y: 40 } }, field)).toBe(false);
});

it("relocates a named element that moved, never an unnamed one", () => {
  // Named elements may shift when content is inserted above them.
  expect(relocationMatches({ ...row, bounds: { ...row.bounds!, y: 90 } }, row)).toBe(true);
  const unnamed = { ...row, name: null };
  expect(relocationMatches({ ...unnamed, bounds: { ...row.bounds!, y: 90 } }, unnamed)).toBe(false);
  expect(relocationMatches(unnamed, unnamed)).toBe(true);
  expect(relocationMatches({ ...row, name: "Drafts" }, row)).toBe(false);
});

const menu = (
  title: string,
  children: MenuItem[] = [],
  shortcut: MenuItem["shortcut"] = null,
): MenuItem => ({
  title,
  enabled: true,
  shortcut,
  press: () => true,
  children: () => children,
  hasSubmenu: () => children.length > 0 || title === "Services",
});
// Services is filled only when it opens, so it reports a submenu with no items yet.
const menuBar = [
  menu("Apple", [menu("System Settings…"), menu("Log Out Max…", [], { character: "q", mask: 1 })]),
  menu("TextEdit", [
    menu("Settings…"),
    menu("Services"),
    menu("Quit TextEdit", [], { character: "q", mask: 0 }),
  ]),
  menu("File", [menu("New", [], { character: "n", mask: 0 })]),
];

it("keeps the Apple menu and Services out of an agent's menu bar and shortcuts", () => {
  const bar = agentMenuBar(menuBar);
  expect(bar.map((item) => item.title)).toEqual(["TextEdit", "File"]);
  expect(bar[0]?.children().map((item) => item.title)).toEqual(["Settings…", "Quit TextEdit"]);
  expect(findShortcut(bar, "q", 0)?.title).toBe("Quit TextEdit");
  expect(findShortcut(bar, "q", 1)).toBeUndefined();
  expect(findShortcut(systemMenus(menuBar), "q", 1)?.title).toBe("Log Out Max…");
  expect(systemMenus(menuBar).map((item) => item.title)).toEqual(["Apple", "Services"]);
});
