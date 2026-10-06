import { assert, describe, it } from "vite-plus/test";

import { cursorCue, fallbackAgentName, lookTarget } from "./agentCursor.ts";

const element = (
  role: string,
  bounds: { x: number; y: number; width: number; height: number } | null,
) => ({
  ref: 1,
  role,
  name: null,
  value: null,
  enabled: true,
  editable: false,
  actions: [],
  bounds,
  description: null,
  states: [],
  depth: 0,
  path: [0],
  stableId: null,
});

describe("agent cursor signals", () => {
  it("looks at the window's title area, and not at all without a window frame", () => {
    const target = lookTarget({
      elements: [
        element("button", { x: 5, y: 5, width: 10, height: 10 }),
        element("window", { x: 2872, y: 354, width: 230, height: 408 }),
      ],
    });
    assert.deepEqual(target?.point, { x: 2987, y: 368 });
    assert.isUndefined(
      lookTarget({ elements: [element("window", { x: 0, y: 0, width: 0, height: 0 })] }),
    );
  });

  it("names agents from provider instance ids when no display name is known", () => {
    assert.strictEqual(fallbackAgentName("claudeAgent"), "Claude");
    assert.strictEqual(fallbackAgentName("codex-work"), "Codex");
    assert.strictEqual(fallbackAgentName("my-runner"), "my-runner");
    assert.strictEqual(fallbackAgentName(""), "Agent");
  });

  it("maps actions to the cue the user sees", () => {
    assert.strictEqual(cursorCue({ kind: "menu", path: ["File", "New"] }, "window"), "menu");
    assert.strictEqual(cursorCue({ kind: "press" }, "combo_box"), "menu");
    assert.strictEqual(cursorCue({ kind: "press" }, "button"), "click");
    assert.strictEqual(cursorCue({ kind: "scroll", dx: 0, dy: -300 }, "group"), "scrollUp");
    assert.strictEqual(
      cursorCue({ kind: "perform", action: "scroll_left_by_page" }, "group"),
      "scrollLeft",
    );
    assert.strictEqual(
      cursorCue({ kind: "click", button: "left", count: 2 }, "table_cell"),
      "doubleClick",
    );
  });
});
