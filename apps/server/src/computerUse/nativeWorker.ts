// @effect-diagnostics nodeBuiltinImport:off -- This isolated CLI worker runs before an Effect runtime exists.
import type { Element } from "@crowecawcaw/xa11y";
import * as Schema from "effect/Schema";
import * as NodeChildProcess from "node:child_process";
import * as NodeFs from "node:fs/promises";
import * as NodeOs from "node:os";
import * as NodePath from "node:path";
import * as NodeTimersPromises from "node:timers/promises";
import * as NodeUtil from "node:util";
import { isShortcut, menuModifierMask, modifierKeyCode, parseKeyChord } from "./keys.ts";
import { loadMacNative, type MacNative, type MenuItem } from "./macNative.ts";
import { pointerTarget, sameWindowBounds } from "./pointerTarget.ts";
import { deliverPointer, type Desktop } from "./takeover.ts";
import {
  type ComputerAction,
  type NativeSnapshot,
  WorkerRequest,
  type ElementTarget,
  type WorkerResponse,
  type FailureStage,
} from "./protocol.ts";
import {
  childClip,
  isAnonymousContainer,
  isOffscreen,
  matchesQuery,
  queryTerms,
} from "./snapshotTree.ts";

// Loaded only in a short-lived child. Native accessibility can block or crash;
// it must never load inside the server or Electron's main process.
const decodeRequest = Schema.decodeUnknownSync(Schema.fromJsonString(WorkerRequest));
const execFile = NodeUtil.promisify(NodeChildProcess.execFile);
type Xa11y = typeof import("@crowecawcaw/xa11y");
type App = import("@crowecawcaw/xa11y").App;
type Rect = { x: number; y: number; width: number; height: number };
type Point = { x: number; y: number };

const MAX_TEXT = 24_000;
const MAX_VISITED = 6_000;
const MAX_DEPTH = 48;
// The driver kills the worker at 12 s; leave room for capture and the reply.
const WALK_BUDGET_MS = 6_500;
const MAX_IMAGE_SIDE = 1600;

const secure = (element: Element) =>
  /password|secure/i.test(`${element.role} ${String(element.raw.ax_subrole ?? "")}`);
const clippedValue = (element: { readonly value: string | null }) =>
  element.value?.slice(0, 1000) ?? null;
const sameBounds = (a: Rect | null, b: Rect | null) =>
  a === b ||
  (!!a && !!b && a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height);

type Identity = Pick<Element, "role" | "name" | "value" | "stableId" | "bounds">;
/**
 * Whether a live element is the one a snapshot described. Text inputs keep
 * their identity while their value changes, so a batch can type and then
 * press Return in the same field.
 */
export function identityMatches(element: Identity, target: ElementTarget): boolean {
  return (
    element.role === target.role &&
    element.name === target.name &&
    (target.stableId === null || element.stableId === target.stableId) &&
    sameBounds(element.bounds, target.bounds) &&
    (target.editable || clippedValue(element) === target.value)
  );
}

/**
 * Whether a live element can stand in for a target whose tree position moved,
 * for example after a row was inserted above it. Layout may shift, so bounds
 * are only required for unnamed elements; the caller also requires uniqueness.
 */
export function relocationMatches(element: Identity, target: ElementTarget): boolean {
  return (
    element.role === target.role &&
    element.name === target.name &&
    (target.stableId === null || element.stableId === target.stableId) &&
    (target.name !== null ||
      target.stableId !== null ||
      sameBounds(element.bounds, target.bounds)) &&
    (target.editable || clippedValue(element) === target.value)
  );
}

/** The accessibility action that performs `action` without synthesized pointer
 * input. Accessibility actions reach background apps without focusing them or
 * moving the user's mouse. Undefined means only real pointer input can do it. */
export function backgroundAction(
  action: Extract<ComputerAction, { kind: "press" | "move" | "click" | "scroll" | "perform" }>,
  available: readonly string[],
): string | undefined {
  const name =
    action.kind === "press"
      ? "press"
      : action.kind === "perform"
        ? action.action
        : action.kind === "click" && action.count === 1
          ? action.button === "left"
            ? "press"
            : "show_menu"
          : action.kind === "scroll"
            ? scrollPageAction(action.dx, action.dy)
            : undefined;
  return name !== undefined && available.includes(name) ? name : undefined;
}

