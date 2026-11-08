import { expect, it } from "@effect/vitest";
import type { ElementTarget, NativeSnapshot } from "./protocol.ts";
import {
  carryRefs,
  childClip,
  formatChanges,
  formatElement,
  isAnonymousContainer,
  isOffscreen,
  matchesQuery,
  queryTerms,
} from "./snapshotTree.ts";

const element = (
  fields: Partial<ElementTarget> & Pick<ElementTarget, "role" | "path" | "depth">,
): ElementTarget => ({
  ref: 0,
  name: null,
  value: null,
  enabled: true,
  editable: false,
  actions: [],
  bounds: null,
  description: null,
  states: [],
  stableId: null,
  ...fields,
});
const numbered = (elements: readonly ElementTarget[]) =>
  elements.map((item, index) => ({ ...item, ref: index + 1 }));
const view = (app: string, elements: readonly ElementTarget[]): NativeSnapshot => ({
  app,
  pid: 1,
  truncated: false,
  offscreen: 0,
  frontmost: false,
  elements,
});
const changes = (before: readonly ElementTarget[], after: readonly ElementTarget[]) =>
  formatChanges(view("Calculator", before), view("Calculator", after), "next").split("\n").slice(1);

// macOS Calculator in basic mode as the native worker walks it: the display in
// an Edit field group, then 20 keys. Its display text is the element's name.
const KEYS = [
  ["Delete", "Delete"],
  ["All Clear", "AllClear"],
  ["Percent", "Percent"],
  ["Divide", "Divide"],
  ["7", "Seven"],
  ["8", "Eight"],
  ["9", "Nine"],
  ["Multiply", "Multiply"],
  ["4", "Four"],
  ["5", "Five"],
  ["6", "Six"],
  ["Subtract", "Subtract"],
  ["1", "One"],
  ["2", "Two"],
  ["3", "Three"],
  ["Add", "Add"],
  ["Change Sign", "Negate"],
  ["0", "Zero"],
  ["Point", "Decimal"],
  ["Equals", "Equals"],
] as const;
const keypad = [0, 0, 0, 0, 0];
function calculator(
  display: { readonly text: string; readonly x: number; readonly width: number },
  state: { readonly entered?: boolean; readonly lastExpression?: string } = {},
) {
  // Pressing = inserts a Last Expression group first, shifting every key's tree path.
  const shift = state.lastExpression === undefined ? 0 : 1;
  return numbered([
    element({
      role: "window",
      name: "Calculator",
      stableId: "main",
      path: [0],
      depth: 1,
      actions: ["raise", "focus"],
      bounds: { x: 4890, y: 30, width: 230, height: 408 },
    }),
    element({
      role: "split_group",
      stableId: "main, SidebarNavigationSplitView",
      path: [0, 0, 0],
      depth: 2,
      actions: ["focus"],
      bounds: { x: 4890, y: 30, width: 230, height: 408 },
    }),
    ...(state.lastExpression === undefined
      ? []
      : [
          element({
            role: "group",
            name: "Last Expression",
            stableId: "StandardResultView",
            path: [...keypad, 0],
            depth: 3,
            bounds: { x: 4900, y: 88, width: 210, height: 29 },
          }),
          element({
            role: "static_text",
            name: state.lastExpression,
            value: state.lastExpression,
            path: [...keypad, 0, 0],
            depth: 4,
            bounds: { x: 5072, y: 89, width: 38, height: 26 },
          }),
        ]),
    element({
      role: "group",
      name: "Edit field",
      stableId: "StandardInputView",
      path: [...keypad, shift],
      depth: 3,
      bounds: { x: 4900, y: 116, width: 210, height: 42 },
    }),
    element({
      role: "static_text",
      name: display.text,
      value: display.text,
      path: [...keypad, shift, 0],
      depth: 4,
      bounds: { x: display.x, y: 119, width: display.width, height: 36 },
    }),
    ...KEYS.map(([name, stableId], index) => {
      // All Clear becomes Clear, a different element, once a number is entered.
      const clear = state.entered && name === "All Clear";
      return element({
        role: "button",
        name: clear ? "Clear" : name,
        stableId: clear ? "Clear" : stableId,
        path: [...keypad, shift + 1 + index],
        depth: 3,
        actions: ["press", "focus"],
        bounds: {
          x: 4900 + 54 * (index % 4),
          y: 163 + 54 * Math.floor(index / 4),
          width: 48,
          height: 48,
        },
      });
    }),
  ]);
}

it("reports only what each Calculator key changed and never reuses a ref", () => {
  const start = calculator({ text: "0", x: 5091, width: 19 });
  const seven = carryRefs(
    start,
    calculator({ text: "7", x: 5092, width: 18 }, { entered: true }),
    start.length + 1,
  );
  expect(changes(start, seven.elements)).toEqual([
    "Changes since the snapshot you acted on (~ changed, + new; other refs are unchanged):",
    '+         [25] static_text "7" @5092,119 18x36',
    '+       [26] button "Clear" {press} @4954,163 48x48',
    "removed: 4, 6",
  ]);
  const sum = carryRefs(
    seven.elements,
    calculator({ text: "7+8", x: 5055, width: 55 }, { entered: true }),
    seven.nextRef,
  );
  const equals = carryRefs(
    sum.elements,
    calculator({ text: "15", x: 5077, width: 33 }, { lastExpression: "7+8" }),
    sum.nextRef,
  );
  expect(changes(sum.elements, equals.elements)).toEqual([
    "Changes since the snapshot you acted on (~ changed, + new; other refs are unchanged):",
    '+       [28] group "Last Expression" @4900,88 210x29',
    '~         [27] static_text "7+8" @5072,89 38x26',
    '+         [29] static_text "15" @5077,119 33x36',
    '+       [30] button "All Clear" {press} @4954,163 48x48',
    "removed: 26",
  ]);
  // Every key kept its ref although = moved it in the tree, and All Clear
  // came back as a new element rather than taking its old ref 6 again.
  const keys = (elements: readonly ElementTarget[]) =>
    elements.flatMap((item) => (item.role === "button" ? [`${item.name}=${item.ref}`] : []));
  expect(keys(equals.elements)).toEqual(
    keys(start).map((key) => (key === "All Clear=6" ? "All Clear=30" : key)),
  );
});

