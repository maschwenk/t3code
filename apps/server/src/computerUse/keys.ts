/** Key chords for synthesized keyboard input, such as "Return" or "cmd+shift+t".
 *
 * Key codes are macOS virtual key codes, which name physical keys on an ANSI
 * keyboard. Letters and punctuation therefore follow the US layout; text entry
 * belongs to the "type" action, which is layout independent. */

const MODIFIERS = {
  cmd: { flag: 0x10_0000, keyCode: 55 },
  shift: { flag: 0x2_0000, keyCode: 56 },
  option: { flag: 0x8_0000, keyCode: 58 },
  control: { flag: 0x4_0000, keyCode: 59 },
} as const;
export type Modifier = keyof typeof MODIFIERS;

const MODIFIER_ALIASES: Record<string, Modifier> = {
  cmd: "cmd",
  command: "cmd",
  meta: "cmd",
  super: "cmd",
  shift: "shift",
  option: "option",
  opt: "option",
  alt: "option",
  control: "control",
  ctrl: "control",
};

const NAMED_KEYS: Record<string, number> = {
  return: 36,
  enter: 36,
  tab: 48,
  space: 49,
  delete: 51,
  backspace: 51,
  escape: 53,
  esc: 53,
  forwarddelete: 117,
  home: 115,
  end: 119,
  pageup: 116,
  pagedown: 121,
  left: 123,
  arrowleft: 123,
  right: 124,
  arrowright: 124,
  down: 125,
  arrowdown: 125,
  up: 126,
  arrowup: 126,
  f1: 122,
  f2: 120,
  f3: 99,
  f4: 118,
  f5: 96,
  f6: 97,
  f7: 98,
  f8: 100,
  f9: 101,
  f10: 109,
  f11: 103,
  f12: 111,
};

const CHARACTER_KEYS: Record<string, number> = {
  a: 0,
  s: 1,
  d: 2,
  f: 3,
  h: 4,
  g: 5,
  z: 6,
  x: 7,
  c: 8,
  v: 9,
  b: 11,
  q: 12,
  w: 13,
  e: 14,
  r: 15,
  y: 16,
  t: 17,
  "1": 18,
  "2": 19,
  "3": 20,
  "4": 21,
  "6": 22,
  "5": 23,
  "=": 24,
  "9": 25,
  "7": 26,
  "-": 27,
  "8": 28,
  "0": 29,
  "]": 30,
  o: 31,
  u: 32,
  "[": 33,
  i: 34,
  p: 35,
  l: 37,
  j: 38,
  "'": 39,
  k: 40,
  ";": 41,
  "\\": 42,
  ",": 43,
  "/": 44,
  n: 45,
  m: 46,
  ".": 47,
  "`": 50,
};

export type KeyChord = {
  /** Virtual key code of the main key. */
  readonly keyCode: number;
  /** CGEventFlags for the held modifiers. */
  readonly flags: number;
  readonly modifiers: readonly Modifier[];
  /** The single printable character of the main key, when it has one. */
  readonly character: string | null;
};

/** Parses "Return", "Escape", "Down", "cmd+n", "Cmd+Shift+T", "ctrl+tab" or "cmd++". */
export function parseKeyChord(spec: string): KeyChord | undefined {
  const trimmed = spec.trim();
  if (trimmed.length === 0 || trimmed.length > 64) return undefined;
  // A trailing "+" is the plus key itself ("cmd++"); every other "+" separates.
  const parts = trimmed.endsWith("++")
    ? [...trimmed.slice(0, -2).split("+"), "="]
    : trimmed === "+"
      ? ["="]
      : trimmed.split("+");
  const keyName = parts.pop()?.trim();
  if (!keyName) return undefined;
  const modifiers: Modifier[] = [];
  for (const part of parts) {
    const modifier = MODIFIER_ALIASES[part.trim().toLowerCase()];
    if (!modifier || modifiers.includes(modifier)) return undefined;
    modifiers.push(modifier);
  }
  const lower = keyName.toLowerCase();
  const named = NAMED_KEYS[lower.replace(/[\s_-]/g, "")];
  const character = named === undefined && keyName.length === 1 ? lower : null;
  const keyCode = named ?? (character === null ? undefined : CHARACTER_KEYS[character]);
  if (keyCode === undefined) return undefined;
  // "cmd+T" means the T key with cmd; shift is only added when written out.
  return {
    keyCode,
    flags: modifiers.reduce((flags, modifier) => flags | MODIFIERS[modifier].flag, 0),
    modifiers,
    character,
  };
}

export const modifierKeyCode = (modifier: Modifier) => MODIFIERS[modifier].keyCode;

/** True for chords that apps treat as commands rather than text or navigation. */
export const isShortcut = (chord: KeyChord) =>
  chord.modifiers.includes("cmd") || chord.modifiers.includes("control");

/**
 * The value of a menu item's AXMenuItemCmdModifiers that matches `chord`.
 * The attribute is a bit mask where 0 means command alone: shift = 1, option
 * = 2, control = 4, and 8 means the command key is not part of the shortcut.
 */
export const menuModifierMask = (chord: KeyChord) =>
  (chord.modifiers.includes("shift") ? 1 : 0) |
  (chord.modifiers.includes("option") ? 2 : 0) |
  (chord.modifiers.includes("control") ? 4 : 0) |
  (chord.modifiers.includes("cmd") ? 0 : 8);
