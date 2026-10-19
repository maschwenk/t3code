import { app, BrowserWindow, ipcMain, dialog } from "electron";
import * as NodeFSP from "node:fs/promises";
import * as NodeCrypto from "node:crypto";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";
import * as NodeStringDecoder from "node:string_decoder";
import * as Effect from "effect/Effect";
import * as NodeEffectCrypto from "@effect/platform-node/NodeCrypto";
import { make as makeBrowserSessions } from "../../desktop/src/preview/BrowserSession.ts";
import { ExtensionHost } from "../../desktop/src/preview/extensions/ExtensionHost.ts";
import { ExtensionStore } from "../../desktop/src/preview/extensions/ExtensionStore.ts";
import { BROWSER_IMPORT_SOURCES } from "../../desktop/src/preview/BrowserImport/Sources.ts";
import { makePreviewAutomationKeySequence } from "../../desktop/src/preview/PreviewKeyboard.ts";
import {
  CommandDecoder,
  ONE_PASSWORD_ID,
  WIRE_PREFIX,
  pageURL,
  identity,
  stateDirectory,
  selectedProfile,
} from "./protocol.mjs";
import { cursorSource } from "./cursor.mjs";

const token = process.env.T3_CHROMIUM_TOKEN;
// oxlint-disable-next-line t3code/no-global-process-runtime -- Electron startup guard runs outside the Effect services.
const hostPlatform = NodeOS.platform();
// oxlint-disable-next-line t3code/no-global-process-runtime -- Electron startup guard runs outside the Effect services.
const hostArchitecture = NodeOS.arch();
if (
  hostPlatform !== "darwin" ||
  hostArchitecture !== "arm64" ||
  !/^[a-f0-9]{64}$/.test(token ?? "")
) {
  throw new Error("Launch the Apple Silicon helper from T3 Native.");
}
delete process.env.T3_CHROMIUM_TOKEN;
const decoder = new CommandDecoder(token);
const send = (value) =>
  process.stdout.write(WIRE_PREFIX + JSON.stringify({ token, ...value }) + "\n");
console.log = console.info = (...values) => console.error(...values);
const root = await stateDirectory(process.env.T3_CHROMIUM_STATE);
const downloadRoot = NodePath.join(root, "downloads");
await NodeFSP.mkdir(downloadRoot, { recursive: true, mode: 0o700 });
app.setName("T3 Browser");
app.setPath("userData", root);
app.setPath("sessionData", root);
const assets = NodePath.dirname(NodeURL.fileURLToPath(import.meta.url));
const injectedSource = await NodeFSP.readFile(
  NodePath.join(assets, "PlaywrightInjected.js"),
  "utf8",
);
const operationsSource = await NodeFSP.readFile(
  NodePath.join(assets, "BrowserAutomation.js"),
  "utf8",
);
const pages = new Map();
const creatingPages = new Map();
const downloads = new Map();
const downloadSessions = new Set();
let extensions,
  sessions,
  closing = false;
let commandCount = 0;
const key = (input) =>
  JSON.stringify([identity(input.environmentID), identity(input.threadId), identity(input.tabId)]);
