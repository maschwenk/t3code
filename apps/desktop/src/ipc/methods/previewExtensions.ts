import {
  DesktopPreviewExtensionIdInputSchema,
  DesktopPreviewExtensionImportInputSchema,
  DesktopPreviewExtensionOpenPopupInputSchema,
  DesktopPreviewExtensionSetEnabledInputSchema,
  DesktopPreviewExtensionWebStoreInputSchema,
  DesktopPreviewExtensionsListInputSchema,
  PreviewExtension,
  PreviewExtensionCandidateProfile,
} from "@t3tools/contracts";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";

import * as ElectronWindow from "../../electron/ElectronWindow.ts";
import * as PreviewExtensions from "../../preview/extensions/PreviewExtensions.ts";
import * as IpcChannels from "../channels.ts";
import * as DesktopIpc from "../DesktopIpc.ts";

export const installPreviewExtensionEventForwarding = Effect.fn(
  "desktop.ipc.previewExtensions.installEventForwarding",
)(function* () {
  const electronWindow = yield* ElectronWindow.ElectronWindow;
  const extensions = yield* PreviewExtensions.PreviewExtensions;
  yield* extensions.subscribeChanges(() =>
    electronWindow.sendAll(IpcChannels.PREVIEW_EXTENSIONS_CHANGED_CHANNEL),
  );
});

export const list = DesktopIpc.makeIpcMethod({
  channel: IpcChannels.PREVIEW_EXTENSIONS_LIST_CHANNEL,
  payload: DesktopPreviewExtensionsListInputSchema,
  result: Schema.Array(PreviewExtension),
  handler: Effect.fn("desktop.ipc.previewExtensions.list")(function* ({ tabWebContentsId }) {
    const extensions = yield* PreviewExtensions.PreviewExtensions;
    return yield* extensions.list(tabWebContentsId);
  }),
});

export const openPopup = DesktopIpc.makeIpcMethod({
  channel: IpcChannels.PREVIEW_EXTENSIONS_OPEN_POPUP_CHANNEL,
  payload: DesktopPreviewExtensionOpenPopupInputSchema,
  result: Schema.Void,
  handler: Effect.fn("desktop.ipc.previewExtensions.openPopup")(function* (input, event) {
    const extensions = yield* PreviewExtensions.PreviewExtensions;
    if (!event) return;
    yield* extensions.openPopup({ ...input, ownerWebContentsId: event.sender.id });
  }),
});

export const listBrowserCandidates = DesktopIpc.makeIpcMethod({
  channel: IpcChannels.PREVIEW_EXTENSIONS_CANDIDATES_CHANNEL,
  payload: Schema.Void,
  result: Schema.Array(PreviewExtensionCandidateProfile),
  handler: Effect.fn("desktop.ipc.previewExtensions.listBrowserCandidates")(function* () {
    const extensions = yield* PreviewExtensions.PreviewExtensions;
    return yield* extensions.listBrowserCandidates;
  }),
});

export const importFromBrowser = DesktopIpc.makeIpcMethod({
  channel: IpcChannels.PREVIEW_EXTENSIONS_IMPORT_CHANNEL,
  payload: DesktopPreviewExtensionImportInputSchema,
  result: Schema.Array(PreviewExtension),
  handler: Effect.fn("desktop.ipc.previewExtensions.importFromBrowser")(function* (input) {
    const extensions = yield* PreviewExtensions.PreviewExtensions;
    return yield* extensions.importFromBrowser(input);
  }),
});

export const installFromWebStore = DesktopIpc.makeIpcMethod({
  channel: IpcChannels.PREVIEW_EXTENSIONS_INSTALL_WEB_STORE_CHANNEL,
  payload: DesktopPreviewExtensionWebStoreInputSchema,
  result: PreviewExtension,
  handler: Effect.fn("desktop.ipc.previewExtensions.installFromWebStore")(function* ({
    reference,
  }) {
    const extensions = yield* PreviewExtensions.PreviewExtensions;
    return yield* extensions.installFromWebStore(reference);
  }),
});

export const setEnabled = DesktopIpc.makeIpcMethod({
  channel: IpcChannels.PREVIEW_EXTENSIONS_SET_ENABLED_CHANNEL,
  payload: DesktopPreviewExtensionSetEnabledInputSchema,
  result: Schema.Void,
  handler: Effect.fn("desktop.ipc.previewExtensions.setEnabled")(function* ({
    extensionId,
    enabled,
  }) {
    const extensions = yield* PreviewExtensions.PreviewExtensions;
    yield* extensions.setEnabled(extensionId, enabled);
  }),
});

export const remove = DesktopIpc.makeIpcMethod({
  channel: IpcChannels.PREVIEW_EXTENSIONS_REMOVE_CHANNEL,
  payload: DesktopPreviewExtensionIdInputSchema,
  result: Schema.Void,
  handler: Effect.fn("desktop.ipc.previewExtensions.remove")(function* ({ extensionId }) {
    const extensions = yield* PreviewExtensions.PreviewExtensions;
    yield* extensions.remove(extensionId);
  }),
});
