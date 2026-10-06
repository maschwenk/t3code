/**
 * Chrome extensions in the preview browser: the Effect face of
 * {@link ExtensionHost}, for IPC handlers and the preview session setup.
 *
 * @module PreviewExtensions
 */
import {
  type PreviewExtension,
  type PreviewExtensionAnchor,
  type PreviewExtensionCandidateProfile,
  type PreviewExtensionSource,
  parseWebStoreExtensionId,
} from "@t3tools/contracts";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import * as Scope from "effect/Scope";
import type { Session } from "electron";

import * as DesktopEnvironment from "../../app/DesktopEnvironment.ts";
import {
  BROWSER_IMPORT_SOURCES,
  listSourceProfiles,
  sourcePathContext,
} from "../BrowserImport/Sources.ts";
import { ExtensionHost } from "./ExtensionHost.ts";
import { ExtensionStore, listProfileExtensions } from "./ExtensionStore.ts";

export class PreviewExtensionError extends Schema.TaggedError<PreviewExtensionError>()(
  "PreviewExtensionError",
  {
    operation: Schema.String,
    cause: Schema.Defect(),
  },
) {
  // IPC flattens errors to their message, so it is the text the user sees.
  override get message(): string {
    return this.cause instanceof Error ? this.cause.message : String(this.cause);
  }
}

export class PreviewExtensions extends Context.Service<
  PreviewExtensions,
  {
    /** Loads extensions into a preview session before its first page. Never fails. */
    readonly attachSession: (session: Session) => Effect.Effect<void>;
    readonly list: (
      tabWebContentsId?: number,
    ) => Effect.Effect<ReadonlyArray<PreviewExtension>, PreviewExtensionError>;
    readonly openPopup: (input: {
      readonly extensionId: string;
      readonly tabWebContentsId: number;
      readonly anchor: PreviewExtensionAnchor;
      readonly ownerWebContentsId: number;
    }) => Effect.Effect<void, PreviewExtensionError>;
    readonly listBrowserCandidates: Effect.Effect<ReadonlyArray<PreviewExtensionCandidateProfile>>;
    readonly importFromBrowser: (input: {
      readonly sourceId: string;
      readonly profileDirectory: string;
      readonly extensionIds: ReadonlyArray<string>;
    }) => Effect.Effect<ReadonlyArray<PreviewExtension>, PreviewExtensionError>;
    readonly installFromWebStore: (
      reference: string,
    ) => Effect.Effect<PreviewExtension, PreviewExtensionError>;
    readonly setEnabled: (
      extensionId: string,
      enabled: boolean,
    ) => Effect.Effect<void, PreviewExtensionError>;
    readonly remove: (extensionId: string) => Effect.Effect<void, PreviewExtensionError>;
    readonly subscribeChanges: (listener: () => void) => Effect.Effect<void, never, Scope.Scope>;
  }
>()("@t3tools/desktop/preview/extensions/PreviewExtensions") {}

/** How long a new preview tab waits for its profile's extensions before loading anyway. */
const ATTACH_TIMEOUT = "4 seconds";

