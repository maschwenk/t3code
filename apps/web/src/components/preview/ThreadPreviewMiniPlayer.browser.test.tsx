import "~/index.css";

import { RegistryContext } from "@effect/atom-react";
import { scopedThreadKey, scopeThreadRef } from "@t3tools/client-runtime/environment";
import { type DeviceServiceState, type EnvironmentId, ThreadId } from "@t3tools/contracts";
import { AsyncResult, Atom } from "effect/reactivity";
import { useState } from "react";
import { expect, it, vi } from "vite-plus/test";
import { page, userEvent } from "vite-plus/test/browser";

import { act, render } from "../../../test/render";
import {
  browserMiniPlayerSource,
  type PreviewMiniPlayerSource,
  previewMiniPlayerSourceKey,
  selectThreadPreviewMiniPlayer,
  usePreviewMiniPlayerStore,
} from "../../previewMiniPlayerStore";
import { appAtomRegistry } from "../../rpc/atomRegistry";
import { deviceEnvironment } from "../../state/device";
import { ChatCanvas } from "../chat/ChatCanvas";
import { ChatCanvasContext } from "../chat/ChatCanvasContext";
import { resolveChatCanvasLayout } from "../chat/chatCanvasLayout";
import { createChatCanvasStore } from "../chat/canvasStore";
import { deviceStreamScreenAtom } from "../device/deviceStreamSession";
import { PREVIEW_MINI_PLAYER_WEBVIEW_Z_INDEX } from "./previewMiniPlayerLayout";
import {
  MiniPlayerShell,
  ThreadPreviewMiniPlayer,
  useThreadPreviewCanvasSource,
} from "./ThreadPreviewMiniPlayer";

vi.mock(import("../device/DeviceStreamView"), () => ({
  DeviceStreamView: (({ viewId }: { viewId: string }) => (
    <div data-testid="stream" data-view-id={viewId} />
  )) as never,
}));

const threadRef = scopeThreadRef("env-1" as EnvironmentId, ThreadId.make("thread-1"));
const phone: PreviewMiniPlayerSource = {
  kind: "device",
  hostId: "local",
  deviceId: "phone",
  platform: "ios",
  name: "Phone",
};

function Harness() {
  const [store] = useState(createChatCanvasStore);
  const miniPlayer = usePreviewMiniPlayerStore((state) =>
    selectThreadPreviewMiniPlayer(state.byThreadKey, threadRef),
  );
  const preview = useThreadPreviewCanvasSource(threadRef, miniPlayer);
  return (
    <ChatCanvas store={store} threadRef={threadRef} preview={preview} composerOverlayElement={null}>
      {miniPlayer ? (
        <ThreadPreviewMiniPlayer threadRef={threadRef} miniPlayer={miniPlayer} />
      ) : null}
    </ChatCanvas>
  );
}

it("drags from anywhere on the floating preview without pressing the page inside it", async () => {
  const source = browserMiniPlayerSource("tab");
  const sourceKey = previewMiniPlayerSourceKey(source);
  const sourceSize = { width: 1_600, height: 1_000 };
  const container = { width: 1_000, height: 700 };
  const viewport = { width: window.innerWidth, height: window.innerHeight };
  await page.viewport(1280, 800);
  await using _viewport = {
    [Symbol.asyncDispose]: () => page.viewport(viewport.width, viewport.height),
  };
  const store = usePreviewMiniPlayerStore.getState();
  store.open(threadRef, source);
  using _player = { [Symbol.dispose]: () => store.removeThread(threadRef) };
  const pressPage = vi.fn();
  const layout = resolveChatCanvasLayout({
    container,
    preview: { key: sourceKey, width: 480, position: { x: 100, y: 100 }, source: sourceSize },
  });
  const frame = layout.frame!;
  const canvas = {
    container,
    lane: { padding: 48, minChatWidth: 640 },
    layout,
    previewKey: sourceKey,
    detailsCardTopInset: 0,
    preferredDetailsCard: null,
    detailsCardPlacement: null,
    registerTimeline: () => {},
    measureDetailsCard: () => {},
  };
  // Outside the player, 300px right of and 200px below its center.
  const drop = { x: frame.x + frame.width / 2 + 300, y: frame.y + frame.height / 2 + 200 };

  await using screen = await render(
    <ChatCanvasContext value={canvas}>
      <div style={{ position: "relative", width: container.width, height: container.height }}>
        <MiniPlayerShell
          threadRef={threadRef}
          miniPlayer={usePreviewMiniPlayerStore.getState().byThreadKey[scopedThreadKey(threadRef)]!}
          sourceSize={sourceSize}
          label="Floating browser preview"
          onOpenInPanel={() => {}}
        >
          {() => (
            <button
              type="button"
              className="pointer-events-auto absolute inset-0"
              style={{ zIndex: PREVIEW_MINI_PLAYER_WEBVIEW_Z_INDEX }}
              onPointerDown={pressPage}
              onClick={pressPage}
            >
              Live page
            </button>
          )}
        </MiniPlayerShell>
        <div
          data-testid="drop"
          style={{ position: "absolute", left: drop.x - 1, top: drop.y - 1, width: 2, height: 2 }}
        />
      </div>
    </ChatCanvasContext>,
    { router: false },
  );

  await userEvent.dragAndDrop(
    screen.getByRole("region", { name: "Floating browser preview" }),
    screen.getByTestId("drop"),
  );

  expect(
    usePreviewMiniPlayerStore.getState().byThreadKey[scopedThreadKey(threadRef)]?.position,
  ).toEqual({ x: frame.x + 300, y: frame.y + 200 });
  expect(pressPage).not.toHaveBeenCalled();
});

