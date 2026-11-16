import { EnvironmentId, ThreadId } from "@t3tools/contracts";
import { scopedThreadKey } from "@t3tools/client-runtime/environment";
import { expect, it, vi } from "vite-plus/test";
import { page, userEvent } from "vite-plus/test/browser";

import { render } from "../../../test/render";
import { ChatCanvasContext } from "../chat/ChatCanvasContext";
import { resolveChatCanvasLayout } from "../chat/chatCanvasLayout";
import {
  browserMiniPlayerSource,
  previewMiniPlayerSourceKey,
  usePreviewMiniPlayerStore,
} from "~/previewMiniPlayerStore";
import { PREVIEW_MINI_PLAYER_WEBVIEW_Z_INDEX } from "./previewMiniPlayerLayout";
import { MiniPlayerShell } from "./ThreadPreviewMiniPlayer";
import "~/index.css";

const threadRef = {
  environmentId: EnvironmentId.make("local"),
  threadId: ThreadId.make("thread"),
};
const source = browserMiniPlayerSource("tab");
const sourceKey = previewMiniPlayerSourceKey(source);
const sourceSize = { width: 1_600, height: 1_000 };
const container = { width: 1_000, height: 700 };

it("drags from anywhere on the floating preview without pressing the page inside it", async () => {
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