/** @public Service construction is part of the canonical Effect module API. */
export const make = Effect.gen(function* PreviewExtensionsMake() {
  const environment = yield* DesktopEnvironment.DesktopEnvironment;
  const fileSystem = yield* FileSystem.FileSystem;
  const pathContext = yield* sourcePathContext;
  const listeners = new Set<() => void>();
  const runFork = Effect.runForkWith(yield* Effect.context<never>());

  const host = yield* Effect.acquireRelease(
    Effect.sync(
      () =>
        new ExtensionHost({
          store: new ExtensionStore(
            environment.path.join(environment.stateDir, "browser-extensions"),
          ),
          preloadPath: environment.path.join(environment.dirname, "preview-extension-preload.cjs"),
          platform: environment.platform,
          homeDirectory: environment.homeDirectory,
          chromeVersion: process.versions.chrome ?? "140.0.0.0",
          onChange: () => {
            for (const listener of listeners) listener();
          },
          log: (message, details) => {
            runFork(Effect.logWarning(message, details ?? {}));
          },
        }),
    ),
    (host) => Effect.sync(() => host.dispose()),
  );

  const attempt = <A>(operation: string, evaluate: () => Promise<A>) =>
    Effect.tryPromise({
      try: evaluate,
      catch: (cause) => new PreviewExtensionError({ operation, cause }),
    });

  const listOne = (id: string) =>
    attempt("list", () => host.list()).pipe(
      Effect.flatMap((extensions) => {
        const found = extensions.find((extension) => extension.id === id);
        return found
          ? Effect.succeed(found)
          : Effect.fail(
              new PreviewExtensionError({
                operation: "list",
                cause: new Error("The extension did not install."),
              }),
            );
      }),
    );

  const listBrowserCandidates = Effect.gen(function* () {
    const installed = yield* attempt("list", () => host.list()).pipe(
      Effect.orElseSucceed((): ReadonlyArray<PreviewExtension> => []),
    );
    const installedIds = new Set(installed.map((extension) => extension.id));
    const profiles: Array<PreviewExtensionCandidateProfile> = [];
    for (const definition of BROWSER_IMPORT_SOURCES) {
      if (definition.engine !== "chromium" || !definition.platforms.includes(pathContext.platform))
        continue;
      const root = definition.userDataDirectory(pathContext);
      if (root === undefined) continue;
      const sourceProfiles = yield* listSourceProfiles(definition, pathContext);
      for (const profile of sourceProfiles) {
        const profilePath = pathContext.path.resolve(root, profile.directory);
        const extensions = yield* Effect.promise(() => listProfileExtensions(profilePath));
        if (extensions.length === 0) continue;
        profiles.push({
          sourceId: definition.id,
          sourceName: definition.name,
          profileDirectory: profile.directory,
          profileName: profile.name,
          extensions: yield* Effect.forEach(extensions, (extension) =>
            Effect.promise(async () => ({
              id: extension.id,
              name: extension.description.name,
              version: extension.description.version,
              description: extension.description.description,
              iconDataUrl: null,
              installed: installedIds.has(extension.id),
            })),
          ),
        });
      }
    }
    return profiles;
  }).pipe(Effect.provideService(FileSystem.FileSystem, fileSystem));

  return PreviewExtensions.of({
    attachSession: (session) =>
      Effect.promise(() => host.attachSession(session)).pipe(
        Effect.timeoutOption(ATTACH_TIMEOUT),
        Effect.asVoid,
      ),
    list: (tabWebContentsId) => attempt("list", () => host.list(tabWebContentsId)),
    openPopup: (input) => attempt("openPopup", () => host.openPopup(input)),
    listBrowserCandidates,
    importFromBrowser: Effect.fn("PreviewExtensions.importFromBrowser")(function* (input) {
      const definition = BROWSER_IMPORT_SOURCES.find(
        (candidate) => candidate.id === input.sourceId && candidate.engine === "chromium",
      );
      const root = definition?.userDataDirectory(pathContext);
      if (!definition || root === undefined) {
        return yield* new PreviewExtensionError({
          operation: "importFromBrowser",
          cause: new Error("That browser is not available to import from."),
        });
      }
      const source: PreviewExtensionSource = { kind: "browser", sourceId: definition.id };
      const imported = yield* attempt("importFromBrowser", () =>
        host.importFromProfile({
          profilePath: pathContext.path.resolve(root, input.profileDirectory),
          source,
          extensionIds: input.extensionIds,
        }),
      );
      const listed = yield* attempt("list", () => host.list());
      return listed.filter((extension) => imported.some((entry) => entry.id === extension.id));
    }),
    installFromWebStore: Effect.fn("PreviewExtensions.installFromWebStore")(function* (reference) {
      const extensionId = parseWebStoreExtensionId(reference);
      if (extensionId === null) {
        return yield* new PreviewExtensionError({
          operation: "installFromWebStore",
          cause: new Error("Paste a Chrome Web Store link or a 32-letter extension id."),
        });
      }
      const installed = yield* attempt("installFromWebStore", () =>
        host.installFromWebStore(extensionId),
      );
      return yield* listOne(installed.id);
    }),
    setEnabled: (extensionId, enabled) =>
      attempt("setEnabled", () => host.setEnabled(extensionId, enabled)),
    remove: (extensionId) => attempt("remove", () => host.remove(extensionId)),
    subscribeChanges: (listener) =>
      Effect.acquireRelease(
        Effect.sync(() => listeners.add(listener)),
        () => Effect.sync(() => listeners.delete(listener)),
      ).pipe(Effect.asVoid),
  });
}).pipe(Effect.withSpan("PreviewExtensions.make"));

export const layer = Layer.effect(PreviewExtensions, make);
