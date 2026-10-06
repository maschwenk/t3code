import { describe, expect, it } from "vite-plus/test";

import { localizeManifestString, pickIconPath } from "./manifest.ts";

describe("extension manifests", () => {
  it("resolves message placeholders case-insensitively", () => {
    expect(localizeManifestString("__MSG_appName__", { APPNAME: { message: "1Password" } })).toBe(
      "1Password",
    );
    expect(localizeManifestString("__MSG_missing__", {})).toBe("__MSG_missing__");
  });

  it("picks the smallest icon at least the requested size, else the largest", () => {
    const icons = { "16": "16.png", "48": "48.png", "128": "128.png" };
    expect(pickIconPath(icons, 32)).toBe("48.png");
    expect(pickIconPath(icons, 256)).toBe("128.png");
    expect(pickIconPath("icon.png", 16)).toBe("icon.png");
    expect(pickIconPath(undefined, 16)).toBeUndefined();
  });
});
