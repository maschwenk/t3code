import { BrowserWindow, app, dialog, type WebContents } from "electron";

/**
 * Asks before a preview page hands a link to another app, as Chrome does for
 * `zoommtg:`, `slack:` or `com-okta-authenticator:` (Okta Verify's FastPass
 * fallback). Without this the request is silently denied and sign-in flows
 * that launch a desktop app stall.
 */

/** Schemes a page never gets to pass to the operating system. */
const BLOCKED_PROTOCOLS = new Set([
  "http:",
  "https:",
  "file:",
  "javascript:",
  "data:",
  "blob:",
  "about:",
  "vbscript:",
  "ms-msdt:",
  "search-ms:",
  "ms-officecmd:",
]);

/** Answers remembered for this run, by requesting site and scheme. */
const remembered = new Map<string, boolean>();

export async function confirmExternalProtocol(
  contents: WebContents,
  externalUrl: string | undefined,
  requestingUrl: string | undefined,
): Promise<boolean> {
  let target: URL;
  try {
    target = new URL(externalUrl ?? "");
  } catch {
    return false;
  }
  if (BLOCKED_PROTOCOLS.has(target.protocol)) return false;

  let site = "This page";
  try {
    site = new URL(requestingUrl ?? contents.getURL()).host || site;
  } catch {
    // Keep the generic wording.
  }
  const key = `${site}|${target.protocol}`;
  const answer = remembered.get(key);
  if (answer !== undefined) return answer;

  const scheme = target.protocol.slice(0, -1);
  const appName = app.getApplicationNameForProtocol(target.href);
  const host = contents.getType() === "webview" ? contents.hostWebContents : contents;
  const window = host && !host.isDestroyed() ? BrowserWindow.fromWebContents(host) : null;
  const options: Electron.MessageBoxOptions = {
    type: "question",
    buttons: ["Open", "Cancel"],
    defaultId: 0,
    cancelId: 1,
    message: appName ? `Open ${appName}?` : `Open this ${scheme} link?`,
    detail: `${site} wants to open ${appName || `an app for ${scheme} links`}.`,
    checkboxLabel: "Always allow this site to open these links",
  };
  const result = window
    ? await dialog.showMessageBox(window, options)
    : await dialog.showMessageBox(options);
  const allowed = result.response === 0;
  if (result.checkboxChecked) remembered.set(key, allowed);
  return allowed;
}
