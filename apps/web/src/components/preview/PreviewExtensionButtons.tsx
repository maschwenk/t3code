import type { PreviewExtension } from "@t3tools/contracts";
import { Puzzle } from "lucide-react";
import { type MouseEvent, useEffect, useState } from "react";

import { Button } from "~/components/ui/button";
import { toastManager } from "~/components/ui/toast";
import { Tooltip, TooltipPopup, TooltipTrigger } from "~/components/ui/tooltip";

import { previewBridge } from "./previewBridge";

/** The message of a failed desktop call, without Electron's IPC framing. */
export function extensionErrorMessage(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  return message
    .replace(/^Error invoking remote method '[^']+':\s*/u, "")
    .replace(/^\w*Error:\s*/u, "");
}

/**
 * Installed browser extensions, with toolbar state as one preview tab sees it
 * (badges and icons can differ per tab). Pass null for the installed set alone.
 */
export function usePreviewExtensions(
  tabWebContentsId: number | null,
): ReadonlyArray<PreviewExtension> | null {
  const bridge = previewBridge?.extensions;
  const [extensions, setExtensions] = useState<ReadonlyArray<PreviewExtension> | null>(null);
  useEffect(() => {
    if (!bridge) return;
    let current = true;
    let request = 0;
    const refresh = () => {
      const id = ++request;
      bridge.list(tabWebContentsId ?? undefined).then(
        (next) => {
          if (current && id === request) setExtensions(next);
        },
        () => undefined,
      );
    };
    refresh();
    const unsubscribe = bridge.onChange(refresh);
    return () => {
      current = false;
      unsubscribe();
    };
  }, [bridge, tabWebContentsId]);
  return extensions;
}

/** Toolbar buttons for the extensions running in the preview tab's profile. */
export function PreviewExtensionButtons({
  tabWebContentsId,
}: {
  readonly tabWebContentsId: number | null;
}) {
  const extensions = usePreviewExtensions(tabWebContentsId);
  if (tabWebContentsId === null || !extensions) return null;
  const shown = extensions.filter(
    (extension) => extension.enabled && extension.action !== null && extension.loadError === null,
  );
  if (shown.length === 0) return null;
  return (
    <div className="flex items-center gap-0.5" role="group" aria-label="Extensions">
      {shown.map((extension) => (
        <ExtensionButton
          key={extension.id}
          extension={extension}
          tabWebContentsId={tabWebContentsId}
        />
      ))}
    </div>
  );
}

function ExtensionButton({
  extension,
  tabWebContentsId,
}: {
  readonly extension: PreviewExtension;
  readonly tabWebContentsId: number;
}) {
  const action = extension.action;
  if (!action) return null;
  const open = (event: MouseEvent<HTMLButtonElement>) => {
    // The popup opens under the button, so it needs the button's position.
    const rect = event.currentTarget.getBoundingClientRect();
    previewBridge?.extensions
      .openPopup({
        extensionId: extension.id,
        tabWebContentsId,
        anchor: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
      })
      .catch((error: unknown) => {
        toastManager.add({
          type: "error",
          title: `Could not open ${extension.name}`,
          description: extensionErrorMessage(error),
        });
      });
  };
  return (
    <Tooltip>
      <TooltipTrigger
        render={
          <Button
            variant="ghost"
            size="icon-xs"
            type="button"
            className="relative"
            aria-label={action.title}
            disabled={!action.enabled}
            onClick={open}
          />
        }
      >
        {action.iconDataUrl ? (
          <img src={action.iconDataUrl} alt="" className="size-4" draggable={false} />
        ) : (
          <Puzzle />
        )}
        {action.badgeText ? (
          <span
            className="pointer-events-none absolute -right-1 -bottom-0.5 min-w-3.5 rounded-sm px-0.5 text-center text-4xs leading-3.5 font-semibold"
            style={{
              backgroundColor: action.badgeBackgroundColor ?? "#d93025",
              color: action.badgeTextColor ?? "#ffffff",
            }}
          >
            {action.badgeText}
          </span>
        ) : null}
      </TooltipTrigger>
      <TooltipPopup>{action.title}</TooltipPopup>
    </Tooltip>
  );
}
