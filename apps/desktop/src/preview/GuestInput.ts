// CDP input follows shared window focus; send directly to unfocused guests to avoid typing into the app.

const FOCUS_ROUTED_INPUT = new Set([
  "Input.insertText",
  "Input.dispatchKeyEvent",
  "Input.imeSetComposition",
]);

/** Direct input reaches only the main-frame process; insertText crashes when a cross-site frame has focus. */
const FOCUSED_DOCUMENT = `(() => {
  let doc = document;
  for (;;) {
    const active = doc.activeElement;
    if (active?.tagName !== "IFRAME" && active?.tagName !== "FRAME") return doc;
    if (!active.contentDocument) return null;
    doc = active.contentDocument;
  }
})()`;

/** Electron runs editing commands only for CDP keys; exclude clipboard commands to preserve the user's clipboard. */
const EDITING_COMMANDS = new Set(["selectAll", "undo", "redo"]);

const CROSS_SITE_FOCUS_MESSAGE =
  "The page's focus is inside a cross-site frame, which takes typed input only while the preview has focus. Click the field first.";

const ARROW_KEYS: Record<string, string> = {
  ArrowUp: "Up",
  ArrowDown: "Down",
  ArrowLeft: "Left",
  ArrowRight: "Right",
};
const NAMED_KEYS = new Set([
  "Backspace",
  "Tab",
  "Enter",
  "Escape",
  "Delete",
  "Insert",
  "Home",
  "End",
  "PageUp",
  "PageDown",
  "Shift",
  "Control",
  "Alt",
  "Meta",
  "CapsLock",
  "NumLock",
  "ScrollLock",
  "PrintScreen",
]);
const MODIFIER_BITS = [
  [1, "alt"],
  [2, "control"],
  [4, "meta"],
  [8, "shift"],
] as const;

const keyCodeFor = (key: string) => {
  if ([...key].length === 1) return key;
  if (ARROW_KEYS[key]) return ARROW_KEYS[key];
  return NAMED_KEYS.has(key) || /^F(?:[1-9]|1\d|2[0-4])$/u.test(key) ? key : null;
};

/** Electron derives text from keyCode, so typed text needs separate char events. */
export const toKeyboardInputEvents = (
  params: Record<string, unknown>,
): Array<Electron.KeyboardInputEvent> => {
  const bits = typeof params["modifiers"] === "number" ? params["modifiers"] : 0;
  const modifiers = MODIFIER_BITS.flatMap(([bit, name]) => (bits & bit ? [name] : []));
  const text = typeof params["text"] === "string" ? params["text"] : "";
  const chars = [...text].map((char) => ({ type: "char" as const, keyCode: char, modifiers }));
  const keyCode = keyCodeFor(typeof params["key"] === "string" ? params["key"] : "");
  switch (params["type"]) {
    case "keyDown":
      return [...(keyCode ? [{ type: "rawKeyDown" as const, keyCode, modifiers }] : []), ...chars];
    case "rawKeyDown":
    case "keyUp":
      return keyCode ? [{ type: params["type"], keyCode, modifiers }] : [];
    case "char":
      return chars;
    default:
      return [];
  }
};

const evaluate = async (debuggee: Electron.Debugger, expression: string) => {
  const reply = (await debuggee.sendCommand("Runtime.evaluate", {
    expression,
    returnByValue: true,
  })) as { readonly result?: { readonly value?: unknown } };
  return reply.result?.value;
};

/** Host focus shared by the presses in flight in one window, so a later press keeps the field an earlier one saved. */
const HOST_FOCUS = "globalThis.__t3PreviewFocus";

/** A CDP pointer press focuses the guest's native view even with focus emulation enabled. */
const sendPointerPress = async (
  webContents: Electron.WebContents,
  debuggee: Electron.Debugger,
  method: string,
  params: Record<string, unknown>,
  sessionId: string | undefined,
) => {
  const host = webContents.hostWebContents;
  if (!host || host.isDestroyed() || webContents.focusedFrame) {
    return debuggee.sendCommand(method, params, sessionId);
  }
  // Focus in a webview with a press in flight came from that press, so keep the earlier save.
  await host.executeJavaScript(`(() => {
    const state = (${HOST_FOCUS} ??= { saved: null, presses: [] });
    const active = document.activeElement;
    let pressed = false;
    try {
      pressed = active?.tagName === "WEBVIEW" && state.presses.includes(active.getWebContentsId());
    } catch {}
    if (!pressed) {
      state.saved = active && active !== document.body && active.tagName !== "WEBVIEW" ? active : null;
    }
    state.presses.push(${webContents.id});
  })()`);
  try {
    return await debuggee.sendCommand(method, params, sessionId);
  } finally {
    if (!host.isDestroyed()) {
      // Membership check: a host reload starts a new state without this press.
      await host.executeJavaScript(`(() => {
        const state = ${HOST_FOCUS};
        const index = state ? state.presses.indexOf(${webContents.id}) : -1;
        if (index < 0) return;
        state.presses.splice(index, 1);
        if (state.presses.length === 0) delete ${HOST_FOCUS};
        const current = document.activeElement;
        try {
          if (state.saved?.isConnected && current?.tagName === "WEBVIEW" &&
              current.getWebContentsId() === ${webContents.id}) state.saved.focus({ preventScroll: true });
        } catch {}
      })()`);
    }
  }
};

