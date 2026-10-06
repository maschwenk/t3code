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
export function intersect(rect: Rect, clip: Rect): Rect | null {
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

/** The text an agent reads for a snapshot. */
export function formatSnapshot(snapshot: NativeSnapshot, snapshotId: string): string {
  const notes = [
    `${snapshot.elements.length} elements`,
    snapshot.frontmost ? "app is frontmost" : "app is in the background",
    ...(snapshot.offscreen
      ? [`${snapshot.offscreen} offscreen skipped (includeOffscreen=true shows them)`]
      : []),
    ...(snapshot.nextOffset !== undefined ? [`more: pass offset=${snapshot.nextOffset}`] : []),
    ...(snapshot.truncated ? ["truncated: narrow with query, roles or root"] : []),
  ];
  return [
    `${snapshot.app} snapshotId=${snapshotId} (${notes.join("; ")})`,
    ...(snapshot.menus?.length ? [`menus: ${snapshot.menus.join(" | ")}`] : []),
    ...snapshot.elements.map(formatElement),
  ].join("\n");
}
