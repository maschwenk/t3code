import { expect, it } from "@effect/vitest";
import { isShortcut, menuModifierMask, parseKeyChord } from "./keys.ts";

it.each([
  ["Return", 36, 0, null],
  ["escape", 53, 0, null],
  ["Page Down", 121, 0, null],
  ["ArrowUp", 126, 0, null],
  ["cmd+n", 45, 0x10_0000, "n"],
  ["Cmd+Shift+T", 17, 0x10_0000 | 0x2_0000, "t"],
  ["ctrl+option+F5", 96, 0x4_0000 | 0x8_0000, null],
  ["cmd++", 24, 0x10_0000, "="],
  ["cmd+,", 43, 0x10_0000, ","],
] as const)("parses %s", (spec, keyCode, flags, character) => {
  expect(parseKeyChord(spec)).toMatchObject({ keyCode, flags, character });
});

it.each(["", "cmd+", "hyper+a", "cmd+cmd+a", "é", "cmd+shift"])("rejects %j", (spec) => {
  expect(parseKeyChord(spec)).toBeUndefined();
});

it("matches AX menu shortcut masks, where 0 is command alone", () => {
  const mask = (spec: string) => menuModifierMask(parseKeyChord(spec)!);
  expect(mask("cmd+n")).toBe(0);
  expect(mask("cmd+shift+n")).toBe(1);
  expect(mask("cmd+option+i")).toBe(2);
  expect(mask("ctrl+tab")).toBe(4 | 8);
  expect(isShortcut(parseKeyChord("shift+tab")!)).toBe(false);
  expect(isShortcut(parseKeyChord("ctrl+a")!)).toBe(true);
});
