/**
 * Chrome's match patterns (`https://*.example.com/*`, `<all_urls>`), as
 * `tabs.query({ url })` and similar filters use them.
 */
const ALL_URLS_SCHEMES = new Set(["http", "https", "ws", "wss", "file", "ftp"]);

const escapeRegExp = (value: string) => value.replace(/[.+?^${}()|[\]\\]/g, "\\$&");

/** A glob where `*` matches any run of characters, and nothing else is special. */
export const globToRegExp = (glob: string): RegExp =>
  new RegExp(`^${glob.split("*").map(escapeRegExp).join(".*")}$`, "s");

export function matchesUrlPattern(pattern: string, url: string): boolean {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return false;
  }
  const scheme = parsed.protocol.slice(0, -1);
  if (pattern === "<all_urls>") return ALL_URLS_SCHEMES.has(scheme);

  const match = /^(\*|[a-z][a-z0-9+.-]*):\/\/([^/]*)(\/.*)$/.exec(pattern);
  if (!match) return false;
  const patternScheme = match[1] ?? "";
  const patternHostWithPort = match[2] ?? "";
  const patternPath = match[3] ?? "/";
  if (patternScheme === "*" ? scheme !== "http" && scheme !== "https" : patternScheme !== scheme) {
    return false;
  }
  // Chrome ignores the port unless the pattern names one.
  const portIndex = patternHostWithPort.lastIndexOf(":");
  const hasPort = portIndex > 0 && !patternHostWithPort.endsWith("]");
  const patternHost = hasPort ? patternHostWithPort.slice(0, portIndex) : patternHostWithPort;
  if (hasPort) {
    const patternPort = patternHostWithPort.slice(portIndex + 1);
    if (patternPort !== "*" && patternPort !== parsed.port) return false;
  }
  if (scheme !== "file" && patternHost !== "*") {
    if (patternHost.startsWith("*.")) {
      const base = patternHost.slice(2);
      if (parsed.hostname !== base && !parsed.hostname.endsWith(`.${base}`)) return false;
    } else if (parsed.hostname !== patternHost) {
      return false;
    }
  }
  return globToRegExp(patternPath).test(`${parsed.pathname}${parsed.search}`);
}
