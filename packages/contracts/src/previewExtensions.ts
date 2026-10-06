/**
 * Browser extensions for the in-app preview browser.
 *
 * Extensions are installed once and load into every persistent browser
 * profile; each profile keeps its own extension data (a password manager's
 * sign-in, for example). Incognito profiles run without extensions, as in
 * Chrome by default.
 *
 * @module PreviewExtensions
 */
import * as Schema from "effect/Schema";
import { TrimmedNonEmptyString } from "./baseSchemas.ts";
import { BrowserImportSourceId } from "./browserImport.ts";

/** Chrome extension ids are 32 letters from a to p. */
export const PreviewExtensionId = Schema.String.check(Schema.isPattern(/^[a-p]{32}$/));
export type PreviewExtensionId = typeof PreviewExtensionId.Type;

/** The toolbar button an extension declares with `action` (or MV2 `browser_action`). */
export const PreviewExtensionAction = Schema.Struct({
  title: Schema.String,
  badgeText: Schema.String,
  /** CSS color, or null for the browser default. */
  badgeBackgroundColor: Schema.NullOr(Schema.String),
  badgeTextColor: Schema.NullOr(Schema.String),
  /** PNG data URL; null when the extension ships no usable icon. */
  iconDataUrl: Schema.NullOr(Schema.String),
  hasPopup: Schema.Boolean,
  enabled: Schema.Boolean,
});
export type PreviewExtensionAction = typeof PreviewExtensionAction.Type;

export const PreviewExtensionSource = Schema.Union([
  Schema.Struct({ kind: Schema.Literal("browser"), sourceId: BrowserImportSourceId }),
  Schema.Struct({ kind: Schema.Literal("webStore") }),
]);
export type PreviewExtensionSource = typeof PreviewExtensionSource.Type;

export const PreviewExtension = Schema.Struct({
  id: PreviewExtensionId,
  name: TrimmedNonEmptyString,
  version: TrimmedNonEmptyString,
  enabled: Schema.Boolean,
  source: PreviewExtensionSource,
  iconDataUrl: Schema.NullOr(Schema.String),
  /** Absent for extensions without a toolbar button. */
  action: Schema.NullOr(PreviewExtensionAction),
  /** Why the extension failed to load in the browser, if it did. */
  loadError: Schema.NullOr(Schema.String),
});
export type PreviewExtension = typeof PreviewExtension.Type;

/** An extension installed in another browser on this machine. */
export const PreviewExtensionCandidate = Schema.Struct({
  id: PreviewExtensionId,
  name: TrimmedNonEmptyString,
  version: TrimmedNonEmptyString,
  description: Schema.String,
  iconDataUrl: Schema.NullOr(Schema.String),
  /** Already installed in T3 Code, at any version. */
  installed: Schema.Boolean,
});
export type PreviewExtensionCandidate = typeof PreviewExtensionCandidate.Type;

export const PreviewExtensionCandidateProfile = Schema.Struct({
  sourceId: BrowserImportSourceId,
  sourceName: TrimmedNonEmptyString,
  profileDirectory: TrimmedNonEmptyString,
  profileName: TrimmedNonEmptyString,
  extensions: Schema.Array(PreviewExtensionCandidate),
});
export type PreviewExtensionCandidateProfile = typeof PreviewExtensionCandidateProfile.Type;

/** Screen-independent rectangle of the toolbar button, in the window's CSS pixels. */
export const PreviewExtensionAnchor = Schema.Struct({
  x: Schema.Number,
  y: Schema.Number,
  width: Schema.Number,
  height: Schema.Number,
});
export type PreviewExtensionAnchor = typeof PreviewExtensionAnchor.Type;

export const DesktopPreviewExtensionsListInputSchema = Schema.Struct({
  /** The preview tab's webContents id; toolbar state can differ per tab. */
  tabWebContentsId: Schema.optional(Schema.Int),
});

export const DesktopPreviewExtensionImportInputSchema = Schema.Struct({
  sourceId: BrowserImportSourceId,
  profileDirectory: TrimmedNonEmptyString,
  extensionIds: Schema.Array(PreviewExtensionId),
});

export const DesktopPreviewExtensionWebStoreInputSchema = Schema.Struct({
  /** A Chrome Web Store URL or a bare extension id. */
  reference: TrimmedNonEmptyString,
});

export const DesktopPreviewExtensionIdInputSchema = Schema.Struct({
  extensionId: PreviewExtensionId,
});

export const DesktopPreviewExtensionSetEnabledInputSchema = Schema.Struct({
  extensionId: PreviewExtensionId,
  enabled: Schema.Boolean,
});

export const DesktopPreviewExtensionOpenPopupInputSchema = Schema.Struct({
  extensionId: PreviewExtensionId,
  tabWebContentsId: Schema.Int,
  anchor: PreviewExtensionAnchor,
});

/** Pulls the extension id out of a Chrome Web Store URL, or accepts a bare id. */
export function parseWebStoreExtensionId(reference: string): string | null {
  const trimmed = reference.trim();
  if (/^[a-p]{32}$/.test(trimmed)) return trimmed;
  try {
    const url = new URL(trimmed);
    if (url.hostname !== "chromewebstore.google.com" && url.hostname !== "chrome.google.com") {
      return null;
    }
    return url.pathname.split("/").find((segment) => /^[a-p]{32}$/.test(segment)) ?? null;
  } catch {
    return null;
  }
}