/** Positive dy scrolls down, positive dx scrolls right. */
export const scrollPageAction = (dx: number, dy: number) =>
  Math.abs(dy) >= Math.abs(dx)
    ? dy > 0
      ? "scroll_down_by_page"
      : "scroll_up_by_page"
    : dx > 0
      ? "scroll_right_by_page"
      : "scroll_left_by_page";

/**
 * Returns pids of running GUI apps whose LaunchServices name is `name`, taken
 * from `lsappinfo list` output. Regular apps come before menu-bar agents, and
 * background-only processes that share a name (Chrome shims) are skipped.
 */
export function launchServicesPids(listing: string, name: string): number[] {
  const matches: { pid: number; foreground: boolean }[] = [];
  for (const entry of listing.split(/^(?=\s*\d+\) ")/m)) {
    const fields = /\bpid = (\d+)[^\n]*?\btype="(Foreground|UIElement)"/.exec(entry);
    if (fields && /^\s*\d+\) "(.*)" ASN:/.exec(entry)?.[1] === name)
      matches.push({ pid: Number(fields[1]), foreground: fields[2] === "Foreground" });
  }
  return matches
    .toSorted((a, b) => Number(b.foreground) - Number(a.foreground))
    .map((match) => match.pid);
}

const lsappinfo = (args: string[]) =>
  execFile("/usr/bin/lsappinfo", args, { timeout: 3_000, maxBuffer: 8 * 1024 * 1024 }).then(
    (result) => result.stdout,
  );

// xa11y's App.byName and App.foreground read accessibility attributes from
// every windowed app, so each unresponsive app on the machine stalls them for
// a full AX messaging timeout (a minute in practice). LaunchServices names
// apps without contacting them; attaching by pid then only talks to the target.
async function appByName(App: Xa11y["App"], name: string): Promise<App | undefined> {
  for (const pid of launchServicesPids(await lsappinfo(["list"]), name)) {
    const app = await App.byPid(pid, { timeout: 0 }).catch((cause: unknown) => {
      // The process exited or has no accessibility bridge; permission errors propagate.
      if (cause instanceof Error && cause.name === "SelectorNotMatchedError") return undefined;
      throw cause;
    });
    if (app?.name === name) return app;
  }
  return undefined;
}

async function frontmostPid(): Promise<number | undefined> {
  const asn = (await lsappinfo(["front"])).trim();
  if (!asn.startsWith("ASN:")) return undefined;
  const pid = /"pid"=(\d+)/.exec(await lsappinfo(["info", "-only", "pid", asn]))?.[1];
  return pid === undefined ? undefined : Number(pid);
}

type Resolved = { readonly element: Element; readonly window: Element | undefined };
/** Finds a snapshot's element again: by tree path first, then by unique identity in its window. */
async function resolve(app: App, target: ElementTarget): Promise<Resolved | undefined> {
  let element = app.asElement();
  let window: Element | undefined;
  let found = true;
  for (const index of target.path) {
    if (secure(element)) return undefined;
    const child = (await element.children())[index];
    if (!child) {
      found = false;
      break;
    }
    element = child;
    if (element.role === "window") window ??= element;
  }
  if (found && identityMatches(element, target)) return { element, window };
  const windows = (await app.children()).filter((item) => item.role === "window");
  const home = windows[target.path[0] ?? -1];
  const scopes = home ? [home] : windows;
  const matches: Resolved[] = [];
  let visited = 0;
  for (const scope of scopes) {
    const queue: Element[] = [scope];
    while (queue.length && visited < 3_000 && matches.length < 2) {
      const next = queue.shift()!;
      visited++;
      if (secure(next) || (next.pid !== null && next.pid !== app.pid)) continue;
      if (relocationMatches(next, target)) matches.push({ element: next, window: scope });
      queue.push(...(await next.children()));
    }
  }
  return matches.length === 1 ? matches[0] : undefined;
}

const elementStates = (element: Element) =>
  [
    element.focused && "focused",
    element.selected && "selected",
    element.checked === "on" && "checked",
    element.checked === "off" && "unchecked",
    element.checked === "mixed" && "mixed",
    element.expanded === true && "expanded",
    element.expanded === false && "collapsed",
  ].filter((state): state is string => typeof state === "string");

