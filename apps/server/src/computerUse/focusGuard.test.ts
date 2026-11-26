import { expect, it } from "@effect/vitest";
import {
  coveredBy,
  focusGuardFor,
  type FocusObservation,
  focusMove,
  MAX_RESTORES,
  pointerOnApp,
} from "./focusGuard.ts";
import type { WorkerRequest } from "./protocol.ts";

const USER = 10;
const TARGET = 20;
const OTHER = 30;
const observed = (overrides: Partial<FocusObservation>): FocusObservation => ({
  target: TARGET,
  previous: USER,
  front: USER,
  userSwitched: false,
  restores: 0,
  ...overrides,
});

it.each([
  ["restore", "the target took the front from the user", {}, TARGET],
  ["keep", "the user's app is still in front", {}, USER],
  ["adopt", "the user switched to a third app", {}, OTHER],
  ["adopt", "the user clicked or cmd-tabbed into the target", { userSwitched: true }, TARGET],
  ["keep", "the target was already in front", { previous: TARGET }, TARGET],
  ["keep", "the front app is unknown", {}, undefined],
  ["keep", "the launching app has no pid yet", { target: undefined }, TARGET],
  ["adopt", "nothing was in front before", { previous: undefined }, TARGET],
  ["adopt", "the target keeps taking the front back", { restores: MAX_RESTORES }, TARGET],
] as const)("decides to %s when %s", (move, _, overrides, front) => {
  expect(focusMove(observed({ ...overrides, front }))).toBe(move);
});

it("sends the target back to whichever app the user moved to last", () => {
  let previous: number | undefined = USER;
  const restoredTo: Array<number | undefined> = [];
  for (const front of [USER, OTHER, TARGET, OTHER]) {
    const move = focusMove(observed({ previous, front, restores: restoredTo.length }));
    if (move === "adopt") previous = front;
    if (move === "restore") restoredTo.push(previous);
  }
  expect(restoredTo).toEqual([OTHER]);
});

const window = (id: number, pid: number, x: number) => ({
  id,
  pid,
  bounds: { x, y: 0, width: 400, height: 300 },
});

it.each([
  [true, "a target window above overlaps it", [window(1, TARGET, 100), window(2, USER, 0)]],
  [false, "the target window above is beside it", [window(1, TARGET, 500), window(2, USER, 0)]],
  [false, "the target window is below it", [window(2, USER, 0), window(1, TARGET, 100)]],
  [false, "only another app covers it", [window(1, OTHER, 0), window(2, USER, 0)]],
  [false, "the user's app has no window on screen", [window(1, TARGET, 0)]],
] as const)("reports the user's top window covered=%s when %s", (covered, _, stack) => {
  expect(coveredBy(stack, USER, TARGET)).toBe(covered);
});

it("counts a click as the user's own app only where its window is topmost", () => {
  const stack = [window(1, TARGET, 300), window(2, USER, 0)];
  expect(pointerOnApp(stack, { x: 100, y: 100 }, USER)).toBe(true);
  // Where the target's window covers the user's, the click went to the target.
  expect(pointerOnApp(stack, { x: 350, y: 100 }, USER)).toBe(false);
  expect(pointerOnApp(stack, { x: 900, y: 100 }, USER)).toBe(false);
});

const click = (foreground?: boolean): WorkerRequest => ({
  kind: "action",
  app: "Notes",
  pid: TARGET,
  target: null,
  takeover: true,
  action: {
    kind: "click_at",
    x: 1,
    y: 1,
    button: "left",
    count: 1,
    ...(foreground === undefined ? {} : { foreground }),
  },
});
const snapshot: WorkerRequest = {
  kind: "snapshot",
  app: "Notes",
  includeImage: true,
  options: { offset: 0, limit: 10, includeOffscreen: false },
};

it.each([
  [
    "disarm",
    "an open that asks for the app in front",
    { kind: "open", app: "Notes", activate: true },
  ],
  ["arm", "a background open", { kind: "open", app: "Notes", activate: false }],
  ["disarm", "a foreground click", click(true)],
  ["arm", "a background click", click(false)],
  ["arm", "a click without a foreground flag", click()],
  // Reading an app never brings it forward, so a guard there could only undo the
  // user's own switches, such as a link they click that opens the target.
  ["keep", "a snapshot", snapshot],
] as const)("%ss the focus guard for %s", (mode, _, request) => {
  expect(focusGuardFor(request)).toBe(mode);
});
