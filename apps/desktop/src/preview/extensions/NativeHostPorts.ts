// @effect-diagnostics nodeBuiltinImport:off -- Native messaging hosts are child processes driven by extension IPC, outside any Effect runtime.
import * as NodeChildProcess from "node:child_process";
import * as NodeFSP from "node:fs/promises";
import * as NodePath from "node:path";

import {
  NativeMessageDecoder,
  encodeNativeMessage,
  isValidNativeHostName,
  nativeHostAllows,
  nativeHostManifestDirectories,
  type NativeHostManifest,
} from "./nativeMessaging.ts";

/** Where a port's messages and disconnect go: the extension context that opened it. */
export interface NativePortOwner {
  readonly onMessage: (portId: number, message: unknown) => void;
  readonly onDisconnect: (portId: number, error: string | undefined) => void;
}

interface OpenPort {
  readonly child: NodeChildProcess.ChildProcess;
  readonly owner: NativePortOwner;
  readonly ownerKey: string;
}

/**
 * Chrome's native messaging: starts the host a manifest names, with the
 * extension's origin as its argument, and frames JSON over its stdio. Desktop
 * companions such as the 1Password app talk to their extension this way.
 */
export class NativeHostPorts {
  readonly #platform: NodeJS.Platform;
  readonly #home: string;
  readonly #ports = new Map<number, OpenPort>();
  #nextId = 1;

  constructor(options: { readonly platform: NodeJS.Platform; readonly home: string }) {
    this.#platform = options.platform;
    this.#home = options.home;
  }

  async #findHost(extensionId: string, name: string): Promise<NativeHostManifest> {
    if (!isValidNativeHostName(name)) {
      throw new Error("Invalid native messaging host name specified.");
    }
    let forbidden = false;
    for (const directory of nativeHostManifestDirectories(this.#platform, this.#home)) {
      let manifest: NativeHostManifest;
      try {
        manifest = JSON.parse(
          await NodeFSP.readFile(NodePath.join(directory, `${name}.json`), "utf8"),
        ) as NativeHostManifest;
      } catch {
        continue;
      }
      if (!nativeHostAllows(manifest, extensionId, name)) {
        forbidden = true;
        continue;
      }
      return NodePath.isAbsolute(manifest.path)
        ? manifest
        : { ...manifest, path: NodePath.resolve(directory, manifest.path) };
    }
    throw new Error(
      forbidden
        ? "Access to the specified native messaging host is forbidden."
        : "Specified native messaging host not found.",
    );
  }

  /** Starts the host and returns the port id. `ownerKey` groups ports for {@link closeOwnedBy}. */
  async connect(
    extensionId: string,
    name: string,
    ownerKey: string,
    owner: NativePortOwner,
  ): Promise<number> {
    const manifest = await this.#findHost(extensionId, name);
    const child = NodeChildProcess.spawn(manifest.path, [`chrome-extension://${extensionId}/`], {
      cwd: NodePath.dirname(manifest.path),
      stdio: ["pipe", "pipe", "ignore"],
      windowsHide: true,
    });
    const id = this.#nextId++;
    this.#ports.set(id, { child, owner, ownerKey });
    const decoder = new NativeMessageDecoder();
    child.stdout?.on("data", (chunk: Buffer) => {
      let messages: ReadonlyArray<unknown>;
      try {
        messages = decoder.push(chunk);
      } catch (error) {
        this.#close(id, (error as Error).message);
        return;
      }
      for (const message of messages) owner.onMessage(id, message);
    });
    child.stdin?.on("error", () =>
      this.#close(id, "Error when communicating with the native messaging host."),
    );
    child.once("error", () => this.#close(id, "Specified native messaging host not found."));
    child.once("exit", () => this.#close(id, "Native host has exited."));
    return id;
  }

  post(id: number, message: unknown, ownerKey: string): void {
    const port = this.#ports.get(id);
    if (!port || port.ownerKey !== ownerKey) {
      throw new Error("Attempting to use a disconnected port object");
    }
    port.child.stdin?.write(encodeNativeMessage(message));
  }

  /** Closed by the extension: no disconnect event goes back to it. */
  close(id: number, ownerKey: string): void {
    if (this.#ports.get(id)?.ownerKey === ownerKey) this.#close(id, undefined, false);
  }

  /** One request, one response, as `runtime.sendNativeMessage`. */
  async sendOnce(extensionId: string, name: string, message: unknown): Promise<unknown> {
    const ownerKey = `once:${extensionId}:${this.#nextId}`;
    return new Promise<unknown>((resolve, reject) => {
      void this.connect(extensionId, name, ownerKey, {
        onMessage: (portId, value) => {
          resolve(value);
          this.close(portId, ownerKey);
        },
        onDisconnect: (_portId, error) => reject(new Error(error ?? "Native host has exited.")),
      }).then((id) => this.post(id, message, ownerKey), reject);
    });
  }

  /** Ends every port an extension context opened, when that context goes away. */
  closeOwnedBy(ownerKey: string): void {
    for (const [id, port] of this.#ports) {
      if (port.ownerKey === ownerKey) this.#close(id, undefined, false);
    }
  }

  dispose(): void {
    for (const id of this.#ports.keys()) this.#close(id, undefined, false);
  }

  #close(id: number, error: string | undefined, notify = true): void {
    const port = this.#ports.get(id);
    if (!port) return;
    this.#ports.delete(id);
    port.child.stdin?.end();
    if (port.child.exitCode === null) port.child.kill();
    if (notify) port.owner.onDisconnect(id, error);
  }
}
