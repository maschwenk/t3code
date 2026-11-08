import type { ElementTarget, NativeSnapshot } from "./protocol.ts";

type Rect = {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
};

const CONTAINER_ROLES = new Set(["group", "generic", "unknown", "section", "layout_area", "pane"]);
// Every Chromium node advertises these, so they say nothing about a container.
const PASSIVE_ACTIONS = new Set(["show_menu", "scroll_to_visible", "scroll_into_view", "focus"]);

/** Unnamed layout containers. They are walked through but not returned. */
export function isAnonymousContainer(element: {
  readonly role: string;
  readonly name: string | null;
  readonly value: string | null;
  readonly description: string | null;
  readonly actions: readonly string[];
}): boolean {
  return (
    CONTAINER_ROLES.has(element.role) &&
    !element.name &&
    !element.value &&
    !element.description &&
    element.actions.every((action) => PASSIVE_ACTIONS.has(action))
  );
}

const hasArea = (rect: Rect | null | undefined): rect is Rect =>
  !!rect &&
  [rect.x, rect.y, rect.width, rect.height].every(Number.isFinite) &&
  rect.width > 0 &&
  rect.height > 0;

/** The visible part of `rect` within `clip`, or null when they do not overlap. */
function intersect(rect: Rect, clip: Rect): Rect | null {
  const x = Math.max(rect.x, clip.x);
  const y = Math.max(rect.y, clip.y);
  const right = Math.min(rect.x + rect.width, clip.x + clip.width);
  const bottom = Math.min(rect.y + rect.height, clip.y + clip.height);
  return right > x && bottom > y ? { x, y, width: right - x, height: bottom - y } : null;
}

/**
 * Whether an element lies entirely outside the visible area of its window or
 * scroll area. Elements without usable bounds are kept: containers often
 * report none while their children are on screen.
 */
export const isOffscreen = (bounds: Rect | null, clip: Rect | null) =>
  hasArea(bounds) && clip !== null && intersect(bounds, clip) === null;

/** The clip for an element's children. Windows and scroll areas clip their content. */
export function childClip(axRole: string, bounds: Rect | null, clip: Rect | null): Rect | null {
  if ((axRole !== "AXWindow" && axRole !== "AXScrollArea") || !hasArea(bounds)) return clip;
  return clip ? (intersect(bounds, clip) ?? clip) : bounds;
}

/** Lowercased words of a query; an element matches when it contains all of them. */
export const queryTerms = (query: string | undefined) =>
  (query ?? "").toLowerCase().split(/\s+/).filter(Boolean);

export const matchesQuery = (
  terms: readonly string[],
  element: {
    readonly name: string | null;
    readonly value: string | null;
    readonly description: string | null;
  },
) => {
  const text =
    `${element.name ?? ""} ${element.value ?? ""} ${element.description ?? ""}`.toLowerCase();
  return terms.every((term) => text.includes(term));
};

const quote = (text: string, max: number) =>
  JSON.stringify(text.length > max ? `${text.slice(0, max)}…` : text);

/** One element per line, indented by depth: `[ref] role "name" = "value" (states) {actions} @x,y wxh`. */
export function formatElement(element: ElementTarget): string {
  const parts = [`${"  ".repeat(Math.min(element.depth, 12))}[${element.ref}] ${element.role}`];
  if (element.name) parts.push(quote(element.name, 160));
  if (element.value !== null && element.value !== "" && element.value !== element.name)
    parts.push(`= ${quote(element.value, 300)}`);
  if (element.description && element.description !== element.name)
    parts.push(`- ${quote(element.description, 120)}`);
  const states = [
    ...element.states,
    ...(element.enabled ? [] : ["disabled"]),
    ...(element.editable ? ["editable"] : []),
  ];
  if (states.length) parts.push(`(${states.join(", ")})`);
  const offscreen = element.states.includes("offscreen");
  const actions = element.actions.filter(
    (action) => !PASSIVE_ACTIONS.has(action) || (offscreen && action === "scroll_to_visible"),
  );
  if (actions.length) parts.push(`{${actions.join(", ")}}`);
  const bounds = element.bounds;
  if (hasArea(bounds))
    parts.push(
      `@${Math.round(bounds.x)},${Math.round(bounds.y)} ${Math.round(bounds.width)}x${Math.round(bounds.height)}`,
    );
  if (element.context?.length)
    parts.push(`in ${element.context.map((name) => quote(name, 60)).join(" > ")}`);
  return parts.join(" ");
}

const pathKey = (path: readonly number[]) => path.join(".");
const identity = (element: ElementTarget) =>
  JSON.stringify([element.role, element.stableId, element.name]);

/** Each element's nearest ancestor among the returned elements, by tree path. */
function returnedParents(elements: readonly ElementTarget[]) {
  const byPath = new Map(elements.map((element) => [pathKey(element.path), element]));
  const parents = new Map<ElementTarget, ElementTarget>();
  for (const element of elements)
    for (let length = element.path.length - 1; length > 0; length--) {
      const parent = byPath.get(pathKey(element.path.slice(0, length)));
      if (parent) {
        parents.set(element, parent);
        break;
      }
    }
  return { byPath, parents };
}

