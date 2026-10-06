// @effect-diagnostics nodeBuiltinImport:off globalDate:off globalConsole:off preferSchemaOverJson:off globalErrorInEffectFailure:off anyUnknownInErrorContext:off - Experiment harness run directly with node.
/**
 * A synthetic settings app behind a simulated computer-use Driver, for
 * comparing agent strategies without touching real apps. It stands in only for
 * the native worker: ComputerUse's receipts, settings checks, per-step identity
 * checks and mutex run unchanged on top of it. Every label is fixed here.
 */
import * as NodeFS from "node:fs";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Driver from "../../src/computerUse/Driver.ts";
import type {
  ElementTarget,
  NativeSnapshot,
  WorkerRequest,
  WorkerResponse,
} from "../../src/computerUse/protocol.ts";
import { matchesQuery, queryTerms } from "../../src/computerUse/snapshotTree.ts";

export const APP = "JevFixture";
const PID = 4242;

type Screen = {
  readonly title: string;
  readonly links?: ReadonlyArray<readonly [label: string, to: string]>;
  readonly checks?: readonly string[];
  readonly field?: string;
  readonly submit?: string;
};

const SCREENS: Record<string, Screen> = {
  home: {
    title: "Home",
    links: [
      ["Audio", "audio"],
      ["Display", "display"],
      ["Network", "network"],
      ["Storage", "storage"],
      ["Notifications", "notifications"],
      ["Account", "account"],
    ],
  },
  audio: {
    title: "Audio",
    links: [
      ["Output", "audio-output"],
      ["Input", "audio-input"],
    ],
  },
  "audio-output": { title: "Output", checks: ["Spatial audio"] },
  "audio-input": { title: "Input", checks: ["Noise reduction"] },
  display: { title: "Display", links: [["Brightness", "display-brightness"]] },
  "display-brightness": { title: "Brightness", checks: ["Auto brightness"] },
  network: {
    title: "Network",
    links: [
      ["Wi-Fi", "network-wifi"],
      ["VPN", "network-vpn"],
    ],
  },
  "network-wifi": { title: "Wi-Fi", checks: ["Ask to join networks"] },
  "network-vpn": { title: "VPN", checks: ["Connect on demand"] },
  storage: {
    title: "Storage",
    links: [
      ["Disks", "storage-disks"],
      ["Backups", "storage-backups"],
      ["Cloud sync", "storage-cloud"],
    ],
  },
  "storage-disks": { title: "Disks", checks: ["Trim automatically"] },
  "storage-cloud": { title: "Cloud sync", checks: ["Sync on cellular"] },
  "storage-backups": {
    title: "Backups",
    links: [
      ["Schedules", "storage-backups-schedules"],
      ["Retention", "storage-backups-retention"],
      ["Encryption", "storage-backups-encryption"],
    ],
  },
  "storage-backups-retention": { title: "Retention", checks: ["Keep monthly copies"] },
  "storage-backups-encryption": { title: "Encryption", checks: ["Encrypt backups"] },
  "storage-backups-schedules": {
    title: "Schedules",
    checks: ["Nightly backup", "Weekly backup"],
    submit: "Save schedule",
  },
  notifications: {
    title: "Notifications",
    checks: [
      "Email alerts",
      "SMS alerts",
      "Push alerts",
      "Weekly digest",
      "Daily digest",
      "Product news",
      "Security notices",
      "Billing notices",
      "Team mentions",
      "Calendar reminders",
    ],
    submit: "Apply",
  },
  account: {
    title: "Account",
    links: [
      ["Profile", "account-profile"],
      ["Sessions", "account-sessions"],
    ],
  },
  "account-sessions": { title: "Sessions", checks: ["Remember this device"] },
  "account-profile": {
    title: "Profile",
    checks: ["Show status"],
    field: "Display name",
    submit: "Save profile",
  },
};

export type FixtureState = {
  screen: string;
  checked: Record<string, boolean>;
  field: string;
  saved: Record<string, Record<string, boolean | string>>;
  presses: number;
};

export const initialState = (): FixtureState => ({
  screen: "home",
  checked: {},
  field: "",
  saved: {},
  presses: 0,
});