async function takeSnapshot(
  native: MacNative,
  app: App & { pid: number },
  request: Extract<WorkerRequest, { kind: "snapshot" }>,
): Promise<WorkerResponse> {
  const { options } = request;
  const terms = queryTerms(options.query);
  const roles = options.roles?.length ? new Set(options.roles) : undefined;
  const filtering = terms.length > 0 || roles !== undefined;
  let start = app.asElement();
  let startClip: Rect | null = null;
  let window: Element | undefined;
  if (options.root) {
    const resolved = await resolve(app, options.root);
    if (!resolved) return { ok: false, code: "target_changed" };
    start = resolved.element;
    window = resolved.window;
    startClip = window?.bounds ?? null;
  }
  const startPath = [...(options.root?.path ?? [])];
  const elements: ElementTarget[] = [];
  const started = performance.now();
  let textSize = 0;
  let visited = 0;
  let matched = 0;
  let offscreen = 0;
  let truncated = false;
  let more = false;
  const visit = async (
    element: Element,
    path: number[],
    depth: number,
    walkDepth: number,
    clip: Rect | null,
    context: readonly string[],
  ): Promise<void> => {
    if (more || truncated) return;
    if (
      visited >= MAX_VISITED ||
      walkDepth > MAX_DEPTH ||
      performance.now() - started > WALK_BUDGET_MS
    ) {
      truncated = true;
      return;
    }
    visited++;
    if (element.pid !== null && element.pid !== app.pid) return;
    // xa11y lists the application as its own child when it has no windows
    // (for example while the screen is locked); never walk into that cycle.
    if (walkDepth > 0 && element.role === "application") return;
    // Never return password values, names, or descendants to the agent.
    if (secure(element)) return;
    const bounds = element.bounds;
    const hidden = isOffscreen(bounds, clip);
    if (hidden && !options.includeOffscreen) {
      offscreen++;
      return;
    }
    const name = element.name;
    const value = clippedValue(element);
    const description = element.description?.slice(0, 500) ?? null;
    const anonymous =
      element.role !== "application" &&
      isAnonymousContainer({
        role: element.role,
        name,
        value,
        description,
        actions: element.actions,
      });
    const wanted =
      !anonymous &&
      element.role !== "application" &&
      (!filtering ||
        ((roles === undefined || roles.has(element.role)) &&
          matchesQuery(terms, { name, value, description })));
    if (wanted && matched++ >= options.offset) {
      if (elements.length >= options.limit) {
        more = true;
        return;
      }
      textSize += (name?.length ?? 0) + (value?.length ?? 0) + (description?.length ?? 0);
      if (textSize > MAX_TEXT) {
        truncated = true;
        return;
      }
      elements.push({
        ref: elements.length + 1,
        role: element.role,
        name,
        value,
        description,
        enabled: element.enabled,
        editable: element.editable,
        actions: element.actions,
        states: hidden ? [...elementStates(element), "offscreen"] : elementStates(element),
        depth: filtering ? 0 : depth,
        path,
        stableId: element.stableId,
        bounds,
        ...(filtering && context.length ? { context: context.slice(-2) } : {}),
      });
    }
    const nextClip = childClip(String(element.raw.ax_role ?? ""), bounds, clip);
    const nextContext =
      name && element.role !== "static_text" && element.role !== "application"
        ? [...context, name.slice(0, 60)]
        : context;
    const children = await element.children();
    for (const [index, child] of children.entries()) {
      if (more || truncated) break;
      await visit(
        child,
        [...path, index],
        wanted || (!filtering && !anonymous) ? depth + 1 : depth,
        walkDepth + 1,
        nextClip,
        nextContext,
      );
    }
  };
  await visit(start, startPath, 0, 0, startClip, []);
  const menus = options.root
    ? undefined
    : agentMenuBar(native.menuBar(app.pid)).flatMap((item) => (item.title ? [item.title] : []));
  let image: NativeSnapshot["image"];
  if (request.includeImage) {
    const captured = await captureWindow(native, app, window);
    if ("ok" in captured) return captured;
    image = captured;
  }
  return {
    ok: true,
    snapshot: {
      app: app.name,
      pid: app.pid,
      elements,
      truncated,
      offscreen,
      frontmost: (await frontmostPid()) === app.pid,
      ...(more ? { nextOffset: options.offset + elements.length } : {}),
      ...(menus?.length ? { menus } : {}),
      ...(image ? { image } : {}),
    },
  };
}

/** PNG dimensions from its IHDR chunk. */
const pngSize = (png: Buffer) => ({ width: png.readUInt32BE(16), height: png.readUInt32BE(20) });

