// @effect-diagnostics nodeBuiltinImport:off -- Extension files are copied and read by the imperative extension host, outside any Effect runtime.
// @effect-diagnostics globalDate:off -- Staging directory names only need to be unique.
import * as NodeFSP from "node:fs/promises";
import * as NodePath from "node:path";

import type { PreviewExtensionSource } from "@t3tools/contracts";
import { unzipSync } from "fflate";

import {
  type ExtensionManifest,
  type ExtensionMessages,
  isBrowserExtension,
  localizeManifestString,
  pickIconPath,
} from "./manifest.ts";

export interface InstalledExtension {
  readonly id: string;
  readonly name: string;
  readonly version: string;
  readonly description: string;
  readonly enabled: boolean;
  readonly source: PreviewExtensionSource;
  readonly directory: string;
  readonly manifest: ExtensionManifest;
  readonly messages: ExtensionMessages;
}

interface RegistryEntry {
  readonly id: string;
  readonly version: string;
  readonly enabled: boolean;
  readonly source: PreviewExtensionSource;
}

interface Registry {
  readonly extensions: ReadonlyArray<RegistryEntry>;
}

export interface ExtensionDescription {
  readonly manifest: ExtensionManifest;
  readonly messages: ExtensionMessages;
  readonly name: string;
  readonly version: string;
  readonly description: string;
}

const readJson = async <T>(path: string): Promise<T | undefined> => {
  try {
    return JSON.parse(await NodeFSP.readFile(path, "utf8")) as T;
  } catch {
    return undefined;
  }
};

async function readManifest(directory: string): Promise<ExtensionManifest> {
  const manifest = await readJson<ExtensionManifest>(NodePath.join(directory, "manifest.json"));
  if (!manifest || typeof manifest !== "object") {
    throw new Error(`No readable manifest.json in ${directory}.`);
  }
  return manifest;
}

async function readMessages(
  directory: string,
  manifest: ExtensionManifest,
): Promise<ExtensionMessages> {
  for (const locale of [manifest.default_locale, "en", "en_US"]) {
    if (!locale) continue;
    const messages = await readJson<ExtensionMessages>(
      NodePath.join(directory, "_locales", locale, "messages.json"),
    );
    if (messages) return messages;
  }
  return {};
}

async function describeExtension(directory: string): Promise<ExtensionDescription> {
  const manifest = await readManifest(directory);
  const messages = await readMessages(directory, manifest);
  const localize = (value: string | undefined) =>
    value === undefined ? undefined : localizeManifestString(value, messages).trim();
  return {
    manifest,
    messages,
    name: localize(manifest.name) || localize(manifest.short_name) || NodePath.basename(directory),
    version: manifest.version?.trim() || "0",
    description: localize(manifest.description) ?? "",
  };
}

/** A data URL for one of the extension's icon files, or null. */
export async function readIconDataUrl(
  directory: string,
  icons: Parameters<typeof pickIconPath>[0],
  size: number,
): Promise<string | null> {
  const relative = pickIconPath(icons, size);
  if (!relative) return null;
  const path = resolveInside(directory, relative);
  if (!path) return null;
  try {
    const bytes = await NodeFSP.readFile(path);
    const mime = path.endsWith(".svg")
      ? "image/svg+xml"
      : path.endsWith(".jpg") || path.endsWith(".jpeg")
        ? "image/jpeg"
        : "image/png";
    return `data:${mime};base64,${bytes.toString("base64")}`;
  } catch {
    return null;
  }
}

/** Resolves a path an extension declares, refusing anything that leaves its directory. */
export function resolveInside(directory: string, relative: string): string | null {
  const resolved = NodePath.resolve(directory, relative.replace(/^\/+/, ""));
  const root = NodePath.resolve(directory);
  return resolved === root || resolved.startsWith(`${root}${NodePath.sep}`) ? resolved : null;
}

const compareVersions = (left: string, right: string) => {
  const a = left.split(/[._]/).map((part) => Number.parseInt(part, 10) || 0);
  const b = right.split(/[._]/).map((part) => Number.parseInt(part, 10) || 0);
  for (let index = 0; index < Math.max(a.length, b.length); index++) {
    const difference = (a[index] ?? 0) - (b[index] ?? 0);
    if (difference !== 0) return difference;
  }
  return 0;
};

/**
 * Extensions installed in a Chromium profile: `Extensions/<id>/<version>`,
 * newest version only.
 */
export async function listProfileExtensions(profileDirectory: string): Promise<
  ReadonlyArray<{
    readonly id: string;
    readonly directory: string;
    readonly description: ExtensionDescription;
  }>
> {
  const root = NodePath.join(profileDirectory, "Extensions");
  let ids: Array<string>;
  try {
    ids = (await NodeFSP.readdir(root)).filter((name) => /^[a-p]{32}$/.test(name));
  } catch {
    return [];
  }
  const found = await Promise.all(
    ids.map(async (id) => {
      try {
        const versions = (await NodeFSP.readdir(NodePath.join(root, id))).filter(
          (name) => !name.startsWith("."),
        );
        const latest = versions.toSorted(compareVersions).at(-1);
        if (!latest) return undefined;
        const directory = NodePath.join(root, id, latest);
        const description = await describeExtension(directory);
        return isBrowserExtension(description.manifest)
          ? { id, directory, description }
          : undefined;
      } catch {
        return undefined;
      }
    }),
  );
  return found.filter((entry) => entry !== undefined);
}

