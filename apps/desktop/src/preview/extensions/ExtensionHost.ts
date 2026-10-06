// @effect-diagnostics globalTimers:off globalDate:off -- The extension host answers extension IPC and Electron events imperatively, outside any Effect runtime.
import type {
  PreviewExtension,
  PreviewExtensionAction,
  PreviewExtensionAnchor,
  PreviewExtensionSource,
} from "@t3tools/contracts";
import {
  BrowserWindow,
  Notification,
  app,
  ipcMain,
  nativeImage,
  net,
  screen,
  webContents as AllWebContents,
  webFrameMain,
  type IpcMainInvokeEvent,
  type Session,
  type WebContents,
} from "electron";

import {
  PREVIEW_EXTENSION_EVENT_CHANNEL as EVENT_CHANNEL,
  PREVIEW_EXTENSION_INVOKE_CHANNEL as INVOKE_CHANNEL,
} from "./channels.ts";
import { manifestKeyFor, parseCrx } from "./crx.ts";
import {
  type ExtensionStore,
  type InstalledExtension,
  listProfileExtensions,
  readIconDataUrl,
  resolveInside,
} from "./ExtensionStore.ts";
import { type ExtensionIconSet, localizeManifestString, manifestAction } from "./manifest.ts";
import { NativeHostPorts } from "./NativeHostPorts.ts";
import { globToRegExp, matchesUrlPattern } from "./urlPatterns.ts";

const WINDOW_ID_NONE = -1;
const WINDOW_ID_CURRENT = -2;
/** Chrome's bounds for an action popup. */
const POPUP_MIN_SIZE = 25;
const POPUP_MAX_WIDTH = 800;
const POPUP_MAX_HEIGHT = 600;
/** Toolbar icons draw at 16 CSS pixels; 32 keeps them sharp on Retina screens. */
const ICON_SIZE = 32;
const PRELOAD_IDS = {
  worker: "t3code-preview-extensions-worker",
  frame: "t3code-preview-extensions-frame",
} as const;

type Args = ReadonlyArray<unknown>;
type Dict = Readonly<Record<string, unknown>>;

const asDict = (value: unknown): Dict =>
  value !== null && typeof value === "object" ? (value as Dict) : {};
const optionalNumber = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? value : undefined;
const errorMessage = (error: unknown): string =>
  error instanceof Error ? error.message : String(error);

/** An extension's service worker or page, where API calls come from and events go. */
interface ExtensionContext {
  readonly key: string;
  readonly session: Session;
  readonly extensionId: string;
  /** The browser window the context belongs to; undefined for service workers. */
  readonly windowId: () => number | undefined;
  readonly send: (name: string, args: Args) => void;
}

interface ActionDetails {
  title?: string | undefined;
  badgeText?: string | undefined;
  badgeBackgroundColor?: string | null | undefined;
  badgeBackgroundColorArray?: ReadonlyArray<number> | undefined;
  badgeTextColor?: string | null | undefined;
  iconDataUrl?: string | null | undefined;
  popup?: string | undefined;
  enabled?: boolean | undefined;
}

interface ActionStore {
  readonly global: ActionDetails;
  readonly tabs: Map<number, ActionDetails>;
}

interface SessionState {
  readonly session: Session;
  readonly key: number;
  /** Loaded extension ids, mapped to the version loaded. */
  readonly loaded: Map<string, string>;
  readonly actions: Map<string, ActionStore>;
  readonly menus: Map<string, Map<string | number, Dict>>;
  /** Optional permissions each extension has requested, by extension id. */
  readonly grantedPermissions: Map<string, Set<string>>;
  activeTabId: number | undefined;
  ready: Promise<void>;
}

interface ResolvedAction {
  readonly title: string;
  readonly badgeText: string;
  readonly badgeBackgroundColor: string | null;
  readonly badgeBackgroundColorArray: ReadonlyArray<number> | undefined;
  readonly badgeTextColor: string | null;
  readonly iconDataUrl: string | null;
  readonly popup: string;
  readonly enabled: boolean;
}

export interface ExtensionHostOptions {
  readonly store: ExtensionStore;
  /** The built preview-extension-preload.cjs. */
  readonly preloadPath: string;
  readonly platform: NodeJS.Platform;
  readonly homeDirectory: string;
  /** Sent to the Chrome Web Store, which serves the package built for it. */
  readonly chromeVersion: string;
  /** The installed set or some toolbar state changed. */
  readonly onChange: () => void;
  readonly log: (message: string, details?: Record<string, unknown>) => void;
}

type Handler = (context: ExtensionContext, state: SessionState, args: Args) => unknown;

const toCssColor = (value: unknown): string | null => {
  if (typeof value === "string") return value;
  if (Array.isArray(value) && value.length >= 3) {
    const [red, green, blue, alpha = 255] = value.map(Number);
    return `rgba(${red}, ${green}, ${blue}, ${(alpha ?? 255) / 255})`;
  }
  return null;
};

/** ImageData (RGBA, straight alpha) to a PNG data URL. */
const imageDataToDataUrl = (image: Dict): string | null => {
  const width = optionalNumber(image.width);
  const height = optionalNumber(image.height);
  const data = image.data;
  if (!width || !height || !Array.isArray(data) || data.length < width * height * 4) return null;
  // nativeImage takes Skia's native order: BGRA with premultiplied alpha.
  const bitmap = Buffer.alloc(width * height * 4);
  for (let offset = 0; offset < bitmap.length; offset += 4) {
    const alpha = Number(data[offset + 3]) / 255;
    bitmap[offset] = Math.round(Number(data[offset + 2]) * alpha);
    bitmap[offset + 1] = Math.round(Number(data[offset + 1]) * alpha);
    bitmap[offset + 2] = Math.round(Number(data[offset]) * alpha);
    bitmap[offset + 3] = Number(data[offset + 3]);
  }
  return nativeImage.createFromBitmap(bitmap, { width, height }).toDataURL();
};

/** Of a size-keyed set, the entry the toolbar should draw. */
const pickSized = <T>(value: unknown, isLeaf: (candidate: unknown) => boolean): T | undefined => {
  if (value === undefined || value === null) return undefined;
  if (isLeaf(value)) return value as T;
  const entries = Object.entries(asDict(value))
    .map(([size, entry]) => [Number(size), entry] as const)
    .filter(([size]) => Number.isFinite(size))
    .toSorted(([a], [b]) => a - b);
  return (entries.find(([size]) => size >= ICON_SIZE) ?? entries.at(-1))?.[1] as T | undefined;
};

/**
 * Runs Chrome extensions in the preview browser's persistent profiles.
 *
 * Electron loads an extension and supports part of its API. This fills in
 * what the browser around it normally provides: the windows and tabs the
 * preview has, the toolbar button and its popup, native messaging to desktop
 * companions, and namespaces such as `contextMenus` that extensions expect to
 * exist. The extension side of that lives in preview-extension-preload.ts.
 */
export class ExtensionHost {
  readonly #options: ExtensionHostOptions;
  readonly #sessions = new Map<Session, SessionState>();
  readonly #contexts = new Map<string, ExtensionContext>();
  readonly #ports: NativeHostPorts;
  /** Preview tabs and extension windows, by webContents id. */
  readonly #tracked = new Set<number>();
  readonly #extensionWindows = new Map<number, { readonly type: "normal" | "popup" }>();
  /** Action popup webContents id to the window it opened over. */
  readonly #popupOwners = new Map<number, number>();
  readonly #favicons = new Map<number, string>();
  readonly #lastAccessed = new Map<number, number>();
  readonly #notifications = new Map<string, Notification>();
  readonly #loadErrors = new Map<string, string>();
  readonly #iconCache = new Map<string, Promise<string | null>>();
  readonly #handlers: Readonly<Record<string, Handler>>;
  readonly #disposers: Array<() => void> = [];
  #installed: Promise<ReadonlyArray<InstalledExtension>> | undefined;
  #lastFocusedWindowId: number | undefined;
  #popup: { readonly window: BrowserWindow; readonly extensionId: string } | undefined;
  #popupClosed: { readonly extensionId: string; readonly at: number } | undefined;
  #changeTimer: ReturnType<typeof setTimeout> | undefined;
  #nextSessionKey = 1;
  #nextDownloadId = 1;