/**
 * The child sessions Chromium attached for the page's out-of-process frames, such as
 * cross-site and extension iframes, keyed by frame id.
 */
export type FrameSessions = ReadonlyMap<string, string>;

const NO_FRAME_SESSIONS: FrameSessions = new Map();
const INPUT_WORLD = "t3-preview-input";
const MAX_FRAME_DEPTH = 8;
let lookupSequence = 0;

// Called on a window, document, or shadow root, so one lookup also works inside closed roots.
const ELEMENT_AT = "function (x, y) { return (this.document ?? this).elementFromPoint(x, y); }";
const ACTIVE_ELEMENT = "function () { return (this.document ?? this).activeElement; }";
const CONTENT_ORIGIN = `function () {
  const box = this.getBoundingClientRect();
  const style = getComputedStyle(this);
  return [
    box.left + this.clientLeft + parseFloat(style.paddingLeft),
    box.top + this.clientTop + parseFloat(style.paddingTop),
  ];
}`;

interface RemoteObject {
  readonly objectId?: string;
  readonly value?: unknown;
}

/**
 * The out-of-process frame a lookup lands on in one frame's document, with the
 * top-left of that frame's viewport. Runs in an isolated world so page script
 * can't redirect agent input into another frame, and descends through shadow
 * roots, closed ones too: 1Password keeps its menu frame in one.
 */
const ownedFrameAt = async (
  debuggee: Electron.Debugger,
  sessionId: string | undefined,
  lookup: string,
  args: ReadonlyArray<number>,
) => {
  const send = (method: string, params: Record<string, unknown>) =>
    debuggee.sendCommand(method, params, sessionId);
  const { frameTree } = (await send("Page.getFrameTree", {})) as {
    readonly frameTree: { readonly frame: { readonly id: string } };
  };
  const { executionContextId } = (await send("Page.createIsolatedWorld", {
    frameId: frameTree.frame.id,
    worldName: INPUT_WORLD,
  })) as { readonly executionContextId: number };
  const objectGroup = `${INPUT_WORLD}-${++lookupSequence}`;
  const call = async (
    on: Record<string, unknown>,
    functionDeclaration: string,
    returnByValue = false,
  ) =>
    (
      (await send("Runtime.callFunctionOn", {
        ...on,
        functionDeclaration,
        arguments: args.map((value) => ({ value })),
        objectGroup,
        returnByValue,
      })) as { readonly result: RemoteObject }
    ).result;
  try {
    let found = await call({ executionContextId }, lookup);
    let previous: number | undefined;
    while (found.objectId !== undefined) {
      const { node } = (await send("DOM.describeNode", {
        objectId: found.objectId,
        pierce: true,
      })) as {
        readonly node: {
          readonly backendNodeId: number;
          readonly nodeName: string;
          readonly frameId?: string;
          readonly shadowRoots?: ReadonlyArray<{ readonly backendNodeId: number }>;
        };
      };
      if (node.frameId !== undefined && (node.nodeName === "IFRAME" || node.nodeName === "FRAME")) {
        const origin = await call({ objectId: found.objectId }, CONTENT_ORIGIN, true);
        const [x, y] = origin.value as readonly [number, number];
        return { frameId: node.frameId, x, y };
      }
      const root = node.shadowRoots?.[0];
      // A shadow root's lookup lands back on its host when nothing inside it matches.
      if (root === undefined || node.backendNodeId === previous) return null;
      previous = node.backendNodeId;
      const { object } = (await send("DOM.resolveNode", {
        backendNodeId: root.backendNodeId,
        executionContextId,
        objectGroup,
      })) as { readonly object: RemoteObject };
      found = await call({ objectId: object.objectId }, lookup);
    }
    return null;
  } finally {
    void send("Runtime.releaseObjectGroup", { objectGroup }).catch(() => {});
  }
};

/**
 * Follows a lookup from the page down through its out-of-process frames, to the
 * session of the deepest one it lands in, or undefined for the page itself.
 */