/** Copies of installed extensions under `<root>/<id>/<version>`, plus a registry. */
export class ExtensionStore {
  readonly #root: string;
  #writes: Promise<unknown> = Promise.resolve();

  constructor(root: string) {
    this.#root = root;
  }

  get #registryPath() {
    return NodePath.join(this.#root, "registry.json");
  }

  async #readRegistry(): Promise<Registry> {
    return (await readJson<Registry>(this.#registryPath)) ?? { extensions: [] };
  }

  /** Serializes registry updates so concurrent installs cannot drop each other's entries. */
  #update<T>(
    change: (registry: Registry) => Promise<{ readonly registry: Registry; readonly result: T }>,
  ): Promise<T> {
    const next = this.#writes.then(async () => {
      const { registry, result } = await change(await this.#readRegistry());
      await NodeFSP.mkdir(this.#root, { recursive: true });
      const temporary = `${this.#registryPath}.tmp`;
      await NodeFSP.writeFile(temporary, `${JSON.stringify(registry, null, 2)}\n`);
      await NodeFSP.rename(temporary, this.#registryPath);
      return result;
    });
    this.#writes = next.catch(() => undefined);
    return next;
  }

  async list(): Promise<ReadonlyArray<InstalledExtension>> {
    const registry = await this.#readRegistry();
    const installed = await Promise.all(
      registry.extensions.map(async (entry) => {
        const directory = NodePath.join(this.#root, entry.id, entry.version);
        try {
          const description = await describeExtension(directory);
          return { ...entry, ...description, directory } satisfies InstalledExtension;
        } catch {
          return undefined;
        }
      }),
    );
    return installed.filter((entry) => entry !== undefined);
  }

  /** Copies an unpacked extension in, replacing any other version of it. */
  installDirectory(input: {
    readonly id: string;
    readonly sourceDirectory: string;
    readonly source: PreviewExtensionSource;
  }): Promise<InstalledExtension> {
    return this.#install(input.id, input.source, async (target) => {
      await NodeFSP.cp(input.sourceDirectory, target, { recursive: true, dereference: true });
    });
  }

  /** Unpacks a ZIP archive (a Web Store package body) in. */
  installArchive(input: {
    readonly id: string;
    readonly archive: Uint8Array;
    readonly manifestKey: string | undefined;
    readonly source: PreviewExtensionSource;
  }): Promise<InstalledExtension> {
    return this.#install(input.id, input.source, async (target) => {
      const files = unzipSync(input.archive);
      for (const [name, bytes] of Object.entries(files)) {
        if (name.endsWith("/")) continue;
        const path = resolveInside(target, name);
        if (!path || path === target)
          throw new Error(`Archive entry ${name} escapes the extension.`);
        await NodeFSP.mkdir(NodePath.dirname(path), { recursive: true });
        await NodeFSP.writeFile(path, bytes);
      }
      if (input.manifestKey) {
        const manifestPath = NodePath.join(target, "manifest.json");
        const manifest = JSON.parse(await NodeFSP.readFile(manifestPath, "utf8")) as Record<
          string,
          unknown
        >;
        if (manifest.key === undefined) {
          manifest.key = input.manifestKey;
          await NodeFSP.writeFile(manifestPath, JSON.stringify(manifest, null, 2));
        }
      }
    });
  }

  #install(
    id: string,
    source: PreviewExtensionSource,
    populate: (directory: string) => Promise<void>,
  ): Promise<InstalledExtension> {
    return this.#update(async (registry) => {
      const extensionRoot = NodePath.join(this.#root, id);
      const staging = NodePath.join(extensionRoot, `.staging-${Date.now()}`);
      await NodeFSP.rm(staging, { recursive: true, force: true });
      await NodeFSP.mkdir(staging, { recursive: true });
      try {
        await populate(staging);
        const description = await describeExtension(staging);
        if (!isBrowserExtension(description.manifest)) {
          throw new Error(`${description.name} is a theme or app, not an extension.`);
        }
        const directory = NodePath.join(extensionRoot, description.version);
        await NodeFSP.rm(directory, { recursive: true, force: true });
        await NodeFSP.rename(staging, directory);
        for (const entry of await NodeFSP.readdir(extensionRoot)) {
          if (entry !== description.version) {
            await NodeFSP.rm(NodePath.join(extensionRoot, entry), { recursive: true, force: true });
          }
        }
        const previous = registry.extensions.find((entry) => entry.id === id);
        const entry: RegistryEntry = {
          id,
          version: description.version,
          enabled: previous?.enabled ?? true,
          source,
        };
        return {
          registry: {
            extensions: [...registry.extensions.filter((candidate) => candidate.id !== id), entry],
          },
          result: { ...entry, ...description, directory } satisfies InstalledExtension,
        };
      } catch (error) {
        await NodeFSP.rm(staging, { recursive: true, force: true });
        throw error;
      }
    });
  }

  setEnabled(id: string, enabled: boolean): Promise<void> {
    return this.#update(async (registry) => ({
      registry: {
        extensions: registry.extensions.map((entry) =>
          entry.id === id ? { ...entry, enabled } : entry,
        ),
      },
      result: undefined,
    }));
  }

  remove(id: string): Promise<void> {
    return this.#update(async (registry) => {
      await NodeFSP.rm(NodePath.join(this.#root, id), { recursive: true, force: true });
      return {
        registry: { extensions: registry.extensions.filter((entry) => entry.id !== id) },
        result: undefined,
      };
    });
  }
}