it("holds its frame through a source change and stops when the gesture is interrupted", async () => {
  using _state = vi
    .spyOn(deviceEnvironment, "state")
    .mockReturnValue(Atom.make<AsyncResult.AsyncResult<DeviceServiceState>>(AsyncResult.initial()));
  using _store = {
    [Symbol.dispose]: () => usePreviewMiniPlayerStore.getState().removeThread(threadRef),
  };
  usePreviewMiniPlayerStore.getState().open(threadRef, phone);
  const container = document.createElement("div");
  container.style.cssText = "display:flex;position:fixed;inset:0;width:1200px;height:800px";
  await using screen = await render(
    <RegistryContext.Provider value={appAtomRegistry}>
      <Harness />
    </RegistryContext.Provider>,
    { container },
  );
  const player = screen.container.querySelector<HTMLElement>("[data-preview-mini-player]")!;
  const handle = (direction: string) =>
    player.querySelector<HTMLElement>(`[data-preview-mini-player-resize="${direction}"]`)!;
  const rect = () => {
    const { left, top, right, bottom } = player.getBoundingClientRect();
    return { left, top, right, bottom };
  };
  const point = (target: HTMLElement, type: string, x: number, y: number, buttons: number) =>
    act(() =>
      target.dispatchEvent(
        new PointerEvent(type, {
          pointerId: 1,
          pointerType: "mouse",
          isPrimary: true,
          button: type === "pointermove" ? -1 : 0,
          buttons,
          clientX: x,
          clientY: y,
          bubbles: true,
          cancelable: true,
        }),
      ),
    );
  const viewId = screen.getByTestId("stream").element().getAttribute("data-view-id")!;
  const portrait = rect();

  // Held without moving while the device rotates: the frame waits for the release.
  await point(handle("northwest"), "pointerdown", portrait.left, portrait.top, 1);
  await act(() =>
    appAtomRegistry.set(deviceStreamScreenAtom(viewId), {
      width: 1_000,
      height: 2_000,
      orientation: "landscape_left",
    }),
  );
  expect(rect()).toEqual(portrait);

  // The release never arrived, so the next buttonless move ends the gesture where it was held.
  await point(handle("northwest"), "pointermove", portrait.left - 200, portrait.top - 200, 0);
  const landscape = rect();
  expect({ right: landscape.right, bottom: landscape.bottom }).toEqual({
    right: portrait.right,
    bottom: portrait.bottom,
  });
  expect(landscape.right - landscape.left).toBe(2 * (landscape.bottom - landscape.top));
  await point(handle("northwest"), "pointermove", portrait.left - 300, portrait.top - 300, 1);
  expect(rect()).toEqual(landscape);

  await point(handle("west"), "pointerdown", landscape.left, landscape.top + 10, 1);
  await act(() => window.dispatchEvent(new Event("blur")));
  await point(handle("west"), "pointermove", landscape.left - 100, landscape.top + 10, 1);
  expect(rect()).toEqual(landscape);
});