it("keeps refs of unnamed web text by position and shows its new value", () => {
  // Chromium's web text is unnamed; its words are the value.
  const page = (count: number, width: number) =>
    numbered([
      element({ role: "web_area", name: "CU Bakeoff", path: [0, 1, 0], depth: 3 }),
      element({
        role: "button",
        name: "Increment",
        path: [0, 1, 0, 1, 0],
        depth: 4,
        actions: ["press"],
        states: ["focused"],
        bounds: { x: 1009, y: 267, width: 76, height: 22 },
      }),
      element({
        role: "static_text",
        name: "",
        value: `count: ${count}`,
        path: [0, 1, 0, 1, 1, 0],
        depth: 4,
        bounds: { x: 1088, y: 267, width, height: 19 },
      }),
      element({
        role: "static_text",
        name: "",
        value: "no canvas clicks",
        path: [0, 1, 0, 2, 1, 0],
        depth: 4,
        bounds: { x: 1314, y: 423, width: 113, height: 19 },
      }),
    ]);
  const before = page(7, 56);
  const after = carryRefs(before, page(8, 57), before.length + 1);
  expect(after.elements.map((item) => item.ref)).toEqual([1, 2, 3, 4]);
  expect(changes(before, after.elements).slice(1)).toEqual([
    '~         [3] static_text = "count: 8" @1088,267 57x19',
  ]);
  expect(changes(after.elements, after.elements)).toEqual([
    "No changes since the snapshot you acted on.",
  ]);
});

it("does not carry a ref into a different parent's children", () => {
  // Rows with identical Delete buttons, and a new row inserted above them. A
  // button keeps its ref only under the row that kept its ref.
  const row = (index: number, label: string) => [
    element({ role: "row", name: label, path: [0, index], depth: 2 }),
    element({ role: "button", name: "Delete", path: [0, index, 0], depth: 3, actions: ["press"] }),
  ];
  const list = element({ role: "list", name: "Orders", path: [0], depth: 1 });
  const before = numbered([list, ...row(0, "Alpha"), ...row(1, "Beta")]);
  const after = carryRefs(
    before,
    [list, ...row(0, "New"), ...row(1, "Alpha"), ...row(2, "Beta")],
    before.length + 1,
  );
  expect(after.elements.map((item) => `${item.name}=${item.ref}`)).toEqual([
    "Orders=1",
    "New=6",
    "Delete=7",
    "Alpha=2",
    "Delete=3",
    "Beta=4",
    "Delete=5",
  ]);
});

const blank = { name: null, value: null, description: null };
it.each([
  [
    "Chromium layout div",
    { role: "group", ...blank, actions: ["show_menu", "scroll_to_visible"] },
    true,
  ],
  ["clickable div", { role: "group", ...blank, actions: ["press", "show_menu"] }, false],
  ["named group", { role: "group", ...blank, name: "Sidebar", actions: [] }, false],
  ["unnamed button", { role: "button", ...blank, actions: ["press"] }, false],
] as const)("collapses only anonymous layout containers: %s", (_, element, expected) => {
  expect(isAnonymousContainer(element)).toBe(expected);
});

it("clips children to scroll areas so rows scrolled out of view are skipped", () => {
  const window = { x: 0, y: 0, width: 800, height: 600 };
  const list = childClip(
    "AXScrollArea",
    { x: 0, y: 100, width: 300, height: 200 },
    childClip("AXWindow", window, null),
  );
  expect(list).toEqual({ x: 0, y: 100, width: 300, height: 200 });
  expect(isOffscreen({ x: 0, y: 290, width: 300, height: 20 }, list)).toBe(false);
  expect(isOffscreen({ x: 0, y: 320, width: 300, height: 20 }, list)).toBe(true);
  // Groups do not clip, and elements without bounds are never judged offscreen.
  expect(childClip("AXGroup", { x: 0, y: 0, width: 10, height: 10 }, list)).toBe(list);
  expect(isOffscreen(null, list)).toBe(false);
  expect(isOffscreen({ x: 0, y: 0, width: 0, height: 0 }, list)).toBe(false);
});

it("matches every query word against name, value and description", () => {
  const terms = queryTerms("  General   SETTINGS ");
  expect(matchesQuery(terms, { name: "General", value: null, description: "Open settings" })).toBe(
    true,
  );
  expect(matchesQuery(terms, { name: "General", value: null, description: null })).toBe(false);
});

it("renders one compact line per element", () => {
  const element: ElementTarget = {
    ref: 7,
    role: "text_field",
    name: "Search",
    value: "cats",
    enabled: true,
    editable: true,
    actions: ["focus", "scroll_to_visible", "press"],
    bounds: { x: 10.4, y: 20, width: 200, height: 24 },
    description: null,
    states: ["focused"],
    depth: 2,
    path: [0, 1],
    stableId: null,
    context: ["Toolbar"],
  };
  expect(formatElement(element)).toBe(
    '    [7] text_field "Search" = "cats" (focused, editable) {press} @10,20 200x24 in "Toolbar"',
  );
});