/**
 * Captures one window by its window-server id. This works while the window is
 * behind other apps' windows and never includes them.
 */
async function captureWindow(
  native: MacNative,
  app: App & { pid: number },
  window: Element | undefined,
): Promise<NonNullable<NativeSnapshot["image"]> | WorkerResponse> {
  if (!native.canCaptureScreen())
    return {
      ok: false,
      code: "permissions",
      detail: { stage: "capture", reason: "screen_recording_permission" },
    };
  const target =
    window?.bounds ?? (await app.children()).find((item) => item.role === "window")?.bounds ?? null;
  const windows = native.windows(app.pid).filter((item) => item.layer === 0);
  const match =
    (target &&
      windows.find(
        (item) =>
          Math.abs(item.bounds.x - target.x) < 2 &&
          Math.abs(item.bounds.y - target.y) < 2 &&
          Math.abs(item.bounds.width - target.width) < 2,
      )) ||
    windows.find((item) => item.bounds.width >= 100 && item.bounds.height >= 100);
  if (!match) return { ok: false, code: "capture_requires_foreground" };
  const file = NodePath.join(NodeOs.tmpdir(), `t3-computer-${process.pid}-${match.id}.png`);
  try {
    await execFile("/usr/sbin/screencapture", ["-x", "-o", "-t", "png", `-l${match.id}`, file], {
      timeout: 5_000,
    });
    let png = await NodeFs.readFile(file);
    let size = pngSize(png);
    if (Math.max(size.width, size.height) > MAX_IMAGE_SIDE) {
      // Retina captures are twice the window's point size; models need far less.
      await execFile("/usr/bin/sips", ["-Z", String(MAX_IMAGE_SIDE), file], { timeout: 5_000 });
      png = await NodeFs.readFile(file);
      size = pngSize(png);
    }
    if (png.length > 8 * 1024 * 1024) return { ok: false, code: "failed" };
    return {
      data: png.toString("base64"),
      mimeType: "image/png",
      ...size,
      window: { id: match.id, bounds: match.bounds },
    };
  } finally {
    await NodeFs.rm(file, { force: true });
  }
}

const menuTitle = (title: string | null) =>
  (title ?? "")
    .trim()
    .replace(/(\.\.\.|…)$/, "")
    .trim()
    .toLowerCase();

/**
 * The menu bar an agent may use. The Apple menu runs system commands (System
 * Settings, Force Quit, Log Out, Lock Screen) and the application menu's
 * submenus (Services) run other apps, so neither is reachable from an
 * allowlisted app. AppKit always puts those two menus first.
 */
export function agentMenuBar(bar: readonly MenuItem[]): MenuItem[] {
  const [, application, ...rest] = bar;
  if (!application) return [];
  return [
    {
      ...application,
      children: () => application.children().filter((item) => !item.hasSubmenu()),
    },
    ...rest,
  ];
}

/** The menus agentMenuBar withholds, whose shortcuts must not be sent as keys either. */
export function systemMenus(bar: readonly MenuItem[]): MenuItem[] {
  const [apple, application] = bar;
  return [
    ...(apple ? [apple] : []),
    ...(application ? application.children().filter((item) => item.hasSubmenu()) : []),
  ];
}

/** The enabled item within two levels below `items` whose key equivalent is `character` with `mask`. */
export function findShortcut(
  items: readonly MenuItem[],
  character: string,
  mask: number,
  depth = 0,
): MenuItem | undefined {
  for (const item of items) {
    if (item.enabled && item.shortcut?.character === character && item.shortcut.mask === mask)
      return item;
    if (depth < 2) {
      const found = findShortcut(item.children(), character, mask, depth + 1);
      if (found) return found;
    }
  }
  return undefined;
}

function pressMenuPath(native: MacNative, pid: number, path: readonly string[]): WorkerResponse {
  let items = agentMenuBar(native.menuBar(pid));
  for (const [index, title] of path.entries()) {
    const item = items.find((candidate) => menuTitle(candidate.title) === menuTitle(title));
    if (!item || (index === path.length - 1 && !item.enabled))
      return {
        ok: false,
        code: "menu_not_found",
        available: items
          .flatMap((candidate) =>
            candidate.title && candidate.enabled ? [candidate.title.slice(0, 80)] : [],
          )
          .slice(0, 40),
      };
    if (index === path.length - 1)
      return item.press() ? { ok: true, via: "menu" } : { ok: false, code: "failed" };
    items = item.children();
  }
  return { ok: false, code: "menu_not_found" };
}

