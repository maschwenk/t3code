/**
 * Reading the parts of a Chrome extension manifest the browser chrome needs:
 * its display name (often a `__MSG_name__` placeholder resolved from
 * `_locales`), icons and toolbar button.
 */
export interface ExtensionIconSet {
  readonly [size: string]: string;
}

export interface ExtensionActionManifest {
  readonly default_title?: string;
  readonly default_popup?: string;
  readonly default_icon?: string | ExtensionIconSet;
}

export interface ExtensionManifest {
  readonly manifest_version?: number;
  readonly name?: string;
  readonly short_name?: string;
  readonly version?: string;
  readonly description?: string;
  readonly default_locale?: string;
  readonly key?: string;
  readonly icons?: ExtensionIconSet;
  readonly action?: ExtensionActionManifest;
  readonly browser_action?: ExtensionActionManifest;
  readonly permissions?: ReadonlyArray<string>;
  readonly optional_permissions?: ReadonlyArray<string>;
  readonly host_permissions?: ReadonlyArray<string>;
  readonly optional_host_permissions?: ReadonlyArray<string>;
  readonly options_page?: string;
  readonly options_ui?: { readonly page?: string };
  readonly theme?: unknown;
  readonly app?: unknown;
}

export type ExtensionMessages = Readonly<Record<string, { readonly message?: string }>>;

/** Replaces `__MSG_key__` placeholders; Chrome matches message keys case-insensitively. */
export function localizeManifestString(value: string, messages: ExtensionMessages): string {
  return value.replace(/__MSG_(\w+)__/g, (placeholder, key: string) => {
    const wanted = key.toLowerCase();
    const entry = Object.entries(messages).find(([name]) => name.toLowerCase() === wanted);
    return entry?.[1].message ?? placeholder;
  });
}

/** The toolbar button, from MV3 `action` or MV2 `browser_action`. */
export function manifestAction(manifest: ExtensionManifest): ExtensionActionManifest | null {
  return manifest.action ?? manifest.browser_action ?? null;
}

/**
 * The icon file to draw at `size` pixels: the smallest declared icon at least
 * that large, else the largest. Paths are relative to the extension root.
 */
export function pickIconPath(
  icons: string | ExtensionIconSet | undefined,
  size: number,
): string | undefined {
  if (icons === undefined) return undefined;
  if (typeof icons === "string") return icons;
  const sizes = Object.keys(icons)
    .map(Number)
    .filter((candidate) => Number.isFinite(candidate))
    .toSorted((a, b) => a - b);
  const chosen = sizes.find((candidate) => candidate >= size) ?? sizes.at(-1);
  return chosen === undefined ? undefined : icons[String(chosen)];
}

/** Extensions T3 Code can run: not themes or legacy hosted apps. */
export function isBrowserExtension(manifest: ExtensionManifest): boolean {
  return manifest.theme === undefined && manifest.app === undefined;
}
