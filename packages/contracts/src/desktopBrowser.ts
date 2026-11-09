import * as Schema from "effect/Schema";

import { TrimmedNonEmptyString } from "./baseSchemas.ts";

const TabKey = {
  threadId: TrimmedNonEmptyString,
  tabId: TrimmedNonEmptyString,
};

/** `scheme`: a URL no hardened window can load. `nested`: a popup's own popup. */
export const DesktopPopupBlockReason = Schema.Literals(["scheme", "nested"]);
export type DesktopPopupBlockReason = typeof DesktopPopupBlockReason.Type;

export const DesktopBrowserEvent = Schema.Union([
  Schema.Struct({ type: Schema.Literal("attached"), ...TabKey }),
  /** Its `<webview>` went away: closed, crashed, swapped, or devtools took the debugger. */
  Schema.Struct({ type: Schema.Literal("detached"), ...TabKey }),
  Schema.Struct({ type: Schema.Literal("cdp"), ...TabKey, message: Schema.String }),
  /** Its `<webview>` started or stopped being on screen in a desktop window. */
  Schema.Struct({ type: Schema.Literal("shown"), ...TabKey, shown: Schema.Boolean }),
  /** Its page opened a popup window; the window keeps its opener and waits for `adoptPopup`. */
  Schema.Struct({
    type: Schema.Literal("popup"),
    ...TabKey,
    popupId: TrimmedNonEmptyString,
    url: Schema.String,
  }),
  /** Its page asked for a window the desktop refused, so `window.open` returned null. */
  Schema.Struct({
    type: Schema.Literal("popupBlocked"),
    ...TabKey,
    url: Schema.String,
    reason: DesktopPopupBlockReason,
  }),
]);
export type DesktopBrowserEvent = typeof DesktopBrowserEvent.Type;

export const DesktopBrowserCommand = Schema.Union([
  Schema.Struct({ type: Schema.Literal("cdp"), ...TabKey, message: Schema.String }),
  Schema.Struct({ type: Schema.Literal("release"), ...TabKey }),
  Schema.Struct({
    type: Schema.Literal("pointer"),
    ...TabKey,
    phase: Schema.Literals(["move", "click"]),
    x: Schema.Finite,
    y: Schema.Finite,
  }),
  /** Whether an agent turn runs on the thread, so the tabs it uses stay focused between steps. */
  Schema.Struct({
    type: Schema.Literal("turn"),
    threadId: TrimmedNonEmptyString,
    active: Schema.Boolean,
  }),
  /** Attach the waiting popup window as this tab. */
  Schema.Struct({ type: Schema.Literal("adoptPopup"), ...TabKey, popupId: TrimmedNonEmptyString }),
  /** This popup tab's session ended; close its window. */
  Schema.Struct({ type: Schema.Literal("closePopup"), ...TabKey }),
]);
export type DesktopBrowserCommand = typeof DesktopBrowserCommand.Type;
