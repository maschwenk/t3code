import { describe, expect, it } from "vite-plus/test";

import {
  isDefaultThreadListSectionOrder,
  moveThreadListSection,
  resolveThreadListSectionOrder,
} from "./threadListSectionOrder";

describe("thread list section order", () => {
  it("keeps every section when the stored order is partial, repeated, or from a newer client", () => {
    expect(resolveThreadListSectionOrder(undefined)).toEqual([
      "active",
      "working",
      "snoozed",
      "settled",
    ]);
    expect(
      resolveThreadListSectionOrder(["settled", "later-section", "settled", "working"]),
    ).toEqual(["settled", "working", "active", "snoozed"]);
    expect(isDefaultThreadListSectionOrder([])).toBe(true);
    expect(isDefaultThreadListSectionOrder(["working"])).toBe(false);
  });

  it("moves a section one step and stops at either end", () => {
    expect(moveThreadListSection(undefined, "working", -1)).toEqual([
      "working",
      "active",
      "snoozed",
      "settled",
    ]);
    expect(moveThreadListSection(undefined, "active", -1)).toEqual([
      "active",
      "working",
      "snoozed",
      "settled",
    ]);
    expect(moveThreadListSection(["settled"], "settled", 1)).toEqual([
      "active",
      "settled",
      "working",
      "snoozed",
    ]);
  });
});
