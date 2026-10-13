// Test entry only: the packager never includes this file. The product main and
// extension services run unchanged; real window events keep fixture UI hidden.
import { app } from "electron";
import * as NodeFSP from "node:fs/promises";
import * as NodePath from "node:path";
const evidence = process.env.T3_CHROMIUM_FIXTURE_EVIDENCE;
if (!evidence?.startsWith("/private/tmp/t3-native-evidence/"))
  throw new Error("Private fixture evidence required.");
await NodeFSP.mkdir(evidence, { recursive: true });
app.on("browser-window-created", (_event, window) => {
  window.setOpacity(0);
  window.setFocusable(false);
  window.webContents.setBackgroundThrottling(false);
  window.webContents.on("did-finish-load", () => {
    const contents = window.webContents;
    if (!contents.getURL().startsWith("chrome-extension://")) return;
    void (async () => {
      let text = "";
      const end = Date.now() + 15000;
      const ready = (value) => value.trim().length > 0 && !/^Loading[.…]*$/i.test(value.trim());
      while (!ready(text) && Date.now() < end && !contents.isDestroyed()) {
        text = await contents.executeJavaScript('document.body?.innerText??""');
        if (!ready(text)) await new Promise((resolve) => setTimeout(resolve, 25));
      }
      const report = {
        url: contents.getURL(),
        title: contents.getTitle(),
        text: text.slice(0, 12000),
        uiReady: ready(text),
        visible: window.isVisible(),
        opacity: window.getOpacity(),
      };
      await NodeFSP.writeFile(
        NodePath.join(evidence, "extension-ui.json"),
        JSON.stringify(report, null, 2),
      );
      try {
        const image = await contents.capturePage();
        await NodeFSP.writeFile(NodePath.join(evidence, "extension-ui.png"), image.toPNG());
      } catch (error) {
        await NodeFSP.writeFile(NodePath.join(evidence, "capture-limitation.txt"), String(error));
      }
    })().catch((error) => console.error("Fixture popup observation:", error));
  });
});
const observedSessions = new Set();
app.on("web-contents-created", (_event, contents) => {
  if (contents.getType() === "webview" && process.env.T3_CHROMIUM_FIXTURE_MOTION) {
    const motion = process.env.T3_CHROMIUM_FIXTURE_MOTION;
    if (!["no-preference", "reduce"].includes(motion))
      throw new Error("Invalid fixture motion preference.");
    contents.on("dom-ready", () => {
      if (!contents.debugger.isAttached()) contents.debugger.attach("1.3");
      void contents.debugger
        .sendCommand("Emulation.setEmulatedMedia", {
          features: [{ name: "prefers-reduced-motion", value: motion }],
        })
        .catch((error) => console.error("Fixture media emulation:", error));
    });
  }
  if (!observedSessions.has(contents.session)) {
    observedSessions.add(contents.session);
    contents.session.serviceWorkers.on("console-message", (_event, details) => {
      console.error("Fixture worker console:", JSON.stringify(details));
    });
  }
  contents.on("did-finish-load", () => {
    if (!contents.getURL().startsWith("chrome-extension://")) return;
    try {
      contents.debugger.attach("1.3");
      contents.debugger.on("message", (_event, method, details) => {
        if (method === "Runtime.exceptionThrown")
          console.error("Fixture popup exception:", JSON.stringify(details));
      });
      void contents.debugger
        .sendCommand("Runtime.enable")
        .catch((error) => console.error("Fixture exception listener:", error));
    } catch (error) {
      console.error("Fixture exception listener:", error);
    }
  });
  contents.on("console-message", (details) => {
    if (contents.getURL().startsWith("chrome-extension://"))
      console.error(
        "Fixture extension console:",
        JSON.stringify({
          level: details.level,
          message: details.message,
          sourceId: details.sourceId,
          lineNumber: details.lineNumber,
        }),
      );
  });
});
await import("./main.mjs");