const identityCounts = (elements: readonly ElementTarget[]) => {
  const counts = new Map<string, number>();
  for (const element of elements) {
    const id = identity(element);
    counts.set(id, (counts.get(id) ?? 0) + 1);
  }
  return counts;
};

/**
 * Renumbers a fresh walk so every element of `previous` that is still there
 * keeps its ref. An element is the same one when its role, name and identifier
 * match and it sits at the same place under the same kept ancestor, or when
 * that identity is unique in both walks (it moved). Every other element,
 * including one whose name changed, gets a ref from `nextRef` up, so a ref
 * that left the tree is never handed to another element.
 */
export function carryRefs(
  previous: readonly ElementTarget[],
  next: readonly ElementTarget[],
  nextRef: number,
): { readonly elements: ElementTarget[]; readonly nextRef: number } {
  const before = returnedParents(previous);
  const after = returnedParents(next);
  const beforeCounts = identityCounts(previous);
  const afterCounts = identityCounts(next);
  const beforeByIdentity = new Map(previous.map((element) => [identity(element), element]));
  const kept = new Map<ElementTarget, ElementTarget>();
  const taken = new Set<ElementTarget>();
  let fresh = nextRef;
  const elements = next.map((element) => {
    const id = identity(element);
    const parent = after.parents.get(element);
    const previousParent = parent && kept.get(parent);
    let match: ElementTarget | undefined;
    if (!parent || previousParent) {
      const path =
        parent && previousParent
          ? [...previousParent.path, ...element.path.slice(parent.path.length)]
          : element.path;
      const candidate = before.byPath.get(pathKey(path));
      if (
        candidate &&
        identity(candidate) === id &&
        before.parents.get(candidate) === previousParent
      )
        match = candidate;
    }
    if (
      !match &&
      (element.name || element.stableId) &&
      beforeCounts.get(id) === 1 &&
      afterCounts.get(id) === 1
    )
      match = beforeByIdentity.get(id);
    if (match && taken.has(match)) match = undefined;
    if (!match) return { ...element, ref: fresh++ };
    kept.set(element, match);
    taken.add(match);
    return { ...element, ref: match.ref };
  });
  return { elements, nextRef: fresh };
}

function header(snapshot: NativeSnapshot, snapshotId: string) {
  const notes = [
    `${snapshot.elements.length} elements`,
    snapshot.frontmost ? "app is frontmost" : "app is in the background",
    ...(snapshot.offscreen
      ? [`${snapshot.offscreen} offscreen skipped (includeOffscreen=true shows them)`]
      : []),
    ...(snapshot.nextOffset !== undefined ? [`more: pass offset=${snapshot.nextOffset}`] : []),
    ...(snapshot.truncated ? ["truncated: narrow with query, roles or root"] : []),
  ];
  return `${snapshot.app} snapshotId=${snapshotId} (${notes.join("; ")})`;
}

/** The text an agent reads for a snapshot. */
export function formatSnapshot(snapshot: NativeSnapshot, snapshotId: string): string {
  return [
    header(snapshot, snapshotId),
    ...(snapshot.menus?.length ? [`menus: ${snapshot.menus.join(" | ")}`] : []),
    ...snapshot.elements.map(formatElement),
  ].join("\n");
}

/** Sorted refs as runs, such as `4, 9-12`. */
function refRanges(refs: readonly number[]) {
  const runs: [number, number][] = [];
  for (const ref of refs.toSorted((a, b) => a - b)) {
    const last = runs.at(-1);
    if (last && ref === last[1] + 1) last[1] = ref;
    else runs.push([ref, ref]);
  }
  return runs.map(([start, end]) => (start === end ? `${start}` : `${start}-${end}`)).join(", ");
}

/**
 * What changed between two snapshots of the same view whose refs were carried
 * over: `~` lines are elements whose line changed, `+` lines are new elements,
 * both in tree order, then the refs that are gone.
 */
export function formatChanges(
  previous: NativeSnapshot,
  snapshot: NativeSnapshot,
  snapshotId: string,
): string {
  const before = new Map(previous.elements.map((element) => [element.ref, formatElement(element)]));
  const lines: string[] = [];
  for (const element of snapshot.elements) {
    const line = formatElement(element);
    const old = before.get(element.ref);
    if (old !== line) lines.push(`${old === undefined ? "+" : "~"} ${line}`);
    before.delete(element.ref);
  }
  if (before.size) lines.push(`removed: ${refRanges([...before.keys()])}`);
  const menus = snapshot.menus?.join(" | ") ?? "";
  if (menus !== (previous.menus?.join(" | ") ?? "")) lines.unshift(`menus: ${menus || "none"}`);
  return [
    header(snapshot, snapshotId),
    lines.length
      ? "Changes since the snapshot you acted on (~ changed, + new; other refs are unchanged):"
      : "No changes since the snapshot you acted on.",
    ...lines,
  ].join("\n");
}
