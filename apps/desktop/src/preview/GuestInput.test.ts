import * as NodeVM from "node:vm";

import { describe, expect, it, vi } from "vite-plus/test";

import { sendPageCommand, toKeyboardInputEvents } from "./GuestInput.ts";

/** A guest whose page reports `focusedDocument` for the focus probe. */
const makeGuest = ({
  focused,
  focusedDocument = true,
}: {
  readonly focused: boolean;
  readonly focusedDocument?: boolean;
}) => {
  const sendCommand = vi.fn(async (method: string, params?: { expression?: string }) =>
    method === "Runtime.evaluate" && params?.expression?.endsWith("!== null")
      ? { result: { value: focusedDocument } }
      : { result: {} },
  );
  const webContents = {
    focusedFrame: focused ? {} : null,
    insertText: vi.fn(async () => {}),
    sendInputEvent: vi.fn(),
    reload: vi.fn(),
    reloadIgnoringCache: vi.fn(),
  };
  return {
    webContents,
    sendCommand,
    send: (method: string, params: Record<string, unknown>) =>
      sendPageCommand(
        webContents as unknown as Electron.WebContents,
        { sendCommand } as unknown as Electron.Debugger,
        method,
        params,
      ),
  };
};

describe("preview guest input", () => {
  it("types into an unfocused guest's own page, not the app's focused field", async () => {
    const guest = makeGuest({ focused: false });
    await guest.send("Input.insertText", { text: "pairing-code" });
    expect(guest.webContents.insertText).toHaveBeenCalledWith("pairing-code");
    expect(guest.sendCommand).not.toHaveBeenCalledWith("Input.insertText", expect.anything());
  });

  it.each([
    {
      sessionId: undefined,
      method: "Input.dispatchMouseEvent",
      type: "mousePressed",
      outcome: "restore",
    },
    {
      sessionId: "child-frame",
      method: "Input.dispatchMouseEvent",
      type: "mousePressed",
      outcome: "restore",
    },
    {
      sessionId: undefined,
      method: "Input.dispatchTouchEvent",
      type: "touchStart",
      outcome: "restore",
    },
    {
      sessionId: undefined,
      method: "Input.dispatchMouseEvent",
      type: "mousePressed",
      outcome: "other-field",
    },
    {
      sessionId: undefined,
      method: "Input.dispatchMouseEvent",
      type: "mousePressed",
      outcome: "removed",
    },
    {
      sessionId: undefined,
      method: "Input.dispatchMouseEvent",
      type: "mousePressed",
      outcome: "failure",
    },
  ])(
    "preserves host focus for $method in $sessionId with $outcome",
    async ({ sessionId, method, type, outcome }) => {
      const document = { activeElement: {} as object };
      const composer = {
        isConnected: true,
        focus: () => {
          document.activeElement = composer;
        },
      };
      const preview = { tagName: "WEBVIEW", getWebContentsId: () => 7 };
      const otherField = { tagName: "INPUT" };
      document.activeElement = composer;
      const context = NodeVM.createContext({ document });
      const host = {
        isDestroyed: () => false,
        executeJavaScript: async (script: string) => NodeVM.runInContext(script, context),
      };
      const guest = { id: 7, focusedFrame: null, hostWebContents: host };
      const debuggee = {
        sendCommand: async () => {
          document.activeElement = outcome === "other-field" ? otherField : preview;
          if (outcome === "removed") composer.isConnected = false;
          if (outcome === "failure") throw new Error("Pointer failed");
          return {};
        },
      };
      const result = sendPageCommand(
        guest as unknown as Electron.WebContents,
        debuggee as unknown as Electron.Debugger,
        method,
        { type, x: 10, y: 10, button: "left" },
        sessionId,
      );
      if (outcome === "failure") await expect(result).rejects.toThrow("Pointer failed");
      else await result;
      expect(document.activeElement).toBe(
        outcome === "other-field" ? otherField : outcome === "removed" ? preview : composer,
      );
      expect(Object.keys(context)).toEqual(["document"]);
    },
  );

  it.each([{ userClicksStuckTab: false }, { userClicksStuckTab: true }])(
    "keeps the right focus when a sibling press finishes beside a stuck one, user clicks: $userClicksStuckTab",
    async ({ userClicksStuckTab }) => {
      const document = { activeElement: {} as object };
      const composer = {
        isConnected: true,
        focus: () => {
          document.activeElement = composer;
        },
      };
      document.activeElement = composer;
      const context = NodeVM.createContext({ document });
      const host = {
        isDestroyed: () => false,
        executeJavaScript: async (script: string) => NodeVM.runInContext(script, context),
      };
      const previews = new Map(
        [7, 8].map((id) => [id, { tagName: "WEBVIEW", getWebContentsId: () => id }]),
      );
      const stuckPressFocused = Promise.withResolvers<void>();
      const stuckPressEnds = Promise.withResolvers<void>();
      const press = (id: number) => {
        const debuggee = {
          sendCommand: async () => {
            document.activeElement = previews.get(id)!;
            if (id === 7) {
              stuckPressFocused.resolve();
              await stuckPressEnds.promise;
            } else if (userClicksStuckTab) {
              document.activeElement = previews.get(7)!;
            }
            return {};
          },
        };
        return sendPageCommand(
          { id, focusedFrame: null, hostWebContents: host } as unknown as Electron.WebContents,
          debuggee as unknown as Electron.Debugger,
          "Input.dispatchMouseEvent",
          { type: "mousePressed", x: 10, y: 10, button: "left" },
        );
      };
      // A press held open, as by a page's confirm() on mousedown, must not block or win focus.
      const stuck = press(7);
      await stuckPressFocused.promise;
      await press(8);
      const expected = userClicksStuckTab ? previews.get(7) : composer;
      expect(document.activeElement).toBe(expected);
      stuckPressEnds.resolve();
      await stuck;
      expect(Object.keys(context)).toEqual(["document"]);
    },
  );

  it.each([
    {
      method: "Input.dispatchMouseEvent",
      press: "mousePressed",
      release: "mouseReleased",
      failPress: false,
    },
    {
      method: "Input.dispatchTouchEvent",
      press: "touchStart",
      release: "touchEnd",
      failPress: false,
    },
    {
      method: "Input.dispatchMouseEvent",
      press: "mousePressed",
      release: "mouseReleased",
      failPress: true,
    },
  ])(
    "keeps $method releases behind presses waiting for host focus, failed press: $failPress",
    async ({ method, press, release, failPress }) => {
      const captureStarted = Promise.withResolvers<void>();
      const finishCapture = Promise.withResolvers<void>();
      const events: Array<unknown> = [];
      const guest = {
        id: 7,
        focusedFrame: null,
        hostWebContents: {
          isDestroyed: () => false,
          executeJavaScript: async () => {
            captureStarted.resolve();
            await finishCapture.promise;
          },
        },
      };
      const debuggee = {
        sendCommand: async (_method: string, params: Record<string, unknown>) => {
          events.push(params["type"]);
          if (failPress && params["type"] === press) throw new Error("Press failed");
          return {};
        },
      };
      const send = (type: string) =>
        sendPageCommand(
          guest as unknown as Electron.WebContents,
          debuggee as unknown as Electron.Debugger,
          method,
          { type },
        );
      const pressed = send(press);
      await captureStarted.promise;
      const released = send(release);
      finishCapture.resolve();
      const results = await Promise.allSettled([pressed, released]);
      expect(results.map((result) => result.status)).toEqual([
        failPress ? "rejected" : "fulfilled",
        "fulfilled",
      ]);
      expect(events).toEqual([press, release]);
    },
  );

  /**
   * A page with 1Password's inline menu: an out-of-process extension frame at
   * (20, 60), inside a closed shadow root. The lookup scripts run against it.
   */
  const pageWithExtensionMenu = () => {
    const item = { backendNodeId: 5, nodeName: "DIV" };
    const list = { backendNodeId: 6, nodeName: "UL" };
    const menuFrame = {
      backendNodeId: 3,
      nodeName: "IFRAME",
      frameId: "menu-frame",
      clientLeft: 0,
      clientTop: 0,
      style: { paddingLeft: "0px", paddingTop: "0px" },
      getBoundingClientRect: () => ({ left: 20, top: 60 }),
    };
    const inMenu = (x: number, y: number) => x >= 20 && x < 220 && y >= 60 && y < 160;
    const shadowRoot = {
      backendNodeId: 2,
      nodeName: "#document-fragment",
      activeElement: menuFrame,
      elementFromPoint: (x: number, y: number) => (inMenu(x, y) ? menuFrame : menuHost),
    };
    const menuHost = {
      backendNodeId: 1,
      nodeName: "COM-1PASSWORD-MENU",
      shadowRoots: [shadowRoot],
    };
    const field = { backendNodeId: 4, nodeName: "INPUT" };
    const documents = {
      page: {
        activeElement: menuHost,
        elementFromPoint: (x: number, y: number) => (inMenu(x, y) ? menuHost : field),
      },
      menu: { activeElement: list, elementFromPoint: () => item },
    };
    const realm = NodeVM.createContext({
      getComputedStyle: (node: typeof menuFrame) => node.style,
    });
    const objects = new Map<string, object>();
    const handle = (value: object) => {
      const objectId = `object-${objects.size}`;
      objects.set(objectId, value);
      return objectId;
    };
    const delivered: Array<{ method: string; params: Record<string, unknown>; session?: string }> =
      [];
    const sendCommand = async (
      method: string,
      params: {
        readonly objectId?: string;
        readonly functionDeclaration?: string;
        readonly arguments?: ReadonlyArray<{ readonly value: unknown }>;
        readonly returnByValue?: boolean;
      } & Record<string, unknown>,
      session?: string,
    ): Promise<unknown> => {
      switch (method) {
        case "Page.getFrameTree":
          return { frameTree: { frame: { id: session === undefined ? "page" : "menu-frame" } } };
        case "Page.createIsolatedWorld":
          return { executionContextId: 1 };
        case "Runtime.callFunctionOn": {
          const self = params.objectId
            ? objects.get(params.objectId)
            : { document: session === undefined ? documents.page : documents.menu };
          const lookup = NodeVM.runInContext(`(${params.functionDeclaration})`, realm) as (
            ...args: ReadonlyArray<unknown>
          ) => object | null;
          const value = lookup.apply(
            self,
            (params.arguments ?? []).map((argument) => argument.value),
          );
          if (params.returnByValue) return { result: { value } };
          return { result: value ? { objectId: handle(value) } : {} };
        }
        case "DOM.describeNode":
          return { node: objects.get(params.objectId ?? "") };
        case "DOM.resolveNode":
          return { object: { objectId: handle(shadowRoot) } };
        case "Runtime.releaseObjectGroup":
          return {};
        default:
          delivered.push({ method, params, ...(session ? { session } : {}) });
          return {};
      }
    };
    const webContents = {
      id: 7,
      focusedFrame: null,
      hostWebContents: null,
      sendInputEvent: vi.fn(),
    };
    const send = (method: string, params: Record<string, unknown>) =>
      sendPageCommand(
        webContents as unknown as Electron.WebContents,
        { sendCommand } as unknown as Electron.Debugger,
        method,
        params,
        undefined,
        new Map([["menu-frame", "menu-session"]]),
      );
    return { delivered, send, webContents };
  };

  it("clicks an extension menu through its own frame, in the frame's coordinates", async () => {
    const page = pageWithExtensionMenu();
    for (const type of ["mouseMoved", "mousePressed", "mouseReleased"]) {
      await page.send("Input.dispatchMouseEvent", { type, x: 120, y: 110, button: "left" });
    }
    await page.send("Input.dispatchMouseEvent", { type: "mousePressed", x: 300, y: 20 });
    expect(
      page.delivered.map(({ params, session }) => [
        params["type"],
        params["x"],
        params["y"],
        session,
      ]),
    ).toEqual([
      ["mouseMoved", 100, 50, "menu-session"],
      ["mousePressed", 100, 50, "menu-session"],
      ["mouseReleased", 100, 50, "menu-session"],
      ["mousePressed", 300, 20, undefined],
    ]);
  });

  it("sends keys to the extension frame holding the unfocused page's focus", async () => {
    const page = pageWithExtensionMenu();
    await page.send("Input.dispatchKeyEvent", {
      type: "keyDown",
      key: "Enter",
      text: "\r",
      commands: ["selectAll", "paste"],
    });
    expect(page.delivered).toEqual([
      {
        method: "Input.dispatchKeyEvent",
        params: { type: "keyDown", key: "Enter", text: "\r", commands: ["selectAll"] },
        session: "menu-session",
      },
    ]);
    expect(page.webContents.sendInputEvent).not.toHaveBeenCalled();
  });

  it("refuses input when a cross-site frame holds the unfocused page's focus", async () => {
    const guest = makeGuest({ focused: false, focusedDocument: false });
    await expect(guest.send("Input.insertText", { text: "secret" })).rejects.toThrow(
      /cross-site frame/,
    );
    expect(guest.webContents.insertText).not.toHaveBeenCalled();
  });
});

