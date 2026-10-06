// @effect-diagnostics globalTimers:off globalConsole:off globalDate:off globalRandom:off -- This preload, and the function it injects, run inside extension service workers and pages, outside any Effect runtime.
/**
 * Preload for Chrome extension contexts in preview browser sessions: each
 * extension's service worker and its pages (action popups, options pages).
 *
 * Electron implements only part of the extensions API. Extensions such as
 * 1Password call namespaces Electron lacks (`windows`, `contextMenus`,
 * `webNavigation`, ...) during start-up and stop working when one is missing.
 * This installs them in the extension's own world before its code runs. Calls
 * go to the main process (src/preview/extensions/ExtensionHost.ts), and events
 * come back on {@link EVENT_CHANNEL}.
 *
 * Registered for every frame and service worker in the session, so it returns
 * at once for web pages and websites' own service workers.
 */
import { contextBridge, ipcRenderer } from "electron";

import {
  PREVIEW_EXTENSION_EVENT_CHANNEL as EVENT_CHANNEL,
  PREVIEW_EXTENSION_INVOKE_CHANNEL as INVOKE_CHANNEL,
} from "./preview/extensions/channels.ts";

type EventListener = (event: string, args: ReadonlyArray<unknown>) => void;

interface ExtensionBridge {
  readonly invoke: (method: string, args: ReadonlyArray<unknown>) => Promise<unknown>;
  readonly onEvent: (listener: EventListener) => void;
}

/**
 * Asked of the main world: a service worker's preload realm has no
 * `location` of its own. Web pages in the preview run without context
 * isolation, where the bridge throws, which also reads as "not an extension".
 */
const isExtensionContext = (() => {
  try {
    return (
      contextBridge.executeInMainWorld({
        func: () => globalThis.location?.protocol === "chrome-extension:",
      }) === true
    );
  } catch {
    return false;
  }
})();

if (isExtensionContext) {
  const listeners = new Set<EventListener>();
  ipcRenderer.on(EVENT_CHANNEL, (_event, name: string, args: ReadonlyArray<unknown>) => {
    for (const listener of listeners) listener(name, args);
  });

  // A service worker's IPC handler is attached when the worker starts, which
  // can be a moment after this preload first calls it.
  const invoke = async (method: string, args: ReadonlyArray<unknown>): Promise<unknown> => {
    for (let attempt = 0; ; attempt++) {
      try {
        return await ipcRenderer.invoke(INVOKE_CHANNEL, method, args);
      } catch (error) {
        const notReady = String((error as Error | undefined)?.message).includes(
          "No handler registered",
        );
        if (!notReady || attempt >= 40) throw error;
        await new Promise((resolve) => setTimeout(resolve, 25));
      }
    }
  };

  const bridge: ExtensionBridge = {
    invoke,
    onEvent: (listener) => {
      listeners.add(listener);
    },
  };
  contextBridge.executeInMainWorld({ func: installExtensionApis, args: [bridge] });
  // Registers this context with the host, so it receives events before its first API call.
  void invoke("context.ready", []).catch(() => undefined);
}

/**
 * Runs in the extension's main world, so it must stay self-contained: it is
 * serialized by `executeInMainWorld` and cannot reach anything in this module.
 */