  constructor(options: ExtensionHostOptions) {
    this.#options = options;
    this.#ports = new NativeHostPorts({ platform: options.platform, home: options.homeDirectory });
    this.#handlers = this.#makeHandlers();

    ipcMain.handle(INVOKE_CHANNEL, (event, method: unknown, args: unknown) =>
      this.#invokeFromFrame(event, method, args),
    );
    this.#disposers.push(() => ipcMain.removeHandler(INVOKE_CHANNEL));

    const onCreated = (_event: unknown, contents: WebContents) => {
      // Deferred so a window this host is creating is registered first.
      setImmediate(() => this.#track(contents));
    };
    app.on("web-contents-created", onCreated);
    this.#disposers.push(() => app.off("web-contents-created", onCreated));

    const onFocus = (_event: unknown, window: BrowserWindow) => {
      this.#lastFocusedWindowId = window.id;
      for (const state of this.#sessions.values()) {
        if (this.#windowsOf(state).some((candidate) => candidate.id === window.id)) {
          this.#emit(state.session, "windows.onFocusChanged", [window.id]);
        }
      }
    };
    app.on("browser-window-focus", onFocus);
    this.#disposers.push(() => app.off("browser-window-focus", onFocus));
  }

  dispose(): void {
    for (const dispose of this.#disposers.splice(0)) dispose();
    this.#ports.dispose();
    if (this.#changeTimer) clearTimeout(this.#changeTimer);
    if (this.#popup && !this.#popup.window.isDestroyed()) this.#popup.window.destroy();
    for (const notification of this.#notifications.values()) notification.close();
  }

  // ---------------------------------------------------------------------------
  // Sessions and loading

  /** Loads the enabled extensions into a persistent preview session. Idempotent. */
  attachSession(session: Session): Promise<void> {
    const existing = this.#sessions.get(session);
    if (existing) return existing.ready;
    // Incognito profiles run without extensions, as Chrome does by default.
    if (!session.isPersistent()) return Promise.resolve();
    const state: SessionState = {
      session,
      key: this.#nextSessionKey++,
      loaded: new Map(),
      actions: new Map(),
      menus: new Map(),
      grantedPermissions: new Map(),
      activeTabId: undefined,
      ready: Promise.resolve(),
    };
    this.#sessions.set(session, state);
    for (const type of ["worker", "frame"] as const) {
      try {
        session.registerPreloadScript({
          id: PRELOAD_IDS[type],
          type: type === "worker" ? "service-worker" : "frame",
          filePath: this.#options.preloadPath,
        });
      } catch (error) {
        this.#options.log("Extension preload registration failed", {
          type,
          error: errorMessage(error),
        });
      }
    }
    session.serviceWorkers.on("running-status-changed", ({ versionId, runningStatus }) =>
      this.#workerStatusChanged(state, versionId, runningStatus),
    );
    state.ready = this.#loadAll(state);
    return state.ready;
  }

  async #loadAll(state: SessionState): Promise<void> {
    const installed = await this.#installedList();
    await Promise.all(
      installed.filter((entry) => entry.enabled).map((entry) => this.#load(state, entry)),
    );
    this.#notifyChange();
  }

  async #load(state: SessionState, extension: InstalledExtension): Promise<void> {
    this.#unload(state, extension.id);
    try {
      const loaded = await state.session.extensions.loadExtension(extension.directory, {
        allowFileAccess: false,
      });
      if (loaded.id !== extension.id) {
        this.#options.log("Extension loaded under a different id", {
          expected: extension.id,
          actual: loaded.id,
        });
      }
      state.loaded.set(loaded.id, extension.version);
      this.#loadErrors.delete(extension.id);
    } catch (error) {
      this.#loadErrors.set(extension.id, errorMessage(error));
      this.#options.log("Extension failed to load", {
        id: extension.id,
        error: errorMessage(error),
      });
    }
  }

  #unload(state: SessionState, extensionId: string): void {
    if (state.loaded.delete(extensionId)) {
      try {
        state.session.extensions.removeExtension(extensionId);
      } catch {
        // Already gone.
      }
    }
    state.actions.delete(extensionId);
    state.menus.delete(extensionId);
    for (const [key, context] of this.#contexts) {
      if (context.session === state.session && context.extensionId === extensionId) {
        this.#dropContext(key);
      }
    }
    if (this.#popup?.extensionId === extensionId && !this.#popup.window.isDestroyed()) {
      this.#popup.window.close();
    }
  }

  #installedList(): Promise<ReadonlyArray<InstalledExtension>> {
    this.#installed ??= this.#options.store.list().catch((error: unknown) => {
      this.#installed = undefined;
      throw error;
    });
    return this.#installed;
  }

  async #installedById(id: string): Promise<InstalledExtension | undefined> {
    return (await this.#installedList()).find((entry) => entry.id === id);
  }

  async #afterStoreChange(changed: ReadonlyArray<InstalledExtension>): Promise<void> {
    this.#installed = undefined;
    for (const state of this.#sessions.values()) {
      for (const extension of changed) {
        if (extension.enabled) await this.#load(state, extension);
        else this.#unload(state, extension.id);
      }
    }
    this.#notifyChange();
  }

  #notifyChange(): void {
    if (this.#changeTimer) return;
    this.#changeTimer = setTimeout(() => {
      this.#changeTimer = undefined;
      this.#options.onChange();
    }, 50);
  }

  // ---------------------------------------------------------------------------
  // Installing

  async importFromProfile(input: {
    readonly profilePath: string;
    readonly source: PreviewExtensionSource;
    readonly extensionIds: ReadonlyArray<string>;
  }): Promise<ReadonlyArray<InstalledExtension>> {
    const available = await listProfileExtensions(input.profilePath);
    const installed: Array<InstalledExtension> = [];
    for (const id of input.extensionIds) {
      const found = available.find((candidate) => candidate.id === id);
      if (!found) throw new Error("That extension is no longer installed in the browser.");
      installed.push(
        await this.#options.store.installDirectory({
          id,
          sourceDirectory: found.directory,
          source: input.source,
        }),
      );
    }
    await this.#afterStoreChange(installed);
    return installed;
  }

  async installFromWebStore(extensionId: string): Promise<InstalledExtension> {
    const url =
      "https://clients2.google.com/service/update2/crx?response=redirect" +
      `&prodversion=${encodeURIComponent(this.#options.chromeVersion)}` +
      `&acceptformat=crx2,crx3&x=id%3D${extensionId}%26uc`;
    const response = await net.fetch(url);
    if (!response.ok) {
      throw new Error(`The Chrome Web Store answered ${response.status} for that extension.`);
    }
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.length === 0) throw new Error("The Chrome Web Store has no extension with that id.");
    const crx = parseCrx(bytes);
    const manifestKey = manifestKeyFor(crx, extensionId);
    if (!manifestKey) throw new Error("The downloaded package is not signed as that extension.");
    const installed = await this.#options.store.installArchive({
      id: extensionId,
      archive: crx.archive,
      manifestKey,
      source: { kind: "webStore" },
    });
    await this.#afterStoreChange([installed]);
    return installed;
  }

  async setEnabled(extensionId: string, enabled: boolean): Promise<void> {
    await this.#options.store.setEnabled(extensionId, enabled);
    this.#installed = undefined;
    const extension = await this.#installedById(extensionId);
    if (extension) await this.#afterStoreChange([extension]);
  }

  async remove(extensionId: string): Promise<void> {
    for (const state of this.#sessions.values()) this.#unload(state, extensionId);
    await this.#options.store.remove(extensionId);
    this.#loadErrors.delete(extensionId);
    this.#installed = undefined;
    this.#notifyChange();
  }

  // ---------------------------------------------------------------------------
  // Toolbar

  /** Installed extensions, with toolbar state as one preview tab sees it. */
  async list(tabWebContentsId?: number): Promise<ReadonlyArray<PreviewExtension>> {
    const installed = await this.#installedList();
    const tab =
      tabWebContentsId === undefined ? undefined : AllWebContents.fromId(tabWebContentsId);
    const state = tab && !tab.isDestroyed() ? this.#sessions.get(tab.session) : undefined;
    return Promise.all(
      installed.map(async (extension): Promise<PreviewExtension> => {
        const declared = manifestAction(extension.manifest);
        let action: PreviewExtensionAction | null = null;
        if (declared) {
          const resolved = this.#resolveAction(state, extension, tab?.id);
          action = {
            title: resolved.title,
            badgeText: resolved.badgeText,
            badgeBackgroundColor: resolved.badgeBackgroundColor,
            badgeTextColor: resolved.badgeTextColor,
            iconDataUrl:
              resolved.iconDataUrl ??
              (await this.#icon(extension, declared.default_icon ?? extension.manifest.icons)),
            hasPopup: resolved.popup !== "",
            enabled: resolved.enabled,
          };
        }
        return {
          id: extension.id,
          name: extension.name,
          version: extension.version,
          enabled: extension.enabled,
          source: extension.source,
          iconDataUrl: await this.#icon(
            extension,
            extension.manifest.icons ?? declared?.default_icon,
          ),
          action,
          loadError: extension.enabled ? (this.#loadErrors.get(extension.id) ?? null) : null,
        };
      }),
    );
  }

  #icon(
    extension: InstalledExtension,
    icons: string | ExtensionIconSet | undefined,
  ): Promise<string | null> {
    if (icons === undefined) return Promise.resolve(null);
    const key = `${extension.directory}:${JSON.stringify(icons)}`;
    let icon = this.#iconCache.get(key);
    if (!icon) {
      icon = readIconDataUrl(extension.directory, icons, ICON_SIZE);
      this.#iconCache.set(key, icon);
    }
    return icon;
  }

  #actionStore(state: SessionState, extensionId: string): ActionStore {
    let store = state.actions.get(extensionId);
    if (!store) {
      store = { global: {}, tabs: new Map() };
      state.actions.set(extensionId, store);
    }
    return store;
  }

  #resolveAction(
    state: SessionState | undefined,
    extension: InstalledExtension,
    tabId: number | undefined,
  ): ResolvedAction {
    const declared = manifestAction(extension.manifest);
    const store = state?.actions.get(extension.id);
    // A tab's own value wins; one it cleared falls back to the extension-wide value.
    const merged: Record<string, unknown> = { ...store?.global };
    const forTab = tabId === undefined ? undefined : store?.tabs.get(tabId);
    for (const [key, value] of Object.entries(forTab ?? {})) {
      if (value !== undefined) merged[key] = value;
    }
    const action = merged as ActionDetails;
    const defaultTitle =
      declared?.default_title === undefined
        ? undefined
        : localizeManifestString(declared.default_title, extension.messages);
    return {
      title: action.title ?? defaultTitle ?? extension.name,
      badgeText: action.badgeText ?? "",
      badgeBackgroundColor: action.badgeBackgroundColor ?? null,
      badgeBackgroundColorArray: action.badgeBackgroundColorArray,
      badgeTextColor: action.badgeTextColor ?? null,
      iconDataUrl: action.iconDataUrl ?? null,
      popup: action.popup ?? declared?.default_popup ?? "",
      enabled: action.enabled ?? true,
    };
  }

  /**
   * Opens an extension's popup under its toolbar button, or sends
   * `action.onClicked` when it has none. `anchor` is the button's rectangle in
   * the owner window's CSS pixels.
   */
  async openPopup(input: {
    readonly extensionId: string;
    readonly tabWebContentsId: number;
    readonly anchor: PreviewExtensionAnchor;
    readonly ownerWebContentsId: number;
  }): Promise<void> {
    const tab = AllWebContents.fromId(input.tabWebContentsId);
    const owner = AllWebContents.fromId(input.ownerWebContentsId);
    const ownerWindow = owner ? BrowserWindow.fromWebContents(owner) : null;
    if (!tab || tab.isDestroyed() || !owner || !ownerWindow) {
      throw new Error("That browser tab is no longer open.");
    }
    const state = this.#sessions.get(tab.session);
    if (!state) throw new Error("Extensions do not run in this browser profile.");
    await state.ready;
    const extension = await this.#installedById(input.extensionId);
    if (!extension?.enabled || !state.loaded.has(extension.id)) {
      throw new Error("That extension is not running.");
    }

    // Clicking the button while its popup is open closes it: the click first
    // blurs the popup, which closes it, so a click right after reads as a toggle.
    const recentlyClosed = this.#popupClosed;
    if (recentlyClosed?.extensionId === extension.id && Date.now() - recentlyClosed.at < 300) {
      this.#popupClosed = undefined;
      return;
    }
    if (this.#popup && !this.#popup.window.isDestroyed()) {
      const same = this.#popup.extensionId === extension.id;
      this.#popup.window.close();
      if (same) return;
    }

    this.#activate(state, tab);
    const action = this.#resolveAction(state, extension, tab.id);
    if (!action.enabled) return;
    if (action.popup === "") {
      this.#emit(state.session, "action.onClicked", [this.#tabInfo(state, tab)], extension.id);
      return;
    }

    const zoom = owner.getZoomFactor();
    const content = ownerWindow.getContentBounds();
    const anchorRight = Math.round(content.x + (input.anchor.x + input.anchor.width) * zoom);
    const anchorBottom = Math.round(content.y + (input.anchor.y + input.anchor.height) * zoom);
    const popup = new BrowserWindow({
      x: anchorRight - POPUP_MIN_SIZE,
      y: anchorBottom + 4,
      width: POPUP_MIN_SIZE,
      height: POPUP_MIN_SIZE,
      show: false,
      frame: false,
      resizable: false,
      movable: false,
      minimizable: false,
      maximizable: false,
      fullscreenable: false,
      skipTaskbar: true,
      parent: ownerWindow,
      hasShadow: true,
      roundedCorners: true,
      backgroundColor: "#ffffff",
      webPreferences: {
        session: state.session,
        sandbox: true,
        contextIsolation: true,
        nodeIntegration: false,
        enablePreferredSizeMode: true,
      },
    });
    const popupContentsId = popup.webContents.id;
    this.#popupOwners.set(popupContentsId, ownerWindow.id);
    this.#popup = { window: popup, extensionId: extension.id };

    const place = (width: number, height: number) => {
      if (popup.isDestroyed()) return;
      const area = screen.getDisplayNearestPoint({ x: anchorRight, y: anchorBottom }).workArea;
      const clampedWidth = Math.min(Math.max(width, POPUP_MIN_SIZE), POPUP_MAX_WIDTH);
      const clampedHeight = Math.min(Math.max(height, POPUP_MIN_SIZE), POPUP_MAX_HEIGHT);
      const x = Math.min(
        Math.max(anchorRight - clampedWidth, area.x),
        area.x + area.width - clampedWidth,
      );
      const y = Math.min(Math.max(anchorBottom + 4, area.y), area.y + area.height - clampedHeight);
      popup.setBounds({ x, y, width: clampedWidth, height: clampedHeight });
    };
    const reveal = () => {
      if (!popup.isDestroyed() && !popup.isVisible()) popup.show();
    };
    popup.webContents.on("preferred-size-changed", (_event, size) => {
      place(size.width, size.height);
      reveal();
    });
    popup.webContents.on("before-input-event", (event, keyInput) => {
      if (keyInput.type === "keyDown" && keyInput.key === "Escape") {
        event.preventDefault();
        popup.close();
      }
    });
    popup.on("blur", () => {
      if (!popup.isDestroyed() && !popup.webContents.isDevToolsOpened()) popup.close();
    });
    popup.once("closed", () => {
      this.#popupOwners.delete(popupContentsId);
      if (this.#popup?.window === popup) this.#popup = undefined;
      this.#popupClosed = { extensionId: extension.id, at: Date.now() };
    });
    // A popup that never reports a size still has to appear.
    setTimeout(() => {
      if (!popup.isDestroyed() && !popup.isVisible()) {
        place(360, 480);
        reveal();
      }
    }, 1500);
    const path = action.popup.replace(/^\/+/, "");
    await popup.loadURL(`chrome-extension://${extension.id}/${path}`).catch((error: unknown) => {
      this.#options.log("Extension popup failed to load", {
        id: extension.id,
        error: errorMessage(error),
      });
    });
  }

  // ---------------------------------------------------------------------------
  // Contexts and events

  #workerStatusChanged(state: SessionState, versionId: number, status: string): void {
    const key = `worker:${state.key}:${versionId}`;
    if (status === "stopping" || status === "stopped") {
      this.#dropContext(key);
      return;
    }
    if (this.#contexts.has(key)) return;
    const worker = state.session.serviceWorkers.getWorkerFromVersionID(versionId);
    if (!worker || !worker.scope.startsWith("chrome-extension://")) return;
    const context: ExtensionContext = {
      key,
      session: state.session,
      extensionId: new URL(worker.scope).host,
      windowId: () => undefined,
      send: (name, args) => {
        if (!worker.isDestroyed()) worker.send(EVENT_CHANNEL, name, args);
      },
    };
    worker.ipc.removeHandler(INVOKE_CHANNEL);
    worker.ipc.handle(INVOKE_CHANNEL, (_event, method: unknown, args: unknown) =>
      this.#invoke(context, method, args),
    );
    this.#contexts.set(key, context);
  }

  #invokeFromFrame(event: IpcMainInvokeEvent, method: unknown, args: unknown): Promise<unknown> {
    const sender = event.sender;
    const frame = event.senderFrame;
    const state = this.#sessions.get(sender.session);
    let origin: URL | undefined;
    try {
      origin = frame ? new URL(frame.url) : undefined;
    } catch {
      origin = undefined;
    }
    if (!state || !frame || origin?.protocol !== "chrome-extension:") {
      return Promise.reject(new Error("Not an extension page."));
    }
    const key = `frame:${sender.id}:${frame.processId}:${frame.routingId}`;
    let context = this.#contexts.get(key);
    if (!context || context.extensionId !== origin.host) {
      context = {
        key,
        session: sender.session,
        extensionId: origin.host,
        windowId: () => this.#popupOwners.get(sender.id) ?? this.#windowIdOf(sender),
        send: (name, eventArgs) => {
          // Sending to a disposed frame logs an error rather than throwing.
          if (frame.isDestroyed() || frame.detached || !frame.url.startsWith("chrome-extension:")) {
            this.#dropContext(key);
            return;
          }
          frame.send(EVENT_CHANNEL, name, eventArgs);
        },
      };
      this.#contexts.set(key, context);
      sender.once("destroyed", () => this.#dropContext(key));
    }
    return this.#invoke(context, method, args);
  }

  #dropContext(key: string): void {
    this.#contexts.delete(key);
    this.#ports.closeOwnedBy(key);
  }

  async #invoke(context: ExtensionContext, method: unknown, rawArgs: unknown): Promise<unknown> {
    const state = this.#sessions.get(context.session);
    const handler = typeof method === "string" ? this.#handlers[method] : undefined;
    if (!state) throw new Error("Extensions do not run in this browser profile.");
    if (!handler) throw new Error(`${String(method)} is not available in T3 Code.`);
    return handler(context, state, Array.isArray(rawArgs) ? rawArgs : []);
  }

  /** Sends an event to every context of the session's extensions, or of one extension. */
  #emit(session: Session, name: string, args: Args, extensionId?: string): void {
    for (const context of this.#contexts.values()) {
      if (context.session !== session) continue;
      if (extensionId !== undefined && context.extensionId !== extensionId) continue;
      context.send(name, args);
    }
  }

  // ---------------------------------------------------------------------------
  // Tabs and windows

  /** Follows a preview tab or extension window so extensions can see it as a tab. */
  #track(contents: WebContents): void {
    if (contents.isDestroyed() || this.#tracked.has(contents.id)) return;
    const state = this.#sessions.get(contents.session);
    if (!state) return;
    const type = contents.getType();
    if ((type !== "webview" && type !== "window") || this.#popupOwners.has(contents.id)) return;
    const id = contents.id;
    this.#tracked.add(id);
    this.#lastAccessed.set(id, Date.now());

    const session = state.session;
    const updated = (changeInfo: Dict) => {
      if (contents.isDestroyed()) return;
      this.#emit(session, "tabs.onUpdated", [id, changeInfo, this.#tabInfo(state, contents)]);
    };
    const navigation = (
      name: string,
      isMainFrame: boolean,
      processId: number,
      routingId: number,
      details: Dict,
    ) => {
      this.#emit(session, `webNavigation.${name}`, [
        {
          tabId: id,
          processId,
          timeStamp: Date.now(),
          ...this.#frameIds(isMainFrame, processId, routingId),
          ...details,
        },
      ]);
    };

    contents.on("did-start-loading", () => updated({ status: "loading" }));
    contents.on("did-stop-loading", () => updated({ status: "complete" }));
    contents.on("page-title-updated", (_event, title) => updated({ title }));
    contents.on("page-favicon-updated", (_event, favicons) => {
      const favicon = favicons[0];
      if (!favicon) return;
      this.#favicons.set(id, favicon);
      updated({ favIconUrl: favicon });
    });
    contents.on("did-navigate", (_event, url) => {
      // Chrome resets tab-specific toolbar state when the tab navigates.
      for (const store of state.actions.values()) store.tabs.delete(id);
      this.#favicons.delete(id);
      updated({ url });
      this.#notifyChange();
    });
    contents.on("focus", () => this.#activate(state, contents));
    contents.on("did-start-navigation", (details) => {
      if (details.isSameDocument || !details.frame) return;
      navigation(
        "onBeforeNavigate",
        details.isMainFrame,
        details.frame.processId,
        details.frame.routingId,
        {
          url: details.url,
        },
      );
    });
    contents.on(
      "did-frame-navigate",
      (_event, url, _code, _status, isMainFrame, processId, routingId) =>
        navigation("onCommitted", isMainFrame, processId, routingId, {
          url,
          transitionType: "link",
          transitionQualifiers: [],
        }),
    );
    contents.on("dom-ready", () => {
      const main = contents.mainFrame;
      navigation("onDOMContentLoaded", true, main.processId, main.routingId, {
        url: contents.getURL(),
      });
    });
    contents.on("did-frame-finish-load", (_event, isMainFrame, processId, routingId) => {
      const frame = webFrameMain.fromId(processId, routingId);
      navigation("onCompleted", isMainFrame, processId, routingId, { url: frame?.url ?? "" });
    });
    contents.on("did-navigate-in-page", (_event, url, isMainFrame, processId, routingId) =>
      navigation("onHistoryStateUpdated", isMainFrame, processId, routingId, {
        url,
        transitionType: "link",
        transitionQualifiers: [],
      }),
    );
    contents.on(
      "did-fail-load",
      (_event, code, description, url, isMainFrame, processId, routingId) => {
        if (code === -3) return; // Aborted, usually by a newer navigation.
        navigation("onErrorOccurred", isMainFrame, processId, routingId, {
          url,
          error: description,
        });
      },
    );
    const windowId = this.#windowIdOf(contents);
    contents.once("destroyed", () => {
      this.#tracked.delete(id);
      this.#favicons.delete(id);
      this.#lastAccessed.delete(id);
      for (const store of state.actions.values()) store.tabs.delete(id);
      if (state.activeTabId === id) state.activeTabId = undefined;
      this.#emit(session, "tabs.onRemoved", [id, { windowId, isWindowClosing: false }]);
    });
    this.#emit(session, "tabs.onCreated", [this.#tabInfo(state, contents)]);
  }

  #activate(state: SessionState, contents: WebContents): void {
    this.#lastAccessed.set(contents.id, Date.now());
    if (contents.getType() !== "webview" || state.activeTabId === contents.id) return;
    state.activeTabId = contents.id;
    this.#emit(state.session, "tabs.onActivated", [
      { tabId: contents.id, windowId: this.#windowIdOf(contents) },
    ]);
    this.#notifyChange();
  }

  #frameIds(
    isMainFrame: boolean,
    processId: number,
    routingId: number,
  ): { readonly frameId: number; readonly parentFrameId: number } {
    if (isMainFrame) return { frameId: 0, parentFrameId: -1 };
    const frame = webFrameMain.fromId(processId, routingId);
    const parent = frame?.parent;
    return {
      frameId: frame?.frameTreeNodeId ?? routingId,
      parentFrameId: !parent ? -1 : parent.parent ? parent.frameTreeNodeId : 0,
    };
  }

  #tabsOf(state: SessionState): ReadonlyArray<WebContents> {
    const tabs: Array<WebContents> = [];
    for (const id of this.#tracked) {
      const contents = AllWebContents.fromId(id);
      if (contents && !contents.isDestroyed() && contents.session === state.session) {
        tabs.push(contents);
      }
    }
    return tabs;
  }

  #windowIdOf(contents: WebContents): number {
    const host = contents.getType() === "webview" ? contents.hostWebContents : contents;
    if (!host || host.isDestroyed()) return WINDOW_ID_NONE;
    return BrowserWindow.fromWebContents(host)?.id ?? WINDOW_ID_NONE;
  }

  #windowsOf(state: SessionState): ReadonlyArray<BrowserWindow> {
    const windows = new Map<number, BrowserWindow>();
    for (const tab of this.#tabsOf(state)) {
      const id = this.#windowIdOf(tab);
      const window = id === WINDOW_ID_NONE ? null : BrowserWindow.fromId(id);
      if (window && !window.isDestroyed()) windows.set(id, window);
    }
    return [...windows.values()];
  }

  #isActive(state: SessionState, contents: WebContents): boolean {
    // Extension windows and page popups hold a single tab.
    if (contents.getType() !== "webview") return true;
    const windowId = this.#windowIdOf(contents);
    const active =
      state.activeTabId === undefined ? undefined : AllWebContents.fromId(state.activeTabId);
    if (active && !active.isDestroyed() && this.#windowIdOf(active) === windowId) {
      return active.id === contents.id;
    }
    let latest: WebContents | undefined;
    for (const tab of this.#tabsOf(state)) {
      if (tab.getType() !== "webview" || this.#windowIdOf(tab) !== windowId) continue;
      if (
        !latest ||
        (this.#lastAccessed.get(tab.id) ?? 0) > (this.#lastAccessed.get(latest.id) ?? 0)
      ) {
        latest = tab;
      }
    }
    return latest?.id === contents.id;
  }

  #tabInfo(state: SessionState, contents: WebContents): Dict {
    const windowId = this.#windowIdOf(contents);
    const index = this.#tabsOf(state)
      .filter((tab) => this.#windowIdOf(tab) === windowId)
      .findIndex((tab) => tab.id === contents.id);
    const active = this.#isActive(state, contents);
    const favIconUrl = this.#favicons.get(contents.id);
    return {
      id: contents.id,
      index: Math.max(index, 0),
      windowId,
      active,
      highlighted: active,
      selected: active,
      pinned: false,
      audible: contents.isCurrentlyAudible(),
      mutedInfo: { muted: contents.isAudioMuted() },
      discarded: false,
      autoDiscardable: false,
      frozen: false,
      incognito: false,
      groupId: -1,
      url: contents.getURL(),
      title: contents.getTitle(),
      status: contents.isLoading() ? "loading" : "complete",
      lastAccessed: this.#lastAccessed.get(contents.id) ?? Date.now(),
      ...(favIconUrl === undefined ? {} : { favIconUrl }),
    };
  }

  #lastFocusedWindow(state: SessionState): number {
    const windows = this.#windowsOf(state);
    if (windows.some((window) => window.id === this.#lastFocusedWindowId)) {
      return this.#lastFocusedWindowId ?? WINDOW_ID_NONE;
    }
    const active =
      state.activeTabId === undefined ? undefined : AllWebContents.fromId(state.activeTabId);
    if (active && !active.isDestroyed()) return this.#windowIdOf(active);
    return windows[0]?.id ?? WINDOW_ID_NONE;
  }

  #currentWindow(context: ExtensionContext, state: SessionState): number {
    return context.windowId() ?? this.#lastFocusedWindow(state);
  }

  #windowInfo(state: SessionState, window: BrowserWindow, populate: boolean): Dict {
    const bounds = window.getBounds();
    return {
      id: window.id,
      focused: window.isFocused(),
      top: bounds.y,
      left: bounds.x,
      width: bounds.width,
      height: bounds.height,
      incognito: false,
      alwaysOnTop: window.isAlwaysOnTop(),
      type: this.#extensionWindows.get(window.id)?.type ?? "normal",
      state: window.isMinimized()
        ? "minimized"
        : window.isFullScreen()
          ? "fullscreen"
          : window.isMaximized()
            ? "maximized"
            : "normal",
      ...(populate
        ? {
            tabs: this.#tabsOf(state)
              .filter((tab) => this.#windowIdOf(tab) === window.id)
              .map((tab) => this.#tabInfo(state, tab)),
          }
        : {}),
    };
  }

  #tabById(state: SessionState, tabId: unknown): WebContents {
    const contents = typeof tabId === "number" ? AllWebContents.fromId(tabId) : undefined;
    if (
      !contents ||
      contents.isDestroyed() ||
      !this.#tracked.has(contents.id) ||
      contents.session !== state.session
    ) {
      throw new Error(`No tab with id: ${String(tabId)}.`);
    }
    return contents;
  }

  #windowById(context: ExtensionContext, state: SessionState, windowId: unknown): BrowserWindow {
    const id =
      windowId === undefined || windowId === WINDOW_ID_CURRENT
        ? this.#currentWindow(context, state)
        : windowId;
    const window = this.#windowsOf(state).find((candidate) => candidate.id === id);
    if (!window) throw new Error(`No window with id: ${String(windowId)}.`);
    return window;
  }

  #activeTabIn(state: SessionState, windowId: number): WebContents | undefined {
    return this.#tabsOf(state).find(
      (tab) => this.#windowIdOf(tab) === windowId && this.#isActive(state, tab),
    );
  }

  /** Resolves a URL an extension asks to open; only web pages and its own pages are allowed. */
  #resolveUrl(extensionId: string, raw: unknown): string {
    const url = new URL(
      typeof raw === "string" && raw !== "" ? raw : "about:blank",
      `chrome-extension://${extensionId}/`,
    );
    if (url.protocol === "chrome-extension:" && url.host !== extensionId) {
      throw new Error("Extensions can only open their own pages.");
    }
    if (!["http:", "https:", "chrome-extension:", "about:"].includes(url.protocol)) {
      throw new Error(`Cannot open ${url.protocol} URLs.`);
    }
    return url.href;
  }

  /** A window for a tab or window an extension opens, in the extension's profile. */
  #openWindow(
    context: ExtensionContext,
    state: SessionState,
    rawUrl: unknown,
    options: {
      readonly type: "normal" | "popup";
      readonly width?: number | undefined;
      readonly height?: number | undefined;
      readonly left?: number | undefined;
      readonly top?: number | undefined;
      readonly focused?: boolean | undefined;
    },
  ): BrowserWindow {
    const url = this.#resolveUrl(context.extensionId, rawUrl);
    const width = options.width ?? (options.type === "popup" ? 420 : 1100);
    const height = options.height ?? (options.type === "popup" ? 640 : 760);
    const owner = BrowserWindow.fromId(this.#currentWindow(context, state));
    const ownerBounds = owner && !owner.isDestroyed() ? owner.getBounds() : undefined;
    const window = new BrowserWindow({
      width,
      height,
      ...(options.left !== undefined && options.top !== undefined
        ? { x: options.left, y: options.top }
        : ownerBounds
          ? {
              x: Math.round(ownerBounds.x + (ownerBounds.width - width) / 2),
              y: Math.round(ownerBounds.y + Math.max((ownerBounds.height - height) / 3, 0)),
            }
          : {}),
      show: false,
      autoHideMenuBar: true,
      backgroundColor: "#ffffff",
      webPreferences: {
        session: state.session,
        sandbox: true,
        contextIsolation: true,
        nodeIntegration: false,
      },
    });
    const windowId = window.id;
    this.#extensionWindows.set(windowId, { type: options.type });
    window.once("closed", () => this.#extensionWindows.delete(windowId));
    window.once("ready-to-show", () => {
      if (options.focused === false) window.showInactive();
      else window.show();
    });
    this.#track(window.webContents);
    void window.loadURL(url).catch((error: unknown) => {
      this.#options.log("Extension window failed to load", { url, error: errorMessage(error) });
    });
    return window;
  }

  // ---------------------------------------------------------------------------
  // API implementations

  #makeHandlers(): Readonly<Record<string, Handler>> {
    const requirePermission = async (context: ExtensionContext, permission: string) => {
      const extension = await this.#installedById(context.extensionId);
      if (!extension?.manifest.permissions?.includes(permission)) {
        throw new Error(`The "${permission}" permission is required.`);
      }
      return extension;
    };
    const actionTarget = (context: ExtensionContext, state: SessionState, details: unknown) => {
      const store = this.#actionStore(state, context.extensionId);
      const tabId = optionalNumber(asDict(details).tabId);
      if (tabId === undefined) return store.global;
      let target = store.tabs.get(tabId);
      if (!target) {
        target = {};
        store.tabs.set(tabId, target);
      }
      return target;
    };
    const setAction =
      (
        apply: (
          target: ActionDetails,
          details: Dict,
          context: ExtensionContext,
        ) => void | Promise<void>,
      ): Handler =>
      async (context, state, [details]) => {
        await apply(actionTarget(context, state, details), asDict(details), context);
        this.#notifyChange();
      };
    const readAction =
      (read: (action: ResolvedAction) => unknown): Handler =>
      async (context, state, [details]) => {
        const extension = await this.#installedById(context.extensionId);
        if (!extension) throw new Error("Unknown extension.");
        return read(this.#resolveAction(state, extension, optionalNumber(asDict(details).tabId)));
      };
    const setEnabled =
      (enabled: boolean): Handler =>
      (context, state, [tabId]) => {
        const store = this.#actionStore(state, context.extensionId);
        const target = typeof tabId === "number" ? (store.tabs.get(tabId) ?? {}) : store.global;
        target.enabled = enabled;
        if (typeof tabId === "number") store.tabs.set(tabId, target);
        this.#notifyChange();
      };
    const menusOf = (context: ExtensionContext, state: SessionState) => {
      let menus = state.menus.get(context.extensionId);
      if (!menus) {
        menus = new Map();
        state.menus.set(context.extensionId, menus);
      }
      return menus;
    };
    const toChromeCookie = (cookie: Electron.Cookie) => ({
      name: cookie.name,
      value: cookie.value,
      domain: cookie.domain ?? "",
      hostOnly: cookie.hostOnly ?? false,
      path: cookie.path ?? "/",
      secure: cookie.secure ?? false,
      httpOnly: cookie.httpOnly ?? false,
      sameSite: cookie.sameSite ?? "unspecified",
      session: cookie.session ?? true,
      storeId: "0",
      ...(cookie.expirationDate === undefined ? {} : { expirationDate: cookie.expirationDate }),
    });
    const cookieFilter = (details: Dict): Electron.CookiesGetFilter => ({
      ...(typeof details.url === "string" ? { url: details.url } : {}),
      ...(typeof details.name === "string" ? { name: details.name } : {}),
      ...(typeof details.domain === "string" ? { domain: details.domain } : {}),
      ...(typeof details.path === "string" ? { path: details.path } : {}),
      ...(typeof details.secure === "boolean" ? { secure: details.secure } : {}),
      ...(typeof details.session === "boolean" ? { session: details.session } : {}),
    });
    const frames = (contents: WebContents) => {
      const main = contents.mainFrame;
      return main.framesInSubtree.map((frame) => ({
        frameId: frame === main ? 0 : frame.frameTreeNodeId,
        parentFrameId: !frame.parent
          ? -1
          : frame.parent === main
            ? 0
            : frame.parent.frameTreeNodeId,
        processId: frame.processId,
        url: frame.url,
        errorOccurred: false,
        frameType: frame === main ? "outermost_frame" : "sub_frame",
        documentLifecycle: "active",
      }));
    };
    const noop: Handler = () => undefined;
    const permissionSets = async (context: ExtensionContext, state: SessionState) => {
      const extension = await this.#installedById(context.extensionId);
      const manifest = extension?.manifest;
      const granted = state.grantedPermissions.get(context.extensionId) ?? new Set<string>();
      return {
        permissions: new Set([...(manifest?.permissions ?? []), ...granted]),
        origins: [
          ...(manifest?.host_permissions ?? []),
          ...(manifest?.manifest_version === 2
            ? (manifest.permissions ?? []).filter(
                (entry) => entry.includes("://") || entry === "<all_urls>",
              )
            : []),
          ...[...granted].filter((entry) => entry.includes("://") || entry === "<all_urls>"),
        ],
        optional: new Set([
          ...(manifest?.optional_permissions ?? []),
          ...(manifest?.optional_host_permissions ?? []),
        ]),
      };
    };
    /** Whether a granted host pattern covers a requested one. */
    const coversOrigin = (granted: ReadonlyArray<string>, requested: string) =>
      granted.some(
        (pattern) =>
          pattern === requested ||
          pattern === "<all_urls>" ||
          pattern === "*://*/*" ||
          matchesUrlPattern(pattern, requested.replace(/\*\./g, "a.").replace(/\*/g, "a")),
      );
    const requestedPermissions = (value: unknown) => {
      const details = asDict(value);
      return {
        permissions: Array.isArray(details.permissions) ? details.permissions.map(String) : [],
        origins: Array.isArray(details.origins) ? details.origins.map(String) : [],
      };
    };

    return {
      // The preload calls this once so a page receives events before its first API call.
      "context.ready": noop,

      "windows.get": (context, state, [windowId, info]) =>
        this.#windowInfo(
          state,
          this.#windowById(context, state, windowId),
          asDict(info).populate === true,
        ),
      "windows.getCurrent": (context, state, [info]) =>
        this.#windowInfo(
          state,
          this.#windowById(context, state, WINDOW_ID_CURRENT),
          asDict(info).populate === true,
        ),
      "windows.getLastFocused": (_context, state, [info]) => {
        const window = BrowserWindow.fromId(this.#lastFocusedWindow(state));
        if (!window) throw new Error("No last-focused window.");
        return this.#windowInfo(state, window, asDict(info).populate === true);
      },
      "windows.getAll": (_context, state, [info]) => {
        const options = asDict(info);
        const types = Array.isArray(options.windowTypes) ? options.windowTypes : undefined;
        return this.#windowsOf(state)
          .map((window) => this.#windowInfo(state, window, options.populate === true))
          .filter((window) => !types || types.includes(window.type));
      },
      "windows.create": (context, state, [createData]) => {
        const data = asDict(createData);
        const url = Array.isArray(data.url) ? data.url[0] : data.url;
        const window = this.#openWindow(context, state, url, {
          type: data.type === "popup" || data.type === "panel" ? "popup" : "normal",
          width: optionalNumber(data.width),
          height: optionalNumber(data.height),
          left: optionalNumber(data.left),
          top: optionalNumber(data.top),
          focused: typeof data.focused === "boolean" ? data.focused : undefined,
        });
        return this.#windowInfo(state, window, true);
      },
      "windows.update": (context, state, [windowId, updateInfo]) => {
        const window = this.#windowById(context, state, windowId);
        const info = asDict(updateInfo);
        if (info.state === "minimized") window.minimize();
        else if (info.state === "maximized") window.maximize();
        else if (info.state === "fullscreen") window.setFullScreen(true);
        else if (info.state === "normal") {
          if (window.isFullScreen()) window.setFullScreen(false);
          if (window.isMinimized() || window.isMaximized()) window.restore();
        }
        const bounds = window.getBounds();
        if (
          ["left", "top", "width", "height"].some((key) => optionalNumber(info[key]) !== undefined)
        ) {
          window.setBounds({
            x: optionalNumber(info.left) ?? bounds.x,
            y: optionalNumber(info.top) ?? bounds.y,
            width: optionalNumber(info.width) ?? bounds.width,
            height: optionalNumber(info.height) ?? bounds.height,
          });
        }
        if (info.focused === true) window.focus();
        if (info.drawAttention === true) window.flashFrame(true);
        return this.#windowInfo(state, window, false);
      },
      "windows.remove": (context, state, [windowId]) => {
        const window = this.#windowById(context, state, windowId);
        // The app's own windows are not the extension's to close.
        if (!this.#extensionWindows.has(window.id))
          throw new Error("This window cannot be closed.");
        window.close();
      },

      "tabs.query": (context, state, [queryInfo]) => {
        const query = asDict(queryInfo);
        const current = this.#currentWindow(context, state);
        const lastFocused = this.#lastFocusedWindow(state);
        const urls =
          query.url === undefined
            ? undefined
            : (Array.isArray(query.url) ? query.url : [query.url]).map(String);
        const titlePattern =
          typeof query.title === "string" ? globToRegExp(query.title) : undefined;
        const windowId = query.windowId === WINDOW_ID_CURRENT ? current : query.windowId;
        return this.#tabsOf(state)
          .map((tab) => this.#tabInfo(state, tab))
          .filter(
            (tab) =>
              (query.active === undefined || tab.active === query.active) &&
              (query.highlighted === undefined || tab.highlighted === query.highlighted) &&
              (query.currentWindow === undefined ||
                (tab.windowId === current) === query.currentWindow) &&
              (query.lastFocusedWindow === undefined ||
                (tab.windowId === lastFocused) === query.lastFocusedWindow) &&
              (windowId === undefined || tab.windowId === windowId) &&
              (query.status === undefined || tab.status === query.status) &&
              (query.audible === undefined || tab.audible === query.audible) &&
              (query.pinned === undefined || tab.pinned === query.pinned) &&
              (query.discarded === undefined || query.discarded === false) &&
              (query.index === undefined || tab.index === query.index) &&
              (query.windowType === undefined ||
                (this.#extensionWindows.get(tab.windowId as number)?.type ?? "normal") ===
                  query.windowType) &&
              (titlePattern === undefined || titlePattern.test(String(tab.title))) &&
              (urls === undefined ||
                urls.some((pattern) => matchesUrlPattern(pattern, String(tab.url)))),
          );
      },
      "tabs.get": (_context, state, [tabId]) => this.#tabInfo(state, this.#tabById(state, tabId)),
      "tabs.getCurrent": (context, state) => {
        const window = context.windowId();
        if (window === undefined || !this.#extensionWindows.has(window)) return undefined;
        const tab = this.#activeTabIn(state, window);
        return tab ? this.#tabInfo(state, tab) : undefined;
      },
      "tabs.create": (context, state, [createProperties]) => {
        const properties = asDict(createProperties);
        const window = this.#openWindow(context, state, properties.url, {
          type: "normal",
          focused: properties.active !== false,
        });
        return this.#tabInfo(state, window.webContents);
      },
      "tabs.duplicate": (context, state, [tabId]) => {
        const tab = this.#tabById(state, tabId);
        const window = this.#openWindow(context, state, tab.getURL(), { type: "normal" });
        return this.#tabInfo(state, window.webContents);
      },
      "tabs.remove": (_context, state, [tabIds]) => {
        for (const tabId of Array.isArray(tabIds) ? tabIds : [tabIds]) {
          const tab = this.#tabById(state, tabId);
          // Preview tabs belong to the app; extension windows and page popups can close.
          if (tab.getType() === "webview") continue;
          BrowserWindow.fromWebContents(tab)?.close();
        }
      },
      "tabs.highlight": (context, state, [highlightInfo]) =>
        this.#windowInfo(
          state,
          this.#windowById(context, state, asDict(highlightInfo).windowId),
          true,
        ),
      "tabs.captureVisibleTab": async (context, state, [windowId, options]) => {
        const id =
          typeof windowId === "number" && windowId !== WINDOW_ID_CURRENT
            ? windowId
            : this.#currentWindow(context, state);
        const tab = this.#activeTabIn(state, id);
        if (!tab) throw new Error("No visible tab to capture.");
        const image = await tab.capturePage();
        const format = asDict(options).format;
        if (format === "jpeg") {
          const quality = optionalNumber(asDict(options).quality) ?? 92;
          return `data:image/jpeg;base64,${image.toJPEG(quality).toString("base64")}`;
        }
        return image.toDataURL();
      },
      "tabs.goBack": (context, state, [tabId]) => {
        const tab =
          typeof tabId === "number"
            ? this.#tabById(state, tabId)
            : this.#activeTabIn(state, this.#currentWindow(context, state));
        tab?.navigationHistory.goBack();
      },
      "tabs.goForward": (context, state, [tabId]) => {
        const tab =
          typeof tabId === "number"
            ? this.#tabById(state, tabId)
            : this.#activeTabIn(state, this.#currentWindow(context, state));
        tab?.navigationHistory.goForward();
      },
      "tabs.discard": (context, state, [tabId]) => {
        const tab =
          typeof tabId === "number"
            ? this.#tabById(state, tabId)
            : this.#activeTabIn(state, this.#currentWindow(context, state));
        return tab ? this.#tabInfo(state, tab) : undefined;
      },

      "webNavigation.getAllFrames": (_context, state, [details]) =>
        frames(this.#tabById(state, asDict(details).tabId)),
      "webNavigation.getFrame": (_context, state, [details]) => {
        const query = asDict(details);
        return (
          frames(this.#tabById(state, query.tabId)).find(
            (frame) => frame.frameId === query.frameId,
          ) ?? null
        );
      },

      // Menu items are kept so the extension's bookkeeping works; the preview's
      // context menu does not show them yet.
      "contextMenus.create": (context, state, [properties]) => {
        const item = asDict(properties);
        menusOf(context, state).set(item.id as string | number, item);
      },
      "contextMenus.update": (context, state, [id, properties]) => {
        const menus = menusOf(context, state);
        const key = id as string | number;
        menus.set(key, { ...menus.get(key), ...asDict(properties) });
      },
      "contextMenus.remove": (context, state, [id]) => {
        menusOf(context, state).delete(id as string | number);
      },
      "contextMenus.removeAll": (context, state) => {
        menusOf(context, state).clear();
      },

      "permissions.getAll": async (context, state) => {
        const sets = await permissionSets(context, state);
        return { permissions: [...sets.permissions], origins: sets.origins };
      },
      "permissions.contains": async (context, state, [value]) => {
        const sets = await permissionSets(context, state);
        const requested = requestedPermissions(value);
        return (
          requested.permissions.every((permission) => sets.permissions.has(permission)) &&
          requested.origins.every((origin) => coversOrigin(sets.origins, origin))
        );
      },
      // Chrome asks the user; an extension can only request what its manifest lists.
      "permissions.request": async (context, state, [value]) => {
        const sets = await permissionSets(context, state);
        const requested = requestedPermissions(value);
        const allowed = [...requested.permissions, ...requested.origins].every(
          (entry) =>
            sets.permissions.has(entry) ||
            sets.optional.has(entry) ||
            coversOrigin(sets.origins, entry) ||
            coversOrigin([...sets.optional], entry),
        );
        if (!allowed) return false;
        let granted = state.grantedPermissions.get(context.extensionId);
        if (!granted) {
          granted = new Set();
          state.grantedPermissions.set(context.extensionId, granted);
        }
        for (const entry of [...requested.permissions, ...requested.origins]) granted.add(entry);
        this.#emit(context.session, "permissions.onAdded", [requested], context.extensionId);
        return true;
      },
      "permissions.remove": (context, state, [value]) => {
        const requested = requestedPermissions(value);
        const granted = state.grantedPermissions.get(context.extensionId);
        for (const entry of [...requested.permissions, ...requested.origins])
          granted?.delete(entry);
        this.#emit(context.session, "permissions.onRemoved", [requested], context.extensionId);
        return true;
      },

      "notifications.create": async (context, _state, [notificationId, options]) => {
        const extension = await this.#installedById(context.extensionId);
        const details = asDict(options);
        const id = String(notificationId);
        const key = `${context.extensionId}:${id}`;
        this.#notifications.get(key)?.close();
        if (!Notification.isSupported()) return id;
        const icon = extension ? this.#extensionImage(extension, details.iconUrl) : undefined;
        const notification = new Notification({
          title: String(details.title ?? extension?.name ?? ""),
          body: String(details.message ?? ""),
          silent: details.silent === true,
          ...(icon ? { icon } : {}),
        });
        this.#notifications.set(key, notification);
        notification.on("click", () =>
          this.#emit(context.session, "notifications.onClicked", [id], context.extensionId),
        );
        notification.on("close", () => {
          if (this.#notifications.get(key) === notification) this.#notifications.delete(key);
          this.#emit(context.session, "notifications.onClosed", [id, true], context.extensionId);
        });
        notification.show();
        return id;
      },
      "notifications.update": (context, _state, [notificationId]) =>
        this.#notifications.has(`${context.extensionId}:${String(notificationId)}`),
      "notifications.clear": (context, _state, [notificationId]) => {
        const key = `${context.extensionId}:${String(notificationId)}`;
        const notification = this.#notifications.get(key);
        notification?.close();
        return notification !== undefined;
      },
      "notifications.getAll": (context) =>
        Object.fromEntries(
          [...this.#notifications.keys()]
            .filter((key) => key.startsWith(`${context.extensionId}:`))
            .map((key) => [key.slice(context.extensionId.length + 1), true]),
        ),
      "notifications.getPermissionLevel": () => "granted",

      "downloads.download": (context, _state, [options]) => {
        const url = asDict(options).url;
        if (typeof url !== "string") throw new Error("A download needs a URL.");
        context.session.downloadURL(url);
        return this.#nextDownloadId++;
      },
      "downloads.search": () => [],
      "downloads.pause": noop,
      "downloads.resume": noop,
      "downloads.cancel": noop,
      "downloads.erase": () => [],
      "downloads.open": noop,
      "downloads.show": noop,
      "downloads.showDefaultFolder": noop,
      "downloads.removeFile": noop,
      "downloads.acceptDanger": noop,
      "downloads.setUiOptions": noop,

      "cookies.get": async (context, _state, [details]) => {
        await requirePermission(context, "cookies");
        const filter = cookieFilter(asDict(details));
        const cookies = await context.session.cookies.get(filter);
        const best = cookies.toSorted((a, b) => (b.path?.length ?? 0) - (a.path?.length ?? 0))[0];
        return best ? toChromeCookie(best) : null;
      },
      "cookies.getAll": async (context, _state, [details]) => {
        await requirePermission(context, "cookies");
        return (await context.session.cookies.get(cookieFilter(asDict(details)))).map(
          toChromeCookie,
        );
      },
      "cookies.set": async (context, _state, [details]) => {
        await requirePermission(context, "cookies");
        const cookie = asDict(details);
        if (typeof cookie.url !== "string") throw new Error("A cookie needs a URL.");
        await context.session.cookies.set({
          url: cookie.url,
          ...(typeof cookie.name === "string" ? { name: cookie.name } : {}),
          ...(typeof cookie.value === "string" ? { value: cookie.value } : {}),
          ...(typeof cookie.domain === "string" ? { domain: cookie.domain } : {}),
          ...(typeof cookie.path === "string" ? { path: cookie.path } : {}),
          ...(typeof cookie.secure === "boolean" ? { secure: cookie.secure } : {}),
          ...(typeof cookie.httpOnly === "boolean" ? { httpOnly: cookie.httpOnly } : {}),
          ...(typeof cookie.expirationDate === "number"
            ? { expirationDate: cookie.expirationDate }
            : {}),
          ...(cookie.sameSite === "no_restriction" ||
          cookie.sameSite === "lax" ||
          cookie.sameSite === "strict" ||
          cookie.sameSite === "unspecified"
            ? { sameSite: cookie.sameSite }
            : {}),
        });
        const [written] = await context.session.cookies.get({
          url: cookie.url,
          ...(typeof cookie.name === "string" ? { name: cookie.name } : {}),
        });
        return written ? toChromeCookie(written) : null;
      },
      "cookies.remove": async (context, _state, [details]) => {
        await requirePermission(context, "cookies");
        const cookie = asDict(details);
        await context.session.cookies.remove(String(cookie.url), String(cookie.name));
        return { url: cookie.url, name: cookie.name, storeId: "0" };
      },
      "cookies.getAllCookieStores": (_context, state) => [
        { id: "0", tabIds: this.#tabsOf(state).map((tab) => tab.id) },
      ],
      "cookies.getPartitionKey": () => ({ partitionKey: {} }),

      "action.setTitle": setAction((target, details) => {
        target.title = typeof details.title === "string" ? details.title : undefined;
      }),
      "action.getTitle": readAction((action) => action.title),
      "action.setBadgeText": setAction((target, details) => {
        target.badgeText = typeof details.text === "string" ? details.text : undefined;
      }),
      "action.getBadgeText": readAction((action) => action.badgeText),
      "action.setBadgeBackgroundColor": setAction((target, details) => {
        target.badgeBackgroundColor = toCssColor(details.color);
        target.badgeBackgroundColorArray = Array.isArray(details.color)
          ? details.color.map(Number)
          : undefined;
      }),
      "action.getBadgeBackgroundColor": readAction(
        (action) => action.badgeBackgroundColorArray ?? [0, 0, 0, 0],
      ),
      "action.setBadgeTextColor": setAction((target, details) => {
        target.badgeTextColor = toCssColor(details.color);
      }),
      "action.getBadgeTextColor": readAction(() => [255, 255, 255, 255]),
      "action.setPopup": setAction((target, details) => {
        target.popup = typeof details.popup === "string" ? details.popup : undefined;
      }),
      "action.getPopup": readAction((action) =>
        action.popup === "" ? "" : new URL(action.popup, "chrome-extension://x/").pathname,
      ),
      "action.setIcon": setAction(async (target, details, context) => {
        const imageData = pickSized<Dict>(details.imageData, (value) => "data" in asDict(value));
        if (imageData) {
          target.iconDataUrl = imageDataToDataUrl(imageData);
          return;
        }
        const path = pickSized<string>(details.path, (value) => typeof value === "string");
        const extension = await this.#installedById(context.extensionId);
        target.iconDataUrl =
          path && extension ? await readIconDataUrl(extension.directory, path, ICON_SIZE) : null;
      }),
      "action.enable": setEnabled(true),
      "action.disable": setEnabled(false),
      "action.isEnabled": readAction((action) => action.enabled),
      "action.getUserSettings": () => ({ isOnToolbar: true }),
      // Opening a popup needs the toolbar button's position, which only a click supplies.
      "action.openPopup": noop,

      "runtime.connectNative": async (context, _state, [application]) => {
        await requirePermission(context, "nativeMessaging");
        return this.#ports.connect(context.extensionId, String(application), context.key, {
          onMessage: (portId, message) => context.send("nativePort.message", [portId, message]),
          onDisconnect: (portId, error) => context.send("nativePort.disconnect", [portId, error]),
        });
      },
      "runtime.nativePortPost": (context, _state, [portId, message]) =>
        this.#ports.post(Number(portId), message, context.key),
      "runtime.nativePortClose": (context, _state, [portId]) =>
        this.#ports.close(Number(portId), context.key),
      "runtime.sendNativeMessage": async (context, _state, [application, message]) => {
        await requirePermission(context, "nativeMessaging");
        return this.#ports.sendOnce(context.extensionId, String(application), message);
      },
      "runtime.openOptionsPage": async (context, state) => {
        const extension = await this.#installedById(context.extensionId);
        const page = extension?.manifest.options_ui?.page ?? extension?.manifest.options_page;
        if (!page) throw new Error("This extension has no options page.");
        this.#openWindow(context, state, page, { type: "normal" });
      },
    };
  }

  #extensionImage(extension: InstalledExtension, url: unknown): Electron.NativeImage | undefined {
    if (typeof url !== "string" || url === "") return undefined;
    if (url.startsWith("data:")) return nativeImage.createFromDataURL(url);
    let path = url;
    try {
      const parsed = new URL(url, `chrome-extension://${extension.id}/`);
      if (parsed.protocol !== "chrome-extension:" || parsed.host !== extension.id) return undefined;
      path = decodeURIComponent(parsed.pathname);
    } catch {
      return undefined;
    }
    const file = resolveInside(extension.directory, path);
    return file ? nativeImage.createFromPath(file) : undefined;
  }
}