async function pressKey(
  native: MacNative,
  pid: number,
  action: Extract<ComputerAction, { kind: "key" }>,
): Promise<WorkerResponse> {
  const chord = parseKeyChord(action.key);
  if (!chord) return { ok: false, code: "unsupported_action" };
  if (isShortcut(chord) && chord.character) {
    const bar = native.menuBar(pid);
    const mask = menuModifierMask(chord);
    // Posted keys still reach the Apple and Services menus (shift+cmd+q logs out).
    if (findShortcut(systemMenus(bar), chord.character, mask))
      return { ok: false, code: "unsupported_action" };
    // Background AppKit apps ignore posted command shortcuts, but their menu
    // items still run through accessibility. Shortcuts with no menu item fall
    // through to key events, which web and Electron content does handle.
    if ((await frontmostPid()) !== pid) {
      const item = findShortcut(agentMenuBar(bar), chord.character, mask);
      if (item) {
        for (let index = 0; index < (action.repeat ?? 1); index++)
          if (!item.press()) return { ok: false, code: "failed" };
        return { ok: true, via: "menu" };
      }
    }
  }
  let flags = 0;
  for (const modifier of chord.modifiers) {
    flags |= parseKeyChord(`${modifier}+a`)!.flags;
    native.postKey(pid, modifierKeyCode(modifier), true, flags);
  }
  for (let index = 0; index < (action.repeat ?? 1); index++) {
    native.postKey(pid, chord.keyCode, true, chord.flags);
    native.postKey(pid, chord.keyCode, false, chord.flags);
    await NodeTimersPromises.setTimeout(8);
  }
  for (const modifier of chord.modifiers.toReversed()) {
    flags &= ~parseKeyChord(`${modifier}+a`)!.flags;
    native.postKey(pid, modifierKeyCode(modifier), false, flags);
  }
  return { ok: true, via: "keyboard_event" };
}

const within = (point: Point, rect: Rect) =>
  point.x >= rect.x &&
  point.y >= rect.y &&
  point.x < rect.x + rect.width &&
  point.y < rect.y + rect.height;
const asPoint = (tuple: readonly [number, number] | undefined): Point | undefined =>
  tuple && { x: tuple[0], y: tuple[1] };

/**
 * Runs real pointer input at `points`, which must all land on the app: as is
 * when the app is in front, or by briefly bringing it forward while the user
 * is idle (see deliverPointer).
 */
async function runPointer(
  xa11y: Xa11y,
  native: MacNative,
  request: Extract<WorkerRequest, { kind: "action" }>,
  points: readonly Point[],
  window: Element | undefined,
  gesture: (input: ReturnType<Xa11y["inputSim"]>) => Promise<void>,
): Promise<WorkerResponse> {
  const input = xa11y.inputSim();
  const desktop: Desktop = {
    frontmost: frontmostPid,
    activate: native.activate,
    raise: async () => {
      if (window?.actions.includes("raise"))
        await window.performAction("raise").catch(() => undefined);
    },
    owner: (point) => native.pidAt([point.x, point.y]),
    idleSeconds: native.idleSeconds,
    pointer: native.pointer,
    warp: native.warp,
    moveTo: (point) => input.moveTo([point.x, point.y]),
    sleep: (ms) => NodeTimersPromises.setTimeout(ms),
    now: () => performance.now(),
  };
  const outcome = await deliverPointer(
    desktop,
    { pid: request.pid, points, takeover: request.takeover },
    () => gesture(input),
  );
  return outcome.ok ? { ok: true, via: outcome.via } : { ok: false, code: outcome.code };
}

