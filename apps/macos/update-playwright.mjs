// Extract the same pinned injected selector engine used by the Electron client.
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";
import * as NodeVM from "node:vm";
import * as NodeCrypto from "node:crypto";
const root = NodePath.dirname(NodeURL.fileURLToPath(import.meta.url));
const source = NodePath.resolve(process.argv[2] ?? "apps/desktop/node_modules/playwright-core");
const pkg = JSON.parse(NodeFS.readFileSync(NodePath.resolve(source, "package.json"), "utf8"));
if (pkg.name !== "playwright-core" || pkg.version !== "1.60.0")
  throw Error("Expected playwright-core 1.60.0");
const bundle = NodeFS.readFileSync(NodePath.resolve(source, "lib/coreBundle.js"), "utf8");
const marker = "source3 = ";
const start = bundle.indexOf(marker);
const end = bundle.indexOf(";\n  }\n});", start);
if (start < 0 || end < 0) throw Error("Injected runtime was not found");
const script = NodeVM.runInNewContext(
  bundle.slice(start + marker.length, end),
  Object.create(null),
  { timeout: 1000 },
);
if (typeof script !== "string" || script.length < 100000) throw Error("Invalid injected runtime");
NodeFS.writeFileSync(
  NodePath.resolve(root, "Sources/T3Native/Resources/PlaywrightInjected.js"),
  script,
);
NodeFS.writeFileSync(NodePath.resolve(root, "Vendor/PLAYWRIGHT_VERSION"), pkg.version + "\n");
NodeFS.writeFileSync(
  NodePath.resolve(root, "Vendor/PLAYWRIGHT_SHA256"),
  NodeCrypto.createHash("sha256").update(script).digest("hex") +
    "  Sources/T3Native/Resources/PlaywrightInjected.js\n",
);
for (const file of ["LICENSE", "NOTICE"])
  NodeFS.copyFileSync(
    NodePath.resolve(source, file),
    NodePath.resolve(root, "Licenses/playwright-" + file + ".txt"),
  );
