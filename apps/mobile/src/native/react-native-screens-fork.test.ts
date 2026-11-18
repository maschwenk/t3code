import * as NodeFS from "node:fs";
import * as NodeModule from "node:module";
import * as NodePath from "node:path";
import { describe, expect, it } from "vite-plus/test";

/**
 * deps/react-native-screens-*-duo-rail.tgz carries a header fix upstream T3 doesn't have yet. An upstream
 * sync that takes upstream's tarball drops it without any other failure, and the iPhone Duo's rail buttons
 * go back to staying blurred.
 */
describe("react-native-screens", () => {
  it("swaps header bar buttons without animation", () => {
    const root = NodePath.dirname(
      NodeModule.createRequire(__filename).resolve("react-native-screens/package.json"),
    );
    const source = NodeFS.readFileSync(
      NodePath.join(root, "ios/header/RNSHeaderCoordinator.mm"),
      "utf8",
    );
    expect(source).not.toMatch(/BarButtonItems:[^;]*animated:YES/);
    expect(source).toContain("reusingItem:");
  });
});