const frameTarget = async (
  debuggee: Electron.Debugger,
  frames: FrameSessions,
  lookup: string,
  point: { readonly x: number; readonly y: number } = { x: 0, y: 0 },
) => {
  let sessionId: string | undefined;
  let at = point;
  for (let depth = 0; depth < MAX_FRAME_DEPTH && frames.size > 0; depth += 1) {
    const owned = await ownedFrameAt(debuggee, sessionId, lookup, [at.x, at.y]).catch(() => null);
    const child = owned === null ? undefined : frames.get(owned.frameId);
    if (owned === null || child === undefined) break;
    sessionId = child;
    at = { x: at.x - owned.x, y: at.y - owned.y };
  }
  return { sessionId, point: at };
};

const pointerCommands = new WeakMap<Electron.WebContents, Promise<unknown>>();

/**
 * Focus capture crosses processes; later pointer events must not overtake the press.
 * Mouse events over an out-of-process frame use its own session: Chromium's window hit
 * test misses a guest the app isn't showing under the pointer and lands on the page.
 */
const sendPointerCommand = async (
  webContents: Electron.WebContents,
  debuggee: Electron.Debugger,
  method: string,
  params: Record<string, unknown>,
  sessionId: string | undefined,
  frames: FrameSessions,
) => {
  const previous = pointerCommands.get(webContents) ?? Promise.resolve();
  const current = previous
    .catch(() => {})
    .then(async () => {
      const target =
        method === "Input.dispatchMouseEvent" &&
        sessionId === undefined &&
        typeof params["x"] === "number" &&
        typeof params["y"] === "number"
          ? await frameTarget(debuggee, frames, ELEMENT_AT, { x: params["x"], y: params["y"] })
          : { sessionId, point: undefined };
      const routed = target.point ? { ...params, ...target.point } : params;
      return params["type"] === "mousePressed" || params["type"] === "touchStart"
        ? sendPointerPress(webContents, debuggee, method, routed, target.sessionId)
        : debuggee.sendCommand(method, routed, target.sessionId);
    });
  pointerCommands.set(webContents, current);
  try {
    return await current;
  } finally {
    if (pointerCommands.get(webContents) === current) pointerCommands.delete(webContents);
  }
};

/** Sends one command to the guest's page, keeping reloads and input inside it. */
export const sendPageCommand = async (
  webContents: Electron.WebContents,
  debuggee: Electron.Debugger,
  method: string,
  params: Record<string, unknown>,
  sessionId?: string,
  frames: FrameSessions = NO_FRAME_SESSIONS,
): Promise<unknown> => {
  if (method === "Input.dispatchMouseEvent" || method === "Input.dispatchTouchEvent") {
    return sendPointerCommand(webContents, debuggee, method, params, sessionId, frames);
  }
  if (sessionId !== undefined) return debuggee.sendCommand(method, params, sessionId);
  // Electron's debugger routes Page.reload on a webview to its embedder window.
  if (method === "Page.reload") {
    if (params["ignoreCache"] === true) webContents.reloadIgnoringCache();
    else webContents.reload();
    return {};
  }
  if (!FOCUS_ROUTED_INPUT.has(method) || webContents.focusedFrame) {
    return debuggee.sendCommand(method, params);
  }
  // A frame's own session takes input straight to its focused element, where
  // Electron's direct input stops at the page's process.
  const focused = await frameTarget(debuggee, frames, ACTIVE_ELEMENT);
  if (focused.sessionId !== undefined) {
    return debuggee.sendCommand(
      method,
      Array.isArray(params["commands"])
        ? {
            ...params,
            commands: params["commands"].filter((command) => EDITING_COMMANDS.has(command)),
          }
        : params,
      focused.sessionId,
    );
  }
  if ((await evaluate(debuggee, `${FOCUSED_DOCUMENT} !== null`)) !== true) {
    throw new Error(CROSS_SITE_FOCUS_MESSAGE);
  }
  switch (method) {
    case "Input.insertText":
      await webContents.insertText(typeof params["text"] === "string" ? params["text"] : "");
      return {};
    case "Input.dispatchKeyEvent": {
      for (const event of toKeyboardInputEvents(params)) webContents.sendInputEvent(event);
      const commands = Array.isArray(params["commands"])
        ? params["commands"].filter((command) => EDITING_COMMANDS.has(command))
        : [];
      // Runs after the page handles the keys, so the reply also waits for them.
      await evaluate(
        debuggee,
        `(() => { const doc = ${FOCUSED_DOCUMENT}; for (const name of ${JSON.stringify(commands)}) doc?.execCommand(name); return 0; })()`,
      );
      return {};
    }
    default:
      throw new Error(`${method} needs the preview to have focus.`);
  }
};
