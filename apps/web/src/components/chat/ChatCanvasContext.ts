import { createContext, useContext } from "react";
import type { ChatCanvasPreview, resolveChatCanvasLayout } from "./chatCanvasLayout";
import type { PreviewMiniPlayerObstacles } from "../preview/previewMiniPlayerLayout";

/** How cards report themselves to the canvas. Stable for the canvas's lifetime. */
export interface ChatCanvasActions {
  reportPreview: (preview: ChatCanvasPreview) => void;
  clearPreview: (key: string) => void;
  registerTimeline: (element: HTMLElement | null) => void;
  reportDetailsCard: (card: PreviewMiniPlayerObstacles["detailsCard"]) => void;
}

/**
 * Canvas geometry, which changes with every pixel the conversation is resized
 * by. Read it only where placement depends on it; callers that just report
 * themselves use {@link useChatCanvasActions}, which does not re-render them.
 */
export const ChatCanvasContext = createContext<
  | ({
      container: { width: number; height: number };
      lane: { padding: number; minChatWidth: number };
      layout: ReturnType<typeof resolveChatCanvasLayout>;
      previewKey: string | null;
    } & ChatCanvasActions)
  | null
>(null);

export const ChatCanvasActionsContext = createContext<ChatCanvasActions | null>(null);

export const useChatCanvas = () => useContext(ChatCanvasContext);
export const useChatCanvasActions = () => useContext(ChatCanvasActionsContext);