type Control =
  | { readonly kind: "title" }
  | { readonly kind: "link"; readonly to: string }
  | { readonly kind: "home" }
  | { readonly kind: "check"; readonly label: string }
  | { readonly kind: "field" }
  | { readonly kind: "submit" };

/** The window as xa11y would list it, with what each element does. */
function render(state: FixtureState): Array<{ element: ElementTarget; control: Control }> {
  const screen = SCREENS[state.screen]!;
  const rows: Array<{ role: string; name: string; value: string | null; control: Control }> = [
    {
      role: "static_text",
      name: `Screen: ${screen.title}`,
      value: null,
      control: { kind: "title" },
    },
    ...(screen.links ?? []).map(([label, to]) => ({
      role: "button",
      name: label,
      value: null,
      control: { kind: "link", to } as const,
    })),
    ...(screen.checks ?? []).map((label) => ({
      role: "check_box",
      name: label,
      value: state.checked[label] ? "1" : "0",
      control: { kind: "check", label } as const,
    })),
    ...(screen.field
      ? [
          {
            role: "text_field",
            name: screen.field,
            value: state.field,
            control: { kind: "field" } as const,
          },
        ]
      : []),
    ...(screen.submit
      ? [{ role: "button", name: screen.submit, value: null, control: { kind: "submit" } as const }]
      : []),
    ...(state.screen === "home"
      ? []
      : [
          { role: "button", name: "Back to Home", value: null, control: { kind: "home" } as const },
        ]),
  ];
  const element = (
    ref: number,
    path: number[],
    depth: number,
    role: string,
    name: string,
    value: string | null,
    y: number,
  ): ElementTarget => ({
    ref,
    role,
    name,
    value,
    enabled: true,
    editable: role === "text_field",
    actions:
      role === "window"
        ? ["raise"]
        : role === "static_text"
          ? []
          : role === "text_field"
            ? ["focus"]
            : ["press"],
    bounds: { x: 136, y, width: role === "text_field" ? 240 : 160, height: 24 },
    description: null,
    states: [],
    depth,
    path,
    stableId: null,
  });
  return [
    {
      element: {
        ...element(1, [0], 0, "window", "Jev Fixture", null, 120),
        bounds: { x: 120, y: 120, width: 420, height: 520 },
      },
      control: { kind: "title" },
    },
    ...rows.map((row, index) => ({
      element: element(index + 2, [0, index], 1, row.role, row.name, row.value, 160 + index * 32),
      control: row.control,
    })),
  ];
}

const sameElement = (live: ElementTarget, target: ElementTarget) =>
  live.role === target.role &&
  live.name === target.name &&
  live.path.join(".") === target.path.join(".") &&
  (target.editable || live.value === target.value);

function snapshot(
  state: FixtureState,
  request: Extract<WorkerRequest, { kind: "snapshot" }>,
): NativeSnapshot {
  const { query, roles, root, offset, limit } = request.options;
  const terms = queryTerms(query);
  const all = render(state).map(({ element }) => element);
  const inRoot = root
    ? all.filter((element) => element.path.join(".").startsWith(root.path.join(".")))
    : all;
  const matched = inRoot.filter(
    (element) =>
      (!terms.length || matchesQuery(terms, element)) &&
      (!roles?.length || roles.includes(element.role)),
  );
  const page = matched.slice(offset, offset + limit);
  return {
    app: APP,
    pid: PID,
    truncated: false,
    ...(offset + limit < matched.length ? { nextOffset: offset + limit } : {}),
    offscreen: 0,
    menus: ["JevFixture", "File", "Edit", "Window"],
    frontmost: false,
    elements: page,
  };
}

