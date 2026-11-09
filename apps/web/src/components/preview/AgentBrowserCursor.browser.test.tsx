import { describe, expect, it, vi } from "vite-plus/test";

import "~/index.css";
import { useBrowserPointerStore } from "~/browser/browserPointerStore";
import { useBrowserSurfaceStore } from "~/browser/browserSurfaceStore";

import { render } from "../../../test/render";
import { AgentBrowserCursor } from "./AgentBrowserCursor";

function setup() {
  useBrowserSurfaceStore.setState({ byTabId: {} });
  useBrowserPointerStore.setState({
    byTabId: {
      tab: {
        tabId: "tab",
        phase: "move",
        x: 40,
        y: 30,
        sequence: 1,
        createdAt: "2026-11-08T00:00:00.000Z",
      },
    },
  });
}

describe("AgentBrowserCursor", () => {
  it("follows page zoom to the agent's point without changing its on-screen size", async () => {
    setup();
    await using screen = await render(
      <AgentBrowserCursor tabId="tab" zoomFactor={1} controller="agent" />,
    );
    const arrow = () =>
      screen.container.querySelector("[data-agent-cursor-arrow]")!.getBoundingClientRect();
    const unzoomed = arrow();

    await screen.rerender(<AgentBrowserCursor tabId="tab" zoomFactor={2} controller="agent" />);

    // The page point (40, 30) now sits 40 px right and 30 px down on screen.
    await vi.waitFor(() => {
      expect(arrow().left - unzoomed.left).toBeCloseTo(40);
      expect(arrow().top - unzoomed.top).toBeCloseTo(30);
    });
    // Sub-pixel translation can perturb the measured box by float noise.
    expect(arrow().width).toBeCloseTo(unzoomed.width, 3);
    expect(arrow().height).toBeCloseTo(unzoomed.height, 3);
  });
});
