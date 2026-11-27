import { describe, expect, it } from "vite-plus/test";

import { fieldValue } from "./fieldValue.ts";

describe("fieldValue", () => {
  it.each([
    ["date", "2026-12-15", "2026-12-15"],
    ["date", "15/12/2026", "2026-12-15"],
    ["date", "Tuesday, December 15th, 2026", "2026-12-15"],
    ["date", "15 Dec 2026", "2026-12-15"],
    ["date", "05/05/2026", "2026-05-05"],
    ["date", "2026-02-29", undefined],
    ["date", "2028-02-29", "2028-02-29"],
    ["date", "next friday", undefined],
    ["time", "12:05 am", "00:05"],
    ["time", "13:00 pm", undefined],
    ["time", "09:15:30", "09:15:30"],
    ["datetime-local", "December 15, 2026 at 2:30 PM", "2026-12-15T14:30"],
    ["datetime-local", "2026-12-15T14:30", "2026-12-15T14:30"],
    ["month", "December 2026", "2026-12"],
    ["month", "12/2026", "2026-12"],
    ["week", "2026-w51", "2026-W51"],
  ] as const)("reads %s %j as %j", (type, typed, value) => {
    expect(fieldValue(type, typed)).toBe(value);
  });
});
