import { describe, expect, it } from "vite-plus/test";

import { globToRegExp, matchesUrlPattern } from "./urlPatterns.ts";

describe("extension match patterns", () => {
  it("matches the schemes <all_urls> covers", () => {
    expect(matchesUrlPattern("<all_urls>", "https://example.com/")).toBe(true);
    expect(matchesUrlPattern("<all_urls>", "http://localhost:3000/a")).toBe(true);
    expect(matchesUrlPattern("<all_urls>", "chrome-extension://abc/popup.html")).toBe(false);
    expect(matchesUrlPattern("<all_urls>", "not a url")).toBe(false);
  });

  it("treats a * scheme as http or https only", () => {
    expect(matchesUrlPattern("*://example.com/*", "https://example.com/login")).toBe(true);
    expect(matchesUrlPattern("*://example.com/*", "http://example.com/")).toBe(true);
    expect(matchesUrlPattern("*://example.com/*", "ws://example.com/")).toBe(false);
  });

  it("matches subdomains for *. hosts but not lookalike hosts", () => {
    const pattern = "https://*.okta.com/*";
    expect(matchesUrlPattern(pattern, "https://okta.com/")).toBe(true);
    expect(matchesUrlPattern(pattern, "https://acme.okta.com/signin")).toBe(true);
    expect(matchesUrlPattern(pattern, "https://evilokta.com/")).toBe(false);
  });

  it("ignores the port unless the pattern names one", () => {
    expect(matchesUrlPattern("http://localhost/*", "http://localhost:5173/")).toBe(true);
    expect(matchesUrlPattern("http://localhost:3000/*", "http://localhost:5173/")).toBe(false);
    expect(matchesUrlPattern("http://localhost:5173/*", "http://localhost:5173/x")).toBe(true);
  });

  it("matches the path and query as a glob", () => {
    expect(matchesUrlPattern("https://a.com/app/*", "https://a.com/app/x?y=1")).toBe(true);
    expect(matchesUrlPattern("https://a.com/app/*", "https://a.com/other")).toBe(false);
    expect(globToRegExp("Sign in*").test("Sign in · Acme")).toBe(true);
    expect(globToRegExp("a.b").test("axb")).toBe(false);
  });
});