/** click_at, move_at and drag: pointer gestures between capture pixels and elements. */
async function pointerGesture(
  xa11y: Xa11y,
  native: MacNative,
  app: App & { pid: number },
  request: Extract<WorkerRequest, { kind: "action" }>,
  source: Resolved | undefined,
): Promise<WorkerResponse> {
  const { action, screen } = request;
  if (action.kind !== "click_at" && action.kind !== "move_at" && action.kind !== "drag")
    return { ok: false, code: "unsupported_action" };
  let window = source?.window;
  if (screen) {
    // Capture pixels are only meaningful while the window has not moved or resized.
    const live = native.windows(app.pid).find((item) => item.id === screen.window.id);
    if (!live || !sameWindowBounds(live.bounds, screen.window.bounds))
      return { ok: false, code: "target_changed" };
    for (const point of [screen.from, screen.to])
      if (point && !within(point, live.bounds)) return { ok: false, code: "target_changed" };
    window ??= (await app.children()).find(
      (item) =>
        item.role === "window" && !!item.bounds && sameWindowBounds(item.bounds, live.bounds),
    );
  }
  if (action.kind !== "drag") {
    const at = screen?.to;
    if (!at) return { ok: false, code: "unsupported_action" };
    return runPointer(xa11y, native, request, [at], window, async (input) => {
      if (action.kind === "click_at")
        await input.click([at.x, at.y], { button: action.button, count: action.count });
    });
  }
  const from = source
    ? asPoint(pointerTarget(source.element.bounds, source.window?.bounds ?? null))
    : screen?.from;
  let to = screen?.to;
  if (request.drop) {
    const drop = await resolve(app, request.drop);
    if (
      !drop ||
      secure(drop.element) ||
      (drop.element.pid !== null && drop.element.pid !== app.pid)
    )
      return { ok: false, code: "target_changed" };
    to = asPoint(pointerTarget(drop.element.bounds, drop.window?.bounds ?? null));
  }
  if (!from || !to) return { ok: false, code: "input_requires_foreground" };
  return runPointer(xa11y, native, request, [from, to], window, (input) =>
    input.drag([from.x, from.y], [to.x, to.y], { duration: 400 }),
  );
}

async function act(
  xa11y: Xa11y,
  native: MacNative,
  app: App & { pid: number },
  request: Extract<WorkerRequest, { kind: "action" }>,
): Promise<WorkerResponse> {
  const { action } = request;
  if (action.kind === "wait") return { ok: true };
  if (action.kind === "menu") return pressMenuPath(native, app.pid, action.path);
  let resolved: Resolved | undefined;
  if (request.target) {
    resolved = await resolve(app, request.target);
    if (
      !resolved ||
      secure(resolved.element) ||
      !resolved.element.enabled ||
      (resolved.element.pid !== null && resolved.element.pid !== app.pid)
    )
      return { ok: false, code: "target_changed" };
  }
  if (action.kind === "key") {
    // Key events go to the app's focused element; focus the target first.
    if (resolved && !resolved.element.focused) {
      await resolved.element.focus().catch(() => undefined);
      await NodeTimersPromises.setTimeout(40);
    }
    return pressKey(native, app.pid, action);
  }
  if (action.kind === "click_at" || action.kind === "move_at" || action.kind === "drag")
    return pointerGesture(xa11y, native, app, request, resolved);
  if (!resolved) return { ok: false, code: "target_changed" };
  const { element, window } = resolved;
  if (action.kind === "type") {
    if (!element.editable) return { ok: false, code: "unsupported_action" };
    if (action.replace) await element.setValue(action.text);
    else await element.typeText(action.text);
    return { ok: true, via: "accessibility" };
  }
  const background = backgroundAction(action, element.actions);
  if (background) {
    await element.performAction(background);
    return { ok: true, via: "accessibility" };
  }
  if (action.kind === "scroll") {
    // Scroll views usually own the page actions; walk up from the element.
    const name = scrollPageAction(action.dx, action.dy);
    let ancestor = await element.parent();
    for (let level = 0; ancestor && level < 8; level++) {
      if (ancestor.actions.includes(name)) {
        await ancestor.performAction(name);
        return { ok: true, via: "accessibility" };
      }
      ancestor = await ancestor.parent();
    }
  }
  if (action.kind === "press" || action.kind === "perform")
    return { ok: false, code: "unsupported_action" };
  // Only synthesized pointer input remains. It moves the user's real cursor and
  // lands on whatever window is on top, so it runs only where the app's own
  // element is the topmost one at that point.
  const point = pointerTarget(element.bounds, window?.bounds ?? null);
  if (!point) return { ok: false, code: "input_requires_foreground" };
  return runPointer(
    xa11y,
    native,
    request,
    [{ x: point[0], y: point[1] }],
    window,
    async (input) => {
      if (action.kind === "click")
        await input.click(point, { button: action.button, count: action.count });
      else if (action.kind === "scroll") await input.scroll(point, action.dx, action.dy);
    },
  );
}

