import { describe, expect, it } from "vite-plus/test";

import { deliverPointer, type Desktop, USER_IDLE_SECONDS } from "./takeover.ts";

type Point = { x: number; y: number };
const TARGET = 42;
const USER_APP = 7;
const AT = { x: 500, y: 300 };

/**
 * A desktop where the frontmost app owns every point (unless covered), time
 * only passes in sleep, and the user's input happens at scheduled times.
 */
function fakeDesktop(options: {
  front: number;
  idleSeconds?: number;
  userInputAt?: number;
  covered?: boolean;
  activates?: boolean;
}) {
  let clock = 0;
  let lastUserInput = -(options.idleSeconds ?? 60) * 1000;
  let lastSynthetic = -Infinity;
  const state = {
    front: options.front,
    pointer: { x: 10, y: 20 } as Point,
    gestureFront: undefined as number | undefined,
    activations: [] as number[],
  };
  const advance = (ms: number) => {
    clock += ms;
    if (options.userInputAt !== undefined && clock >= options.userInputAt) {
      if (lastUserInput < options.userInputAt) state.pointer = { x: 900, y: 900 };
      lastUserInput = Math.max(lastUserInput, options.userInputAt);
    }
  };
  const desktop: Desktop = {
    frontmost: async () => state.front,
    activate: (pid) => {
      state.activations.push(pid);
      if (options.activates === false) return false;
      state.front = pid;
      return true;
    },
    raise: async () => undefined,
    owner: () => (options.covered ? USER_APP : state.front),
    // Synthetic events count as input, as they may on macOS.
    idleSeconds: () => (clock - Math.max(lastUserInput, lastSynthetic)) / 1000,
    pointer: () => state.pointer,
    warp: (point) => {
      state.pointer = point;
    },
    moveTo: async (point) => {
      state.pointer = point;
      lastSynthetic = clock;
    },
    sleep: async (ms) => advance(ms),
    now: () => clock,
  };
  const gesture = async () => {
    state.gestureFront = state.front;
    lastSynthetic = clock;
  };
  return { desktop, state, gesture };
}

describe("pointer delivery", () => {
  it("acts directly when the app is already in front", async () => {
    const { desktop, state, gesture } = fakeDesktop({ front: TARGET, idleSeconds: 0 });
    const outcome = await deliverPointer(
      desktop,
      { pid: TARGET, points: [AT], takeover: false },
      gesture,
    );
    expect(outcome).toMatchObject({ ok: true, via: "pointer" });
    expect(state.activations).toEqual([]);
  });

  it("takes over a background app while the user is idle, then restores pointer and front app", async () => {
    const { desktop, state, gesture } = fakeDesktop({ front: USER_APP });
    const outcome = await deliverPointer(
      desktop,
      { pid: TARGET, points: [AT], takeover: true },
      gesture,
    );
    expect(outcome).toMatchObject({ ok: true, via: "takeover" });
    expect(state.gestureFront).toBe(TARGET);
    expect(state.front).toBe(USER_APP);
    expect(state.pointer).toEqual({ x: 10, y: 20 });
  });

  it("refuses without touching anything while the user is active or takeover is off", async () => {
    const active = fakeDesktop({ front: USER_APP, idleSeconds: USER_IDLE_SECONDS - 1 });
    expect(
      await deliverPointer(
        active.desktop,
        { pid: TARGET, points: [AT], takeover: true },
        active.gesture,
      ),
    ).toEqual({ ok: false, code: "user_active" });
    const off = fakeDesktop({ front: USER_APP });
    expect(
      await deliverPointer(
        off.desktop,
        { pid: TARGET, points: [AT], takeover: false },
        off.gesture,
      ),
    ).toEqual({ ok: false, code: "input_requires_foreground" });
    for (const { state } of [active, off]) {
      expect(state.activations).toEqual([]);
      expect(state.gestureFront).toBeUndefined();
    }
  });

  it("counts the agent's own recent gesture as idle time, but not the user's input after it", async () => {
    for (const userInputAt of [undefined, 400]) {
      const { desktop, state, gesture } = fakeDesktop({
        front: USER_APP,
        ...(userInputAt ? { userInputAt } : {}),
      });
      const options = { pid: TARGET, points: [AT], takeover: true };
      const first = await deliverPointer(desktop, options, gesture);
      if (!first.ok) throw new Error("first gesture failed");
      await desktop.sleep(500);
      const second = await deliverPointer(
        desktop,
        { ...options, ownInputAt: first.inputAt },
        gesture,
      );
      expect(second.ok ? second.via : second.code).toBe(userInputAt ? "user_active" : "takeover");
      expect(state.front).toBe(USER_APP);
    }
  });

  it("aborts when the user moves during the takeover, leaving their pointer where they put it", async () => {
    // The user grabs the mouse while the pointer waits over the target.
    const { desktop, state, gesture } = fakeDesktop({ front: USER_APP, userInputAt: 100 });
    const outcome = await deliverPointer(
      desktop,
      { pid: TARGET, points: [AT], takeover: true },
      gesture,
    );
    expect(outcome).toEqual({ ok: false, code: "user_active" });
    expect(state.gestureFront).toBeUndefined();
    expect(state.front).toBe(USER_APP);
    expect(state.pointer).toEqual({ x: 900, y: 900 });
  });

  it("restores the front app when the target stays covered or will not come forward", async () => {
    const covered = fakeDesktop({ front: USER_APP, covered: true });
    expect(
      await deliverPointer(
        covered.desktop,
        { pid: TARGET, points: [AT], takeover: true },
        covered.gesture,
      ),
    ).toEqual({ ok: false, code: "input_requires_foreground" });
    expect(covered.state.front).toBe(USER_APP);
    expect(covered.state.pointer).toEqual({ x: 10, y: 20 });

    const stuck = fakeDesktop({ front: USER_APP, activates: false });
    expect(
      await deliverPointer(
        stuck.desktop,
        { pid: TARGET, points: [AT], takeover: true },
        stuck.gesture,
      ),
    ).toEqual({ ok: false, code: "input_requires_foreground" });
    for (const { state } of [covered, stuck]) expect(state.gestureFront).toBeUndefined();
  });
});
