import { EnvironmentId } from "@t3tools/contracts";
import { describe, expect, it, vi } from "vite-plus/test";

vi.mock(import("~/env"), async (original) => ({ ...(await original()), isElectron: true }));

import { rendersServerTabNatively } from "./previewRuntime";

describe("rendersServerTabNatively", () => {
  const primary = EnvironmentId.make("primary");

  it("leaves a desktop popup to the window its page opened, which alone keeps the opener", () => {
    expect(rendersServerTabNatively(primary, primary, { runtime: "server" })).toBe(true);
    expect(
      rendersServerTabNatively(primary, primary, { runtime: "server", openerTabId: "tab_1" }),
    ).toBe(false);
  });
});