function installExtensionApis(bridge: ExtensionBridge): void {
  type Listener = (...args: Array<any>) => unknown;
  type ApiRoot = Record<string, any>;
  const scope = globalThis as unknown as { chrome?: ApiRoot; browser?: ApiRoot };
  const roots = [scope.chrome, scope.browser].filter(
    (root, index, all): root is ApiRoot => root !== undefined && all.indexOf(root) === index,
  );
  if (roots.length === 0) return;

  const events = new Map<string, { readonly listeners: Set<Listener>; readonly api: object }>();
  const event = (key: string) => {
    let entry = events.get(key);
    if (!entry) {
      const listeners = new Set<Listener>();
      entry = {
        listeners,
        api: {
          addListener: (listener: Listener) => void listeners.add(listener),
          removeListener: (listener: Listener) => void listeners.delete(listener),
          hasListener: (listener: Listener) => listeners.has(listener),
          hasListeners: () => listeners.size > 0,
        },
      };
      events.set(key, entry);
    }
    return entry.api;
  };
  const dispatch = (key: string, args: ReadonlyArray<unknown>) => {
    for (const listener of events.get(key)?.listeners ?? []) {
      try {
        listener(...args);
      } catch (error) {
        console.error(`[t3] ${key} listener failed`, error);
      }
    }
  };

  // Chrome APIs return a promise, or call a trailing callback instead.
  const call = (method: string, args: Array<unknown>, map?: (value: any) => unknown) => {
    const callback = typeof args.at(-1) === "function" ? (args.pop() as Listener) : undefined;
    const result = bridge.invoke(method, args).then((value) => (map ? map(value) : value));
    if (!callback) return result;
    result.then(
      (value) => callback(value),
      (error) => {
        console.warn(`[t3] ${method} failed`, error);
        callback(undefined);
      },
    );
    return undefined;
  };
  const api = (namespace: string, methods: ReadonlyArray<string>) =>
    Object.fromEntries(
      methods.map((method) => [
        method,
        (...args: Array<unknown>) => call(`${namespace}.${method}`, args),
      ]),
    );
  const eventsOf = (namespace: string, names: ReadonlyArray<string>) =>
    Object.fromEntries(names.map((name) => [name, event(`${namespace}.${name}`)]));

  const set = (name: string, members: Record<string, unknown>, onlyMissing = false) => {
    for (const root of roots) {
      if (root[name] === undefined) {
        try {
          root[name] = {};
        } catch {
          continue;
        }
      }
      const target = root[name];
      for (const [key, value] of Object.entries(members)) {
        if (onlyMissing && target[key] !== undefined) continue;
        try {
          Object.defineProperty(target, key, {
            value,
            configurable: true,
            enumerable: true,
            writable: true,
          });
        } catch {
          // A frozen native member keeps Electron's version.
        }
      }
    }
  };

  bridge.onEvent((name, args) => {
    if (name === "nativePort.message") {
      nativePorts.get(args[0] as number)?.message(args[1]);
      return;
    }
    if (name === "nativePort.disconnect") {
      nativePorts.get(args[0] as number)?.disconnect(args[1] as string | undefined);
      return;
    }
    if (name === "contextMenus.onClicked") {
      const info = args[0] as { menuItemId?: string | number } | undefined;
      const onclick =
        info?.menuItemId === undefined ? undefined : menuClickHandlers.get(info.menuItemId);
      onclick?.(...args);
    }
    dispatch(name, args);
  });

  // windows
  set("windows", {
    WINDOW_ID_NONE: -1,
    WINDOW_ID_CURRENT: -2,
    WindowType: {
      NORMAL: "normal",
      POPUP: "popup",
      PANEL: "panel",
      APP: "app",
      DEVTOOLS: "devtools",
    },
    WindowState: {
      NORMAL: "normal",
      MINIMIZED: "minimized",
      MAXIMIZED: "maximized",
      FULLSCREEN: "fullscreen",
      LOCKED_FULLSCREEN: "locked-fullscreen",
    },
    CreateType: { NORMAL: "normal", POPUP: "popup", PANEL: "panel" },
    ...api("windows", [
      "get",
      "getCurrent",
      "getLastFocused",
      "getAll",
      "create",
      "update",
      "remove",
    ]),
    ...eventsOf("windows", ["onCreated", "onRemoved", "onFocusChanged", "onBoundsChanged"]),
  });

  // tabs: Electron answers `query` without knowing which preview tab is in
  // front, so tab and window lookups come from the host instead.
  set("tabs", {
    TAB_ID_NONE: -1,
    ...api("tabs", [
      "query",
      "get",
      "getCurrent",
      "create",
      "remove",
      "highlight",
      "captureVisibleTab",
      "duplicate",
      "goBack",
      "goForward",
      "discard",
    ]),
    ...eventsOf("tabs", [
      "onCreated",
      "onUpdated",
      "onActivated",
      "onRemoved",
      "onHighlighted",
      "onReplaced",
      "onAttached",
      "onDetached",
      "onMoved",
      "onZoomChange",
    ]),
  });

  set("webNavigation", {
    ...api("webNavigation", ["getFrame", "getAllFrames"]),
    ...eventsOf("webNavigation", [
      "onBeforeNavigate",
      "onCommitted",
      "onDOMContentLoaded",
      "onCompleted",
      "onErrorOccurred",
      "onHistoryStateUpdated",
      "onReferenceFragmentUpdated",
      "onCreatedNavigationTarget",
      "onTabReplaced",
    ]),
  });

  // contextMenus.create returns its id synchronously.
  let nextMenuId = 1;
  const menuClickHandlers = new Map<string | number, Listener>();
  const stripOnclick = (properties: Record<string, unknown> | undefined) => {
    if (!properties) return properties;
    const { onclick: _onclick, ...rest } = properties;
    return rest;
  };
  const contextMenus = {
    ContextType: {
      ALL: "all",
      PAGE: "page",
      FRAME: "frame",
      SELECTION: "selection",
      LINK: "link",
      EDITABLE: "editable",
      IMAGE: "image",
      VIDEO: "video",
      AUDIO: "audio",
      LAUNCHER: "launcher",
      BROWSER_ACTION: "browser_action",
      PAGE_ACTION: "page_action",
      ACTION: "action",
    },
    ItemType: { NORMAL: "normal", CHECKBOX: "checkbox", RADIO: "radio", SEPARATOR: "separator" },
    ACTION_MENU_TOP_LEVEL_LIMIT: 6,
    create: (properties: Record<string, unknown> = {}, callback?: Listener) => {
      const id = (properties.id as string | number | undefined) ?? nextMenuId++;
      if (typeof properties.onclick === "function")
        menuClickHandlers.set(id, properties.onclick as Listener);
      void bridge.invoke("contextMenus.create", [{ ...stripOnclick(properties), id }]).then(
        () => callback?.(),
        () => callback?.(),
      );
      return id;
    },
    update: (id: string | number, properties: Record<string, unknown>, callback?: Listener) => {
      if (typeof properties.onclick === "function")
        menuClickHandlers.set(id, properties.onclick as Listener);
      return call(
        "contextMenus.update",
        callback ? [id, stripOnclick(properties), callback] : [id, stripOnclick(properties)],
      );
    },
    remove: (id: string | number, callback?: Listener) => {
      menuClickHandlers.delete(id);
      return call("contextMenus.remove", callback ? [id, callback] : [id]);
    },
    removeAll: (callback?: Listener) => {
      menuClickHandlers.clear();
      return call("contextMenus.removeAll", callback ? [callback] : []);
    },
    ...eventsOf("contextMenus", ["onClicked", "onShown", "onHidden"]),
  };
  set("contextMenus", contextMenus);

  set("notifications", {
    TemplateType: { BASIC: "basic", IMAGE: "image", LIST: "list", PROGRESS: "progress" },
    PermissionLevel: { GRANTED: "granted", DENIED: "denied" },
    create: (...args: Array<unknown>) => {
      if (typeof args[0] !== "string")
        args.unshift(`t3-${Date.now()}-${Math.random().toString(36).slice(2)}`);
      return call("notifications.create", args);
    },
    ...api("notifications", ["update", "clear", "getAll", "getPermissionLevel"]),
    ...eventsOf("notifications", [
      "onClicked",
      "onClosed",
      "onButtonClicked",
      "onPermissionLevelChanged",
      "onShowSettings",
    ]),
  });

  set(
    "downloads",
    {
      ...api("downloads", [
        "download",
        "search",
        "pause",
        "resume",
        "cancel",
        "erase",
        "open",
        "show",
        "showDefaultFolder",
        "removeFile",
        "acceptDanger",
        "setUiOptions",
      ]),
      ...eventsOf("downloads", ["onCreated", "onChanged", "onErased", "onDeterminingFilename"]),
    },
    true,
  );

  set(
    "cookies",
    {
      OnChangedCause: {
        EVICTED: "evicted",
        EXPIRED: "expired",
        EXPLICIT: "explicit",
        EXPIRED_OVERWRITE: "expired_overwrite",
        OVERWRITE: "overwrite",
      },
      SameSiteStatus: {
        NO_RESTRICTION: "no_restriction",
        LAX: "lax",
        STRICT: "strict",
        UNSPECIFIED: "unspecified",
      },
      ...api("cookies", [
        "get",
        "getAll",
        "set",
        "remove",
        "getAllCookieStores",
        "getPartitionKey",
      ]),
      ...eventsOf("cookies", ["onChanged"]),
    },
    true,
  );

  // Electron has no browser settings for extensions to manage. Keep the
  // values an extension sets so reading them back behaves like Chrome.
  const setting = (initial: unknown) => {
    let value = initial;
    return {
      get: (...args: Array<unknown>) => {
        const result = { value, levelOfControl: "controllable_by_this_extension" };
        const callback = args.find((arg) => typeof arg === "function") as Listener | undefined;
        if (callback) {
          queueMicrotask(() => callback(result));
          return undefined;
        }
        return Promise.resolve(result);
      },
      set: (details: { value?: unknown } = {}, callback?: Listener) => {
        value = details.value;
        if (callback) queueMicrotask(() => callback());
        else return Promise.resolve();
        return undefined;
      },
      clear: (_details?: unknown, callback?: Listener) => {
        value = initial;
        if (callback) queueMicrotask(() => callback());
        else return Promise.resolve();
        return undefined;
      },
      onChange: event(`privacy.setting.${Math.random()}`),
    };
  };
  set(
    "privacy",
    {
      services: {
        alternateErrorPagesEnabled: setting(false),
        autofillAddressEnabled: setting(true),
        autofillCreditCardEnabled: setting(true),
        autofillEnabled: setting(true),
        passwordSavingEnabled: setting(true),
        safeBrowsingEnabled: setting(true),
        safeBrowsingExtendedReportingEnabled: setting(false),
        searchSuggestEnabled: setting(false),
        spellingServiceEnabled: setting(false),
        translationServiceEnabled: setting(false),
      },
      network: {
        networkPredictionEnabled: setting(true),
        webRTCIPHandlingPolicy: setting("default"),
      },
      websites: {
        doNotTrackEnabled: setting(false),
        hyperlinkAuditingEnabled: setting(true),
        protectedContentEnabled: setting(true),
        referrersEnabled: setting(true),
        thirdPartyCookiesAllowed: setting(true),
      },
    },
    true,
  );

  // Granted from the manifest; optional permissions are granted on request.
  set(
    "permissions",
    {
      ...api("permissions", ["contains", "getAll", "request", "remove"]),
      ...eventsOf("permissions", ["onAdded", "onRemoved"]),
    },
    true,
  );

  set("commands", {
    getAll: (callback?: Listener) => {
      const commands = (scope.chrome?.runtime?.getManifest?.()?.commands ?? {}) as Record<
        string,
        { description?: string }
      >;
      const result = Object.entries(commands).map(([name, command]) => ({
        name,
        description: command.description ?? "",
        shortcut: "",
      }));
      if (callback) {
        queueMicrotask(() => callback(result));
        return undefined;
      }
      return Promise.resolve(result);
    },
    ...eventsOf("commands", ["onCommand"]),
  });

  // Toolbar button. The host draws it, so every change goes there.
  const toPlainImage = (image: unknown): unknown => {
    if (!image || typeof image !== "object") return image;
    if ("data" in image && "width" in image && "height" in image) {
      const { data, width, height } = image as {
        data: ArrayLike<number>;
        width: number;
        height: number;
      };
      return { width, height, data: Array.from(data) };
    }
    return Object.fromEntries(
      Object.entries(image).map(([size, value]) => [size, toPlainImage(value)]),
    );
  };
  const action = {
    ...api("action", [
      "setTitle",
      "getTitle",
      "setBadgeText",
      "getBadgeText",
      "setBadgeBackgroundColor",
      "getBadgeBackgroundColor",
      "setBadgeTextColor",
      "getBadgeTextColor",
      "setPopup",
      "getPopup",
      "enable",
      "disable",
      "isEnabled",
      "openPopup",
      "getUserSettings",
    ]),
    setIcon: (
      details: { imageData?: unknown; path?: unknown; tabId?: number } = {},
      callback?: Listener,
    ) =>
      call(
        "action.setIcon",
        callback
          ? [{ ...details, imageData: toPlainImage(details.imageData) }, callback]
          : [{ ...details, imageData: toPlainImage(details.imageData) }],
      ),
    ...eventsOf("action", ["onClicked", "onUserSettingsChanged"]),
  };
  set("action", action);
  set("browserAction", action);

  // Native messaging, for desktop companions such as the 1Password app.
  const nativePorts = new Map<
    number,
    { message: (value: unknown) => void; disconnect: (error?: string) => void }
  >();
  const connectNative = (application: string) => {
    const onMessage = new Set<Listener>();
    const onDisconnect = new Set<Listener>();
    let hostPortId: number | undefined;
    let closed = false;
    const queued: Array<unknown> = [];
    const port = {
      name: application,
      sender: undefined,
      onMessage: {
        addListener: (listener: Listener) => void onMessage.add(listener),
        removeListener: (listener: Listener) => void onMessage.delete(listener),
        hasListener: (listener: Listener) => onMessage.has(listener),
        hasListeners: () => onMessage.size > 0,
      },
      onDisconnect: {
        addListener: (listener: Listener) => void onDisconnect.add(listener),
        removeListener: (listener: Listener) => void onDisconnect.delete(listener),
        hasListener: (listener: Listener) => onDisconnect.has(listener),
        hasListeners: () => onDisconnect.size > 0,
      },
      postMessage: (message: unknown) => {
        if (closed) throw new Error("Attempting to use a disconnected port object");
        if (hostPortId === undefined) queued.push(message);
        else void bridge.invoke("runtime.nativePortPost", [hostPortId, message]);
      },
      disconnect: () => {
        if (closed) return;
        closed = true;
        if (hostPortId === undefined) return;
        nativePorts.delete(hostPortId);
        void bridge.invoke("runtime.nativePortClose", [hostPortId]);
      },
    };
    const end = (error?: string) => {
      if (closed) return;
      closed = true;
      if (hostPortId !== undefined) nativePorts.delete(hostPortId);
      if (error) console.warn(`[t3] native host ${application}: ${error}`);
      for (const listener of onDisconnect) listener(port);
    };
    bridge.invoke("runtime.connectNative", [application]).then(
      (id) => {
        if (closed) {
          void bridge.invoke("runtime.nativePortClose", [id]);
          return;
        }
        hostPortId = id as number;
        nativePorts.set(hostPortId, {
          message: (value) => {
            for (const listener of onMessage) listener(value, port);
          },
          disconnect: end,
        });
        for (const message of queued.splice(0))
          void bridge.invoke("runtime.nativePortPost", [hostPortId, message]);
      },
      (error) => end(String((error as Error | undefined)?.message ?? error)),
    );
    return port;
  };
  set("runtime", {
    connectNative,
    sendNativeMessage: (application: string, message: unknown, callback?: Listener) =>
      call(
        "runtime.sendNativeMessage",
        callback ? [application, message, callback] : [application, message],
      ),
    openOptionsPage: (callback?: Listener) =>
      call("runtime.openOptionsPage", callback ? [callback] : []),
  });
  set(
    "runtime",
    {
      setUninstallURL: (_url: string, callback?: Listener) => {
        if (callback) queueMicrotask(() => callback());
        else return Promise.resolve();
        return undefined;
      },
      requestUpdateCheck: (callback?: Listener) => {
        const result = { status: "no_update" };
        if (callback) queueMicrotask(() => callback(result.status, {}));
        else return Promise.resolve(result);
        return undefined;
      },
      ...eventsOf("runtime", [
        "onConnectExternal",
        "onMessageExternal",
        "onUpdateAvailable",
        "onRestartRequired",
      ]),
    },
    true,
  );
}
