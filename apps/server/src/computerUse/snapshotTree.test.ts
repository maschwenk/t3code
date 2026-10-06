import { expect, it } from "@effect/vitest";
import type { ElementTarget } from "./protocol.ts";
import {
  childClip,
  formatElement,
  isAnonymousContainer,
  isOffscreen,
  matchesQuery,
  queryTerms,
} from "./snapshotTree.ts";

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