function act(
  state: FixtureState,
  request: Extract<WorkerRequest, { kind: "action" }>,
): WorkerResponse {
  const { action, target } = request;
  if (request.pid !== PID) return { ok: false, code: "target_changed" };
  if (action.kind === "menu")
    return { ok: false, code: "menu_not_found", available: ["File", "Edit", "Window"] };
  if (action.kind === "key") return { ok: true, via: "keyboard_event" };
  if (!target) return { ok: false, code: "unsupported_action" };
  const live = render(state).find(({ element }) => sameElement(element, target));
  if (!live) return { ok: false, code: "target_changed" };
  const { control } = live;
  const pressing =
    action.kind === "press" ||
    (action.kind === "perform" && action.action === "press") ||
    (action.kind === "click" && action.button === "left" && action.count === 1);
  if (action.kind === "type") {
    if (control.kind !== "field") return { ok: false, code: "unsupported_action" };
    state.field = action.replace ? action.text : state.field + action.text;
    return { ok: true, via: "accessibility" };
  }
  if (!pressing) return { ok: false, code: "unsupported_action" };
  const screen = SCREENS[state.screen]!;
  switch (control.kind) {
    case "link":
      state.screen = control.to;
      break;
    case "home":
      state.screen = "home";
      break;
    case "check":
      state.checked[control.label] = !state.checked[control.label];
      break;
    case "submit":
      state.saved[state.screen] = Object.fromEntries([
        ...(screen.checks ?? []).map((label) => [label, state.checked[label] === true] as const),
        ...(screen.field ? [[screen.field, state.field] as const] : []),
      ]);
      break;
    default:
      return { ok: false, code: "unsupported_action" };
  }
  state.presses += 1;
  return { ok: true, via: "accessibility" };
}

/**
 * A Driver over the fixture. `nativeMs` delays each request to stand in for
 * worker startup; `statePath` receives the state after every change.
 */
export const layer = (
  options: {
    readonly nativeMs?: number;
    readonly statePath?: string;
    /** Counts worker requests; each one is a native process spawn in the real Driver. */
    readonly stats?: { requests: number };
  } = {},
) => {
  const state = initialState();
  const persist = () => {
    if (options.statePath) NodeFS.writeFileSync(options.statePath, JSON.stringify(state));
  };
  persist();
  return Layer.succeed(Driver.Driver, {
    execute: (request) =>
      Effect.gen(function* () {
        if (options.stats) options.stats.requests += 1;
        if (options.nativeMs) yield* Effect.sleep(options.nativeMs);
        if (request.kind === "open")
          return request.app === APP
            ? ({ ok: true, via: "launch_services" } as const)
            : ({ ok: false, code: "app_not_running" } as const);
        if (request.app !== APP) return { ok: false, code: "app_not_running" } as const;
        if (request.kind === "snapshot")
          return { ok: true, snapshot: snapshot(state, request) } as const;
        const response = act(state, request);
        persist();
        return response;
      }),
  });
};

export type Task = {
  readonly id: string;
  readonly goal: string;
  readonly verify: (state: FixtureState) => boolean;
};

const savedExactly = (
  state: FixtureState,
  screen: string,
  expected: Record<string, boolean | string>,
) => {
  const saved = state.saved[screen];
  return (
    !!saved && Object.entries(saved).every(([key, value]) => (expected[key] ?? false) === value)
  );
};

export const TASKS: readonly Task[] = [
  {
    id: "nested",
    goal: 'In the JevFixture app, go to Storage > Backups > Schedules, turn on "Nightly backup" (leave "Weekly backup" off), and press "Save schedule".',
    verify: (state) =>
      savedExactly(state, "storage-backups-schedules", {
        "Nightly backup": true,
        "Weekly backup": false,
      }),
  },
  {
    id: "flat",
    goal: 'In the JevFixture app, open Notifications, turn on exactly these: "Email alerts", "Weekly digest", "Security notices" and "Team mentions" (everything else off), then press "Apply".',
    verify: (state) =>
      savedExactly(state, "notifications", {
        "Email alerts": true,
        "Weekly digest": true,
        "Security notices": true,
        "Team mentions": true,
      }),
  },
  {
    id: "form",
    goal: 'In the JevFixture app, go to Account > Profile, set "Display name" to "Synthetic Tester" (leave "Show status" off), and press "Save profile".',
    verify: (state) =>
      savedExactly(state, "account-profile", {
        "Display name": "Synthetic Tester",
        "Show status": false,
      }),
  },
];
