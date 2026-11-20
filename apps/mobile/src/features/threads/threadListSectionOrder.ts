import { SIDEBAR_SECTION_KEYS, type SidebarSectionKey } from "@t3tools/contracts/settings";

/** Mobile keeps Working below the active list until the user moves it; desktop puts it first. */
export const DEFAULT_THREAD_LIST_SECTION_ORDER: readonly SidebarSectionKey[] = [
  "active",
  "working",
  "snoozed",
  "settled",
];

export const THREAD_LIST_SECTION_LABELS: Record<SidebarSectionKey, string> = {
  working: "Working",
  active: "Pinned and active",
  snoozed: "Snoozed",
  settled: "Settled",
};

function isSidebarSectionKey(key: string): key is SidebarSectionKey {
  return SIDEBAR_SECTION_KEYS.some((candidate) => candidate === key);
}

/** Top-to-bottom order of the thread list sections from the stored preference.
    Unknown and repeated keys drop, and keys the list lacks follow in default
    order, so an older or hand-edited preference still shows every section. */
export function resolveThreadListSectionOrder(
  stored: readonly string[] | undefined,
): SidebarSectionKey[] {
  const order = new Set<SidebarSectionKey>((stored ?? []).filter(isSidebarSectionKey));
  for (const key of DEFAULT_THREAD_LIST_SECTION_ORDER) order.add(key);
  return [...order];
}

export function isDefaultThreadListSectionOrder(stored: readonly string[] | undefined): boolean {
  return resolveThreadListSectionOrder(stored).every(
    (key, index) => key === DEFAULT_THREAD_LIST_SECTION_ORDER[index],
  );
}

/** Moves one section a step up or down; a move past either end leaves the order as it was. */
export function moveThreadListSection(
  stored: readonly string[] | undefined,
  section: SidebarSectionKey,
  offset: -1 | 1,
): SidebarSectionKey[] {
  const order = resolveThreadListSectionOrder(stored);
  const from = order.indexOf(section);
  const to = from + offset;
  if (from < 0 || to < 0 || to >= order.length) return order;
  order.splice(from, 1);
  order.splice(to, 0, section);
  return order;
}