async function openApp(
  App: Xa11y["App"],
  request: Extract<WorkerRequest, { kind: "open" }>,
): Promise<WorkerResponse> {
  // -g asks LaunchServices not to bring the app forward. Some apps still
  // activate themselves when they finish launching.
  const launched = await execFile(
    "/usr/bin/open",
    request.activate ? ["-a", request.app] : ["-g", "-a", request.app],
    { timeout: 10_000 },
  ).then(
    () => true,
    () => false,
  );
  if (!launched) return { ok: false, code: "app_not_running" };
  for (let attempt = 0; attempt < 40; attempt++) {
    const app = await appByName(App, request.app);
    // A launching app is listed before its first window exists.
    if (app && (attempt >= 16 || (await app.children()).length > 0))
      return { ok: true, via: "launch_services" };
    await NodeTimersPromises.setTimeout(250);
  }
  return { ok: false, code: "app_not_running" };
}

async function execute(
  request: WorkerRequest,
  stage: (value: FailureStage) => void,
): Promise<WorkerResponse> {
  // oxlint-disable-next-line t3code/no-global-process-runtime -- This isolated CLI worker runs before an Effect runtime exists.
  if (process.platform !== "darwin") return { ok: false, code: "unavailable" };
  stage("load");
  // xa11y is CommonJS. Node's ESM interop only detects `App` and `Element` as
  // named exports, so `inputSim` and `screenshot` exist only on the default export.
  const xa11y = (await import("@crowecawcaw/xa11y")).default;
  const { App } = xa11y;
  if (request.kind === "open") {
    stage("app_lookup");
    return openApp(App, request);
  }
  const native = await loadMacNative();
  stage("app_lookup");
  const app =
    request.kind === "snapshot"
      ? await appByName(App, request.app)
      : await App.byPid(request.pid, { timeout: 0 });
  if (!app) return { ok: false, code: "app_not_running" };
  if (app.name !== request.app || app.pid === null) return { ok: false, code: "target_changed" };
  const attached = app as App & { pid: number };
  if (request.kind === "action") {
    stage("action");
    return act(xa11y, native, attached, request);
  }
  stage("element_tree");
  return takeSnapshot(native, attached, request);
}

export function nativeFailure(cause: unknown, stage?: FailureStage): WorkerResponse {
  // v0.13 stores provider initialization errors as strings, then wraps them
  // in PlatformError. Match only its fixed permission prefix, never relay it.
  const wrappedPermission =
    cause instanceof Error &&
    cause.name === "PlatformError" &&
    cause.message.startsWith("Platform error (-1): Permission denied: ");
  return {
    ok: false,
    code:
      cause instanceof Error &&
      (wrappedPermission ||
        cause.name === "PermissionDeniedError" ||
        cause.name === "AccessibilityNotEnabledError" ||
        // xa11y wraps methods, but native property getters can still throw tags.
        /^XA11Y_(PERMISSION_DENIED|ACCESSIBILITY_NOT_ENABLED):/.test(cause.message))
        ? "permissions"
        : "failed",
    ...(stage
      ? {
          detail: {
            stage,
            reason:
              cause instanceof Error &&
              cause.message.includes("Enable Screen Recording in System Settings")
                ? ("screen_recording_permission" as const)
                : cause instanceof Error &&
                    cause.message.includes("Enable Accessibility in System Settings")
                  ? ("accessibility_permission" as const)
                  : cause instanceof TypeError
                    ? ("type_error" as const)
                    : cause instanceof Error && "code" in cause && cause.code === "InvalidArg"
                      ? ("invalid_argument" as const)
                      : cause instanceof Error && cause.name === "TimeoutError"
                        ? ("timeout" as const)
                        : cause instanceof Error &&
                            /^(XA11yError|PlatformError|SelectorNotMatchedError)$/.test(cause.name)
                          ? ("native_error" as const)
                          : ("unknown" as const),
          },
        }
      : {}),
  };
}

export async function runComputerUseWorker(): Promise<void> {
  let response: WorkerResponse;
  let stage: FailureStage = "request";
  try {
    let raw = "";
    for await (const chunk of process.stdin) {
      raw += String(chunk);
      if (raw.length > 65_536) throw new Error("Request too large");
    }
    response = await execute(decodeRequest(raw), (value) => {
      stage = value;
    });
  } catch (cause) {
    response = nativeFailure(cause, stage);
  }
  process.stdout.write(JSON.stringify(response));
}