describe("CDP key events as Electron input", () => {
  it("sends a key's text as char events after its key down", () => {
    expect(toKeyboardInputEvents({ type: "keyDown", key: "Enter", text: "\r" })).toEqual([
      { type: "rawKeyDown", keyCode: "Enter", modifiers: [] },
      { type: "char", keyCode: "\r", modifiers: [] },
    ]);
    expect(toKeyboardInputEvents({ type: "keyDown", key: "é", text: "é", modifiers: 8 })).toEqual([
      { type: "rawKeyDown", keyCode: "é", modifiers: ["shift"] },
      { type: "char", keyCode: "é", modifiers: ["shift"] },
    ]);
  });

  // regression: #18556 agent typing in a preview tab landed in the app instead of the guest
  it("names arrows and function keys as Electron accelerators", () => {
    expect(toKeyboardInputEvents({ type: "keyUp", key: "ArrowLeft", modifiers: 3 })).toEqual([
      { type: "keyUp", keyCode: "Left", modifiers: ["alt", "control"] },
    ]);
    expect(toKeyboardInputEvents({ type: "rawKeyDown", key: "F12" })).toEqual([
      { type: "rawKeyDown", keyCode: "F12", modifiers: [] },
    ]);
    expect(toKeyboardInputEvents({ type: "rawKeyDown", key: "AudioVolumeUp" })).toEqual([]);
  });
});