const fail = (tag, message) => Object.assign(new Error(message), { _tag: tag });
function check(page, revision) {
  if (
    page.window.isDestroyed() ||
    page.guest?.isDestroyed() ||
    page.revision !== revision ||
    pages.get(page.key) !== page
  ) {
    throw fail("PreviewAutomationControlInterruptedError", "Browser control was interrupted.");
  }
}
async function isolated(page, code, guard) {
  const result = page.guest.executeJavaScriptInIsolatedWorld(997, [{ code }]);
  return guard ? guard.wait(result) : result;
}
async function state(page) {
  if (!page.guest || page.guest.isDestroyed()) return {};
  return {
    available: true,
    visible: page.window.isVisible(),
    windowId: page.window.id,
    tabId: page.tabId,
    threadId: page.threadId,
    environmentID: page.environmentID,
    url: page.guest.getURL(),
    title: page.guest.getTitle(),
    loading: page.guest.isLoading(),
    canGoBack: page.guest.navigationHistory.canGoBack(),
    canGoForward: page.guest.navigationHistory.canGoForward(),
    viewportSetting: page.viewport,
    viewport: await isolated(page, "({width:innerWidth,height:innerHeight})"),
    agentCursor: await isolated(page, "globalThis.__t3AgentCursor?.state()??null"),
  };
}
async function publish(page) {
  if (page.window.isDestroyed() || !page.guest || page.guest.isDestroyed()) return;
  const value = await state(page);
  if (page.window.isDestroyed()) return;
  page.window.webContents.send("t3-native-browser-state", value);
  send({ event: "page", value });
}
function interrupt(page, reason = "Browser control was interrupted.") {
  page.revision++;
  page.expectedInputs = [];
  for (const control of page.controls ?? []) control.cancel(reason);
  releaseInputs(page);
  page.agentDriven = false;
  if (page.guest && !page.guest.isDestroyed())
    void isolated(page, "globalThis.__t3AgentCursor?.hide()").catch(() => {});
  send({
    event: "interrupted",
    value: { environmentID: page.environmentID, threadId: page.threadId, tabId: page.tabId },
  });
}
function releaseInputs(page) {
  if (!page.guest || page.guest.isDestroyed() || !page.guest.debugger.isAttached()) return;
  const pressed = page.pressedMouse;
  page.pressedMouse = null;
  if (pressed)
    void page.guest.debugger
      .sendCommand("Input.dispatchMouseEvent", { ...pressed, type: "mouseReleased" })
      .catch(() => {});
  const keyUp = page.pressedKey;
  page.pressedKey = null;
  if (keyUp) void page.guest.debugger.sendCommand("Input.dispatchKeyEvent", keyUp).catch(() => {});
}
async function createPage(input) {
  const id = key(input);
  if (creatingPages.has(id)) return creatingPages.get(id);
  const existing = pages.get(id);
  if (existing) return existing;
  const initialURL = pageURL(input.url ?? "about:blank");
  const creation = createPageOwned(input, id, initialURL);
  creatingPages.set(id, creation);
  try {
    return await creation;
  } catch (error) {
    const page = pages.get(id);
    if (page && !page.window.isDestroyed()) page.window.destroy();
    throw error;
  } finally {
    if (creatingPages.get(id) === creation) creatingPages.delete(id);
  }
}
async function createPageOwned(input, id, initialURL) {
  const profileId = identity(input.profileId ?? "default");
  const scope = identity(input.environmentID) + "\u0000" + profileId;
  const partition = await Effect.runPromise(
    sessions.getPartition(scope, profileId !== "incognito", "profile"),
  );
  const browserSession = await Effect.runPromise(
    sessions.getSession(scope, profileId !== "incognito", "profile"),
  );
  await extensions.attachSession(browserSession);
  installDownloads(browserSession);
  const window = new BrowserWindow({
    width: 1100,
    height: 800,
    minWidth: 620,
    minHeight: 400,
    show: false,
    title: "T3 Browser · 1Password",
    alwaysOnTop: true,
    webPreferences: {
      preload: NodePath.join(assets, "shell-preload.cjs"),
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true,
      webviewTag: true,
    },
  });
  const page = {
    key: id,
    window,
    partition,
    threadId: input.threadId,
    tabId: input.tabId,
    environmentID: input.environmentID,
    profileId,
    viewport: input.viewport ?? { width: null, height: null },
    revision: 0,
    documentRevision: 0,
    controls: new Set(),
    expectedInputs: [],
    synthetic: 0,
    agentDriven: false,
    actions: [],
  };
  pages.set(id, page);
  window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  window.webContents.on("will-navigate", (event) => event.preventDefault());
  window.webContents.on("will-attach-webview", (event, preferences, params) => {
    if (params.partition !== partition || !safeURL(params.src)) {
      event.preventDefault();
      return;
    }
    delete preferences.preload;
    preferences.nodeIntegration = false;
    preferences.nodeIntegrationInSubFrames = false;
    preferences.contextIsolation = true;
    preferences.sandbox = true;
    preferences.webSecurity = true;
  });
  page.attached = new Promise((resolveAttached, reject) => {
    const timer = setTimeout(() => reject(new Error("The Chromium page did not attach.")), 20000);
    window.once("closed", () => {
      clearTimeout(timer);
      reject(new Error("The Chromium page was closed."));
    });
    window.webContents.once("did-attach-webview", (_event, guest) => {
      clearTimeout(timer);
      page.guest = guest;
      guest.setWindowOpenHandler(({ url }) => {
        if (safeURL(url))
          send({
            event: "newPage",
            value: {
              environmentID: page.environmentID,
              threadId: page.threadId,
              tabId: page.tabId,
              url,
            },
          });
        return { action: "deny" };
      });
      guest.on("will-navigate", (details) => {
        if (!safeURL(details.url)) details.preventDefault();
      });
      guest.on("will-redirect", (details) => {
        if (!safeURL(details.url)) details.preventDefault();
      });
      guest.ipc.on("t3-native-browser-human-input", (event, signal) => {
        if (
          event.senderFrame !== guest.mainFrame ||
          !signal ||
          !["pointer", "key", "wheel"].includes(signal.kind)
        )
          return;
        const now = Date.now();
        page.expectedInputs = page.expectedInputs.filter((input) => now - input.at < 750);
        const expected = page.expectedInputs.findIndex(
          (input) =>
            input.kind === signal.kind &&
            (signal.kind === "pointer"
              ? signal.button === 0 &&
                Math.abs(input.x - signal.x) < 1 &&
                Math.abs(input.y - signal.y) < 1
              : signal.kind === "key"
                ? input.key === signal.key && input.code === signal.code
                : false),
        );
        if (expected >= 0) {
          page.expectedInputs.splice(expected, 1);
          return;
        }
        interrupt(page, "Browser control was interrupted by manual " + signal.kind + " input.");
      });
      guest.on("did-start-navigation", (details) => {
        if (details.isMainFrame) {
          page.documentRevision++;
          for (const control of page.controls)
            if (!control.allowNavigation) control.cancel("The browser document changed.");
          releaseInputs(page);
          void isolated(page, "globalThis.__t3AgentCursor?.hide()").catch(() => {});
        }
      });
      for (const name of [
        "did-navigate",
        "did-navigate-in-page",
        "page-title-updated",
        "did-stop-loading",
      ]) {
        guest.on(name, () => void publish(page).catch(() => {}));
      }
      resolveAttached(guest);
    });
  });
  // The renderer gets a partition only from this private, authenticated owner.
  page.initialURL = initialURL;
  window.on("close", (event) => {
    if (
      !closing &&
      !page.allowClose &&
      [...downloads.values()].some((download) => download.page === page)
    ) {
      event.preventDefault();
      void dialog
        .showMessageBox(window, {
          type: "question",
          message: "Downloads are still running",
          detail: "Closing this page cancels its downloads.",
          buttons: ["Keep downloading", "Close and cancel downloads"],
          defaultId: 0,
          cancelId: 0,
        })
        .then(({ response }) => {
          if (response === 1) {
            for (const download of downloads.values())
              if (download.page === page) download.item.cancel();
            page.allowClose = true;
            window.destroy();
          }
        });
    }
  });
  window.once("closed", () => {
    interrupt(page);
    if (pages.get(id) === page) pages.delete(id);
    send({
      event: "closed",
      value: { environmentID: page.environmentID, threadId: page.threadId, tabId: page.tabId },
    });
  });
  await window.loadFile(NodePath.join(assets, "shell.html"));
  await page.attached;
  if (input.show !== false) window.show();
  return page;
}
function safeURL(url) {
  try {
    pageURL(url);
    return true;
  } catch {
    return false;
  }
}
function installDownloads(session) {
  if (downloadSessions.has(session)) return;
  downloadSessions.add(session);
  session.registerPreloadScript({
    id: "t3-native-browser-human-input",
    type: "frame",
    filePath: NodePath.join(assets, "guest-input.cjs"),
  });
  session.on("will-download", (_event, item, source) => {
    const page = [...pages.values()].find((page) => page.guest === source);
    if (!page) {
      item.cancel();
      return;
    }
    const id = NodeCrypto.randomUUID(),
      status = {
        id,
        environmentID: page.environmentID,
        threadId: page.threadId,
        tabId: page.tabId,
        name:
          NodePath.basename(item.getFilename())
            .split("")
            .filter((character) => character.charCodeAt(0) > 31)
            .join("")
            .slice(0, 180) || "download",
        state: "downloading",
      };
    const managed = page.agentDriven ? NodePath.join(downloadRoot, id + "-" + status.name) : null;
    if (managed) item.setSavePath(managed);
    let finish;
    const done = new Promise((resolve) => {
      finish = resolve;
    });
    const download = { item, page, status, done };
    downloads.set(id, download);
    send({ event: "download", value: status });
    item.on("updated", () => {
      status.receivedBytes = item.getReceivedBytes();
      status.totalBytes = item.getTotalBytes();
    });
    item.once("done", async (_event, state) => {
      downloads.delete(id);
      status.state = state;
      if (state === "completed") status.path = item.getSavePath();
      else if (managed) await NodeFSP.rm(managed, { force: true }).catch(() => {});
      send({ event: "download", value: status });
      finish();
    });
    // Human downloads keep the native Save dialog; agent downloads use a unique
    // managed file and remove incomplete bytes on cancellation.
  });
}
async function query(page, operation, input, documentIdentity, guard) {
  const injected = injectedSource,
    operations = operationsSource;
  return isolated(
    page,
    `(async()=>{if(${JSON.stringify(documentIdentity ?? null)}!==null && globalThis.__t3DocumentIdentity!==${JSON.stringify(documentIdentity ?? null)})throw new Error('Browser document changed.');if(!globalThis.__t3PlaywrightInjected){const module={exports:{}};${injected}\nglobalThis.__t3PlaywrightInjected=new(module.exports.InjectedScript())(globalThis,{isUnderTest:false,sdkLanguage:'javascript',testIdAttributeName:'data-testid',stableRafCount:1,browserName:'chromium',shouldPrependErrorPrefix:false,isUtilityWorld:true,customEngines:[]});}const operation=${JSON.stringify(operation)},input=${JSON.stringify(input)};return(await(async()=>{${operations}\n})());})()`,
    guard,
  );
}
async function move(page, point, label, guard) {
  guard();
  if (!point || !Number.isFinite(point.x) || !Number.isFinite(point.y)) return;
  try {
    await isolated(page, cursorSource, guard);
    guard();
    await isolated(
      page,
      `globalThis.__t3AgentCursor.move(${point.x},${point.y},${JSON.stringify(label)})`,
      guard,
    );
    guard();
  } catch (error) {
    if (page.guest && !page.guest.isDestroyed())
      void isolated(page, "globalThis.__t3AgentCursor?.hide()").catch(() => {});
    throw error;
  }
}
async function automate(page, operation, input, timeout = 60000) {
  await page.attached;
  const revision = page.revision,
    documentRevision = page.documentRevision;
  const end = Date.now() + Math.min(60000, Math.max(1, timeout));
  const guard = () => {
    check(page, revision);
    if (operation !== "navigate" && page.documentRevision !== documentRevision)
      throw fail("PreviewAutomationControlInterruptedError", "The browser document changed.");
    if (Date.now() > end)
      throw fail("PreviewAutomationTimeoutError", "Browser operation timed out.");
  };
  guard();
  let rejectControl;
  const interrupted = new Promise((_resolve, reject) => {
    rejectControl = reject;
  });
  void interrupted.catch(() => {});
  const control = {
    allowNavigation: operation === "navigate",
    cancel: (reason) =>
      rejectControl(
        fail(
          "PreviewAutomationControlInterruptedError",
          reason ?? "Browser control was interrupted.",
        ),
      ),
  };
  const timer = setTimeout(
    () => rejectControl(fail("PreviewAutomationTimeoutError", "Browser operation timed out.")),
    Math.max(1, end - Date.now()),
  );
  page.controls.add(control);
  guard.wait = (promise) => Promise.race([promise, interrupted]);
  try {
    return await automateGuarded(page, operation, input, guard);
  } finally {
    clearTimeout(timer);
    page.controls.delete(control);
  }
}
async function automateGuarded(page, operation, input, guard) {
  const documentIdentity =
    operation === "navigate"
      ? null
      : await isolated(
          page,
          `globalThis.__t3DocumentIdentity??=${JSON.stringify(NodeCrypto.randomUUID())}`,
          guard,
        );
  guard();
  if (!["status", "snapshot", "waitFor"].includes(operation)) page.agentDriven = true;
  if (operation === "status" || operation === "open") return guard.wait(state(page));
  if (operation === "navigate") {
    const readiness = input.readiness ?? "load";
    if (!["load", "domContentLoaded", "none"].includes(readiness))
      throw new Error("Invalid navigation readiness.");
    let ready, listener;
    if (readiness === "domContentLoaded")
      ready = new Promise((resolve) => {
        listener = resolve;
        page.guest.once("dom-ready", listener);
      });
    const navigation = page.guest.loadURL(pageURL(input.url));
    try {
      if (readiness === "none") void navigation.catch(() => {});
      else if (ready) await guard.wait(Promise.race([ready, navigation]));
      else await guard.wait(navigation);
    } finally {
      if (listener) page.guest.removeListener("dom-ready", listener);
    }
    // Intentional navigation adopts its destination; other actions remain bound
    // to the document/control revision captured before any selector lookup.
    guard();
    return guard.wait(state(page));
  }
  if (operation === "resize") {
    const width = input.viewport?.width ?? input.width,
      height = input.viewport?.height ?? input.height;
    if (width == null && height == null) {
      page.viewport = { width: null, height: null };
      return {
        tabId: page.tabId,
        setting: page.viewport,
        viewport: await isolated(page, "({width:innerWidth,height:innerHeight})"),
      };
    }
    if (
      !Number.isInteger(width) ||
      !Number.isInteger(height) ||
      width < 240 ||
      height < 240 ||
      width > 3840 ||
      height > 3840
    )
      throw new Error("Invalid Chromium viewport.");
    page.viewport = { width, height };
    const toolbar = await page.window.webContents.executeJavaScript(
      "document.querySelector('header').getBoundingClientRect().height+document.querySelector('#notice').getBoundingClientRect().height",
    );
    const zoom = page.guest.getZoomFactor();
    page.window.setContentSize(Math.round(width * zoom), Math.round(height * zoom + toolbar));
    let measured;
    do {
      guard();
      measured = await isolated(page, "({width:innerWidth,height:innerHeight})", guard);
      if (measured.width === width && measured.height === height) break;
      await new Promise((resolve) => setTimeout(resolve, 40));
    } while (measured.width !== width || measured.height !== height);
    return { tabId: page.tabId, setting: page.viewport, viewport: measured };
  }
  if (operation === "setColorScheme") {
    if (!["system", "dark", "light"].includes(input.colorScheme))
      throw new Error("Invalid color scheme.");
    if (!page.guest.debugger.isAttached()) page.guest.debugger.attach("1.3");
    await page.guest.debugger.sendCommand("Emulation.setEmulatedMedia", {
      features:
        input.colorScheme === "system"
          ? []
          : [{ name: "prefers-color-scheme", value: input.colorScheme }],
    });
    return { tabId: page.tabId, colorScheme: input.colorScheme };
  }
  if (operation === "evaluate") {
    if (input.returnByValue === false)
      throw fail(
        "PreviewAutomationUnsupportedClientError",
        "Remote object handles are not available.",
      );
    if (typeof input.expression !== "string") throw new Error("Missing JavaScript expression.");
    const result = await guard.wait(
      page.guest.executeJavaScript(
        `(async()=>{let value=(0,eval)(${JSON.stringify(input.expression)});${input.awaitPromise === false ? "" : "value=await value;"}return value??null;})()`,
      ),
    );
    guard();
    return result;
  }
  if (operation === "press") {
    await move(
      page,
      await query(page, "pointer", input, documentIdentity, guard),
      "Agent key",
      guard,
    );
    if (!page.guest.debugger.isAttached()) page.guest.debugger.attach("1.3");
    const sequence = makePreviewAutomationKeySequence(
      { ...input, threadId: page.threadId },
      { isMac: true },
    );
    page.synthetic++;
    try {
      guard();
      page.expectedInputs.push({ ...sequence.signal, at: Date.now() });
      page.pressedKey = sequence.keyUp;
      await guard.wait(page.guest.debugger.sendCommand("Input.dispatchKeyEvent", sequence.keyDown));
      guard();
      await guard.wait(page.guest.debugger.sendCommand("Input.dispatchKeyEvent", sequence.keyUp));
      page.pressedKey = null;
    } finally {
      releaseInputs(page);
      page.synthetic--;
    }
    guard();
    return null;
  }
  if (operation === "snapshot") {
    await isolated(page, "globalThis.__t3AgentCursor?.settle()", guard);
    const result = await query(page, "snapshot", input, documentIdentity, guard);
    guard();
    const image = await guard.wait(page.guest.capturePage());
    guard();
    const size = image.getSize(),
      bytes = image.toPNG();
    if (bytes.length > 16 * 1024 * 1024)
      throw fail(
        "PreviewAutomationResultTooLargeError",
        "Reduce the viewport to capture this page.",
      );
    return {
      ...result,
      tabId: page.tabId,
      actionTimeline: page.actions,
      screenshot: { mimeType: "image/png", data: bytes.toString("base64"), ...size },
    };
  }
  if (["recordingStart", "recordingStop"].includes(operation))
    throw fail(
      "PreviewAutomationUnsupportedClientError",
      "Chromium recording is not available yet; use the native browser recorder.",
    );
  if (!["click", "type", "scroll", "waitFor"].includes(operation))
    throw fail("PreviewAutomationUnsupportedClientError", "Unsupported browser operation.");
  if (operation !== "waitFor")
    await move(
      page,
      await query(page, "pointer", input, documentIdentity, guard),
      operation === "type" ? "Agent typing" : "Agent",
      guard,
    );
  while (true) {
    guard();
    const result = await query(page, operation, input, documentIdentity, guard);
    guard();
    if (result?.error) throw fail(result.error._tag, result.error.message);
    if (result?.pending) {
      await new Promise((resolve) => setTimeout(resolve, 50));
      continue;
    }
    if (operation === "click") {
      await move(page, result, "Agent", guard);
      const final = await query(page, "click", input, documentIdentity, guard);
      guard();
      if (final?.pending) continue;
      if (final?.error) throw fail(final.error._tag, final.error.message);
      await move(page, final, "Agent", guard);
      const viewport = await isolated(page, "({width:innerWidth,height:innerHeight})", guard);
      guard();
      if (
        !Number.isFinite(final.x) ||
        !Number.isFinite(final.y) ||
        final.x < 0 ||
        final.y < 0 ||
        final.x >= viewport.width ||
        final.y >= viewport.height
      )
        throw new Error("Click is outside the page viewport.");
      if (!page.guest.debugger.isAttached()) page.guest.debugger.attach("1.3");
      page.synthetic++;
      try {
        guard();
        await guard.wait(
          page.guest.debugger.sendCommand("Input.dispatchMouseEvent", {
            type: "mouseMoved",
            x: final.x,
            y: final.y,
          }),
        );
        guard();
        page.expectedInputs.push({ kind: "pointer", x: final.x, y: final.y, at: Date.now() });
        page.pressedMouse = { x: final.x, y: final.y, button: "left", clickCount: 1 };
        await guard.wait(
          page.guest.debugger.sendCommand("Input.dispatchMouseEvent", {
            ...page.pressedMouse,
            type: "mousePressed",
          }),
        );
        guard();
        await guard.wait(
          page.guest.debugger.sendCommand("Input.dispatchMouseEvent", {
            ...page.pressedMouse,
            type: "mouseReleased",
          }),
        );
        page.pressedMouse = null;
      } finally {
        releaseInputs(page);
        page.synthetic--;
      }
      guard();
      await isolated(page, "globalThis.__t3AgentCursor?.click()", guard);
      guard();
      return null;
    }
    return operation === "waitFor" ? null : result;
  }
}
async function flushSessions() {
  await Promise.all(
    [...downloadSessions]
      .filter((session) => session.isPersistent())
      .map(async (session) => {
        await session.cookies.flushStore();
        session.flushStorageData();
      }),
  );
}
async function cancelDownloads() {
  const active = [...downloads.values()];
  for (const download of active) download.item.cancel();
  await Promise.all(active.map((download) => download.done));
}
async function command(method, input) {
  if (method === "hello") return { version: 1, engine: "chromium", extensionId: ONE_PASSWORD_ID };
  if (method === "stopHelper") {
    closing = true;
    extensions.dispose();
    await cancelDownloads();
    await flushSessions();
    for (const page of pages.values()) page.window.destroy();
    setImmediate(() => app.quit());
    return null;
  }
  if (method === "install") {
    await extensions.installFromWebStore(ONE_PASSWORD_ID);
    return extensions.list();
  }
  if (method === "import") {
    const requested = NodePath.resolve(input.profilePath ?? "");
    // Imports are only reachable through an explicit native file chooser; only
    // the selected extension package is copied, never cookies or vault state.
    for (const source of BROWSER_IMPORT_SOURCES.filter((source) => source.engine === "chromium")) {
      const root = source.userDataDirectory({
        platform: "darwin",
        home: NodeOS.homedir(),
        path: { join: NodePath.join },
      });
      if (!root || NodePath.dirname(requested) !== root) continue;
      const profilePath = await selectedProfile(root, NodePath.basename(requested));
      await extensions.importFromProfile({
        profilePath,
        source: { kind: "browser", sourceId: source.id },
        extensionIds: [ONE_PASSWORD_ID],
      });
      return extensions.list();
    }
    throw new Error(
      "Select a Chrome, Edge, Brave, Vivaldi, Opera or Arc profile containing 1Password.",
    );
  }
  if (method === "removeExtension") {
    await extensions.remove(ONE_PASSWORD_ID);
    return extensions.list();
  }
  if (method === "clearProfile") {
    const profileId = identity(input.profileId),
      environment = identity(input.environmentID),
      scope = environment + "\u0000" + profileId;
    if (!["all", "cookies", "cache"].includes(input.kinds))
      throw new Error("Invalid profile clear.");
    const browserSession = await Effect.runPromise(
      sessions.getSession(scope, profileId !== "incognito", "profile"),
    );
    for (const page of pages.values())
      if (page.environmentID === environment && page.profileId === profileId) interrupt(page);
    if (input.kinds === "cache") await browserSession.clearCache();
    else if (input.kinds === "all") await browserSession.clearStorageData();
    else {
      const partition = await Effect.runPromise(
        sessions.getPartition(scope, profileId !== "incognito", "profile"),
      );
      await Effect.runPromise(sessions.clearCookies([partition]));
    }
    return null;
  }
  if (method === "extensions") return extensions.list();
  if (method === "downloads") return [...downloads.values()].map((download) => download.status);
  if (method === "cancelDownloads") {
    await cancelDownloads();
    return null;
  }
  if (method === "open") {
    const page = await createPage(input);
    return state(page);
  }
  const page = pages.get(key(input));
  if (!page)
    throw fail("PreviewAutomationTabNotFoundError", "The Chromium page is no longer open.");
  if (method === "close") {
    page.window.close();
    return null;
  }
  if (method === "stop") {
    interrupt(page);
    return null;
  }
  if (method === "reveal") {
    page.window.show();
    page.window.focus();
    return state(page);
  }
  if (method === "popup") {
    interrupt(page);
    if (page.profileId === "incognito")
      throw new Error("1Password is unavailable in private profiles.");
    const revision = page.revision;
    const password = (await extensions.list(page.guest.id)).find(
      (extension) => extension.id === ONE_PASSWORD_ID,
    );
    check(page, revision);
    if (!password?.enabled)
      throw new Error("Install the 1Password extension in Browser Settings first.");
    if (password.loadError) throw new Error(password.loadError);
    const startupDeadline = Date.now() + 15000;
    // 1Password chooses onboarding or its account popup after worker startup.
    // Opening the manifest default earlier can leave a popup waiting forever.
    while (!extensions.hasActionPopupOverride(page.guest.id, ONE_PASSWORD_ID)) {
      check(page, revision);
      if (Date.now() >= startupDeadline)
        throw new Error("1Password is still initializing. Try opening it again.");
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    check(page, revision);
    const anchor = input.anchor ?? {
      x: page.window.getContentBounds().width - 300,
      y: 8,
      width: 90,
      height: 32,
    };
    if (
      !["x", "y", "width", "height"].every(
        (key) => Number.isFinite(anchor[key]) && Math.abs(anchor[key]) < 10000,
      )
    )
      throw new Error("Invalid popup anchor.");
    await extensions.openPopup({
      extensionId: ONE_PASSWORD_ID,
      tabWebContentsId: page.guest.id,
      ownerWebContentsId: page.window.webContents.id,
      anchor,
    });
    return null;
  }
  if (method === "zoom") {
    interrupt(page);
    const zoom = input.factor ?? page.guest.getZoomFactor() + (input.delta ?? 0);
    if (!Number.isFinite(zoom) || zoom < 0.25 || zoom > 5)
      throw new Error("Browser zoom must be between 25% and 500%.");
    page.guest.setZoomFactor(zoom);
    return state(page);
  }
  if (method === "back") {
    interrupt(page);
    page.guest.navigationHistory.goBack();
    return null;
  }
  if (method === "forward") {
    interrupt(page);
    page.guest.navigationHistory.goForward();
    return null;
  }
  if (method === "reload") {
    interrupt(page);
    page.guest.reload();
    return null;
  }
  if (method === "navigate") return automate(page, "navigate", input);
  if (method === "automation") {
    const action = {
      id: NodeCrypto.randomUUID(),
      action: input.operation,
      status: "running",
      startedAt: new Date().toISOString(),
    };
    page.actions.push(action);
    if (page.actions.length > 50) page.actions.shift();
    try {
      const result = await automate(page, input.operation, input.input ?? {}, input.timeoutMs);
      action.status = "succeeded";
      return result;
    } catch (error) {
      action.status =
        error._tag === "PreviewAutomationControlInterruptedError" ? "interrupted" : "failed";
      action.error = error.message;
      throw error;
    } finally {
      action.completedAt = new Date().toISOString();
    }
  }
  throw new Error("Unknown helper command.");
}
async function start() {
  sessions = await Effect.runPromise(
    makeBrowserSessions.pipe(Effect.provide(NodeEffectCrypto.layer)),
  );
  extensions = new ExtensionHost({
    store: new ExtensionStore(NodePath.join(root, "browser-extensions")),
    preloadPath: NodePath.join(assets, "preview-extension-preload.cjs"),
    platform: "darwin",
    homeDirectory: NodeOS.homedir(),
    chromeVersion: process.versions.chrome,
    onChange: () =>
      void extensions
        .list()
        .then((value) => send({ event: "extensions", value }))
        .catch(() => {}),
    log: (message) => console.error(message),
  });
  ipcMain.handle("t3-native-browser-toolbar", async (event, { method, input }) => {
    const page = [...pages.values()].find((page) => page.window.webContents === event.sender);
    if (
      !page ||
      event.senderFrame !== page.window.webContents.mainFrame ||
      event.senderFrame.url !== NodeURL.pathToFileURL(NodePath.join(assets, "shell.html")).href
    )
      throw new Error("Invalid browser toolbar owner.");
    if (method === "ready") {
      page.window.webContents.send("t3-native-browser-state", {
        partition: page.partition,
        url: page.initialURL,
      });
      return;
    }
    if (!["back", "forward", "reload", "stop", "close", "popup", "navigate"].includes(method))
      throw new Error("Invalid toolbar action.");
    if (method === "navigate") interrupt(page);
    return command(method, {
      ...input,
      environmentID: page.environmentID,
      threadId: page.threadId,
      tabId: page.tabId,
    });
  });
  const utf8 = new NodeStringDecoder.StringDecoder("utf8");
  process.stdin.on("data", (chunk) => {
    try {
      const commands = decoder.push(utf8.write(chunk));
      for (const request of commands) {
        if (commandCount >= 32) throw new Error("Too many pending browser commands.");
        commandCount++;
        void command(request.method, request.input ?? {})
          .then(
            (result) => send({ id: request.id, result: result ?? null }),
            (error) =>
              send({
                id: request.id,
                error: {
                  _tag: error._tag ?? "PreviewAutomationActionFailedError",
                  message: error.message,
                },
              }),
          )
          .finally(() => commandCount--);
      }
    } catch (error) {
      console.error(error.message);
      app.quit();
    }
  });
  const shutdown = () => {
    if (closing) return;
    closing = true;
    extensions.dispose();
    void cancelDownloads()
      .then(flushSessions)
      .finally(() => app.quit());
  };
  process.stdin.on("end", shutdown);
  process.once("SIGTERM", shutdown);
  process.once("SIGINT", shutdown);
  app.on("window-all-closed", () => {});
  app.on("before-quit", (event) => {
    if (closing) return;
    event.preventDefault();
    const finish = async () => {
      closing = true;
      extensions.dispose();
      await cancelDownloads();
      await flushSessions();
      app.quit();
    };
    if (!downloads.size) {
      void finish();
      return;
    }
    const owner = [...pages.values()].find((page) => !page.window.isDestroyed())?.window;
    const options = {
      type: "question",
      message: "Downloads are still running",
      detail: "Quitting T3 Browser cancels its downloads.",
      buttons: ["Keep downloading", "Quit and cancel downloads"],
      defaultId: 0,
      cancelId: 0,
    };
    void (owner ? dialog.showMessageBox(owner, options) : dialog.showMessageBox(options)).then(
      ({ response }) => {
        if (response === 1) void finish();
      },
    );
  });
  send({ event: "ready", value: { version: 1, engine: "chromium" } });
}
void app
  .whenReady()
  .then(start)
  .catch((error) => {
    console.error(error);
    app.exit(1);
  });
