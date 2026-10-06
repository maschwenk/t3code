// @effect-diagnostics nodeBuiltinImport:off globalDate:off globalConsole:off preferSchemaOverJson:off globalErrorInEffectFailure:off anyUnknownInErrorContext:off - Experiment harness run directly with node.
import { expect, it } from "@effect/vitest";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as Effect from "effect/Effect";
import * as ComputerUse from "../../src/computerUse/ComputerUse.ts";
import * as Jev from "../../src/computerUse/jevDelegate.ts";
import * as Fixture from "./fixtureApp.ts";
import { computerLayer } from "./mcpServer.ts";

// Answers the way Jev does: the listed action naming the next control in
// `path` (one per executed step), else DONE. No network.
const scripted =
  (path: readonly string[], confidence = 0.9): Jev.Decider =>
  ({ criteria, history }) => {
    const next = path[history.length];
    const listed = Object.entries(criteria).find(
      ([, text]) => next !== undefined && text.endsWith(JSON.stringify(next)),
    );
    return Effect.succeed({ choice: listed?.[0] ?? "DONE", confidence, model: "scripted", ms: 0 });
  };

const run = (decider: Jev.Decider, deny?: string[]) => {
  const statePath = NodePath.join(
    NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "jev-")),
    "s.json",
  );
  return Effect.gen(function* () {
    const computer = yield* ComputerUse.ComputerUse;
    const result = yield* Jev.delegate(computer, decider, "test", {
      app: Fixture.APP,
      goal: "goal",
      deny,
    });
    const state = JSON.parse(NodeFS.readFileSync(statePath, "utf8")) as Fixture.FixtureState;
    // The returned snapshot is the caller's live receipt, so the agent can keep acting.
    const followUp = result.observation
      ? yield* computer.act("test", {
          snapshotId: result.observation.snapshotId,
          steps: [{ action: { kind: "key", key: "Escape" } }],
        })
      : undefined;
    return { result, state, followUp };
  }).pipe(Effect.provide(computerLayer({ statePath })));
};

it("offers only unique, enabled, non-text presses and says what a toggle will do", () => {
  const base = {
    value: null,
    enabled: true,
    editable: false,
    actions: ["press"],
    bounds: null,
    description: null,
    states: [],
    depth: 1,
    path: [0],
    stableId: null,
  };
  const elements = [
    { ...base, ref: 1, role: "button", name: "Save" },
    { ...base, ref: 2, role: "button", name: "Open" },
    { ...base, ref: 3, role: "link", name: "Open" },
    { ...base, ref: 4, role: "check_box", name: "Sync", value: "1" },
    { ...base, ref: 5, role: "text_field", name: "Title", editable: true },
    { ...base, ref: 6, role: "button", name: "Delete all" },
    { ...base, ref: 7, role: "button", name: "Off", enabled: false },
    { ...base, ref: 8, role: "static_text", name: "Label", actions: [] },
  ];
  expect(Jev.candidateActions(elements, ["delete"]).map((action) => action.description)).toEqual([
    'Press button "Save"',
    'Turn off check_box "Sync"',
  ]);
});

it.effect("walks screens through ComputerUse.act and stops for verification on DONE", () =>
  Effect.gen(function* () {
    const { result, state, followUp } = yield* run(
      scripted(["Storage", "Backups", "Schedules", "Nightly backup", "Save schedule"]),
    );
    expect(result.status).toBe("needs_verification");
    expect(result.steps).toHaveLength(6);
    expect(state.saved["storage-backups-schedules"]).toEqual({
      "Nightly backup": true,
      "Weekly backup": false,
    });
    expect(followUp?.error).toBeUndefined();
    expect(followUp?.snapshot).toBeDefined();
  }),
);

it.effect("hands back without acting when confidence is low or a control is denied", () =>
  Effect.gen(function* () {
    const unsure = yield* run(scripted(["Storage"], 0.4));
    expect(unsure.result.status).toBe("low_confidence");
    expect(unsure.state.presses).toBe(0);

    // A denied control is never offered, so the loop cannot press it.
    const denied = yield* run(scripted(["Storage"]), ["storage"]);
    expect(denied.result.status).toBe("needs_verification");
    expect(denied.state.presses).toBe(0);
  }),
);
