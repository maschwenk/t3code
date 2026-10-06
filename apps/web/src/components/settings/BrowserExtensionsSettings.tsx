/**
 * Browser extensions for the preview browser: install from another browser on
 * this computer or from the Chrome Web Store, turn on and off, remove.
 *
 * @module BrowserExtensionsSettings
 */
import type { PreviewExtension, PreviewExtensionCandidateProfile } from "@t3tools/contracts";
import { MoreVertical, Plus as PlusIcon, Puzzle } from "lucide-react";
import { type FormEvent, useEffect, useState } from "react";

import { previewBridge } from "~/components/preview/previewBridge";
import {
  extensionErrorMessage,
  usePreviewExtensions,
} from "~/components/preview/PreviewExtensionButtons";
import { cn } from "~/lib/utils";

import { Button } from "../ui/button";
import {
  Dialog,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogPanel,
  DialogPopup,
  DialogTitle,
} from "../ui/dialog";
import { Input } from "../ui/input";
import { Label } from "../ui/label";
import { Menu, MenuItem, MenuPopup, MenuTrigger } from "../ui/menu";
import { Switch } from "../ui/switch";
import { toastManager } from "../ui/toast";
import { SettingsRow } from "./settingsLayout";

function ExtensionIcon({
  src,
  className,
}: {
  readonly src: string | null;
  readonly className?: string;
}) {
  return src ? (
    <img src={src} alt="" className={cn("size-5 shrink-0", className)} draggable={false} />
  ) : (
    <Puzzle className={cn("size-5 shrink-0 text-muted-foreground", className)} />
  );
}

export function BrowserExtensionsSetting({ disabled }: { readonly disabled: boolean }) {
  const bridge = previewBridge?.extensions ?? null;
  const extensions = usePreviewExtensions(null);
  const [dialog, setDialog] = useState<"browser" | "webStore" | null>(null);
  // Remounts the import dialog on each open, so it starts with a fresh scan.
  const [importSession, setImportSession] = useState(0);
  const unavailable = disabled || bridge === null;

  const setEnabled = (extension: PreviewExtension, enabled: boolean) => {
    bridge?.setEnabled(extension.id, enabled).catch((error: unknown) => {
      toastManager.add({
        type: "error",
        title: `Could not turn ${enabled ? "on" : "off"} ${extension.name}`,
        description: extensionErrorMessage(error),
      });
    });
  };
  const remove = (extension: PreviewExtension) => {
    bridge?.remove(extension.id).then(
      () => toastManager.add({ type: "success", title: `Removed ${extension.name}` }),
      (error: unknown) =>
        toastManager.add({
          type: "error",
          title: `Could not remove ${extension.name}`,
          description: extensionErrorMessage(error),
        }),
    );
  };

  return (
    <SettingsRow
      id="browser-extensions"
      title="Extensions"
      description="Chrome extensions such as 1Password run in every profile except Incognito. Each profile keeps its own sign-ins."
      control={
        <Menu>
          <MenuTrigger render={<Button size="sm" variant="outline" disabled={unavailable} />}>
            <PlusIcon />
            Add extension
          </MenuTrigger>
          <MenuPopup align="end">
            <MenuItem
              onClick={() => {
                setImportSession((session) => session + 1);
                setDialog("browser");
              }}
            >
              From a browser on this computer…
            </MenuItem>
            <MenuItem onClick={() => setDialog("webStore")}>From the Chrome Web Store…</MenuItem>
          </MenuPopup>
        </Menu>
      }
    >
      {extensions && extensions.length > 0 ? (
        <div className="mt-2 mb-2 overflow-hidden rounded-lg border border-border/60">
          {extensions.map((extension, index) => (
            <div
              key={extension.id}
              className={cn(
                "flex items-center gap-3 px-3 py-2",
                index > 0 && "border-t border-border/60",
              )}
            >
              <ExtensionIcon
                src={extension.iconDataUrl}
                className={cn(!extension.enabled && "opacity-50")}
              />
              <div className="min-w-0 flex-1">
                <div className="flex min-w-0 items-baseline gap-2">
                  <span className="truncate text-sm text-foreground">{extension.name}</span>
                  <span className="shrink-0 text-xs text-muted-foreground">
                    {extension.version}
                  </span>
                </div>
                {extension.loadError ? (
                  <p className="text-xs text-destructive">{extension.loadError}</p>
                ) : null}
              </div>
              <Switch
                size="sm"
                checked={extension.enabled}
                disabled={unavailable}
                aria-label={`Turn ${extension.name} ${extension.enabled ? "off" : "on"}`}
                onCheckedChange={(checked) => setEnabled(extension, checked)}
              />
              <Menu>
                <MenuTrigger
                  render={
                    <Button
                      size="icon-xs"
                      variant="ghost-muted"
                      disabled={unavailable}
                      aria-label={`${extension.name} options`}
                    />
                  }
                >
                  <MoreVertical />
                </MenuTrigger>
                <MenuPopup align="end">
                  <MenuItem variant="destructive" onClick={() => remove(extension)}>
                    Remove
                  </MenuItem>
                </MenuPopup>
              </Menu>
            </div>
          ))}
        </div>
      ) : null}
      <ImportFromBrowserDialog
        key={importSession}
        open={dialog === "browser"}
        onOpenChange={(open) => setDialog(open ? "browser" : null)}
      />
      <WebStoreDialog
        open={dialog === "webStore"}
        onOpenChange={(open) => setDialog(open ? "webStore" : null)}
      />
    </SettingsRow>
  );
}

function ImportFromBrowserDialog({
  open,
  onOpenChange,
}: {
  readonly open: boolean;
  readonly onOpenChange: (open: boolean) => void;
}) {
  const bridge = previewBridge?.extensions ?? null;
  const [profiles, setProfiles] = useState<ReadonlyArray<PreviewExtensionCandidateProfile> | null>(
    null,
  );
  const [adding, setAdding] = useState<string | null>(null);
  const [added, setAdded] = useState<ReadonlySet<string>>(new Set());

  useEffect(() => {
    if (!open || !bridge) return;
    let current = true;
    bridge.listBrowserCandidates().then(
      (next) => {
        if (current) setProfiles(next);
      },
      () => {
        if (current) setProfiles([]);
      },
    );
    return () => {
      current = false;
    };
  }, [bridge, open]);

  const add = (profile: PreviewExtensionCandidateProfile, extensionId: string, name: string) => {
    if (!bridge) return;
    const key = `${profile.sourceId}:${profile.profileDirectory}:${extensionId}`;
    setAdding(key);
    bridge
      .importFromBrowser({
        sourceId: profile.sourceId,
        profileDirectory: profile.profileDirectory,
        extensionIds: [extensionId],
      })
      .then(
        () => {
          setAdded((previous) => new Set(previous).add(extensionId));
          toastManager.add({ type: "success", title: `Added ${name}` });
        },
        (error: unknown) =>
          toastManager.add({
            type: "error",
            title: `Could not add ${name}`,
            description: extensionErrorMessage(error),
          }),
      )
      .finally(() => setAdding(null));
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogPopup className="max-w-lg">
        <DialogHeader>
          <DialogTitle>Add from a browser</DialogTitle>
          <DialogDescription>
            Copies an extension you already use in Chrome or another Chromium browser. Sign in to it
            again inside T3 Code.
          </DialogDescription>
        </DialogHeader>
        <DialogPanel className="max-h-[60vh] overflow-y-auto">
          {profiles === null ? (
            <p className="text-sm text-muted-foreground">Looking for browsers…</p>
          ) : profiles.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              No extensions found in Chrome, Edge, Brave, Arc or other Chromium browsers.
            </p>
          ) : (
            <div className="grid gap-4">
              {profiles.map((profile) => (
                <section
                  key={`${profile.sourceId}:${profile.profileDirectory}`}
                  className="grid gap-1"
                >
                  <h3 className="text-xs font-medium text-muted-foreground">
                    {profile.sourceName} · {profile.profileName}
                  </h3>
                  <div className="overflow-hidden rounded-lg border border-border/60">
                    {profile.extensions.map((extension, index) => {
                      const key = `${profile.sourceId}:${profile.profileDirectory}:${extension.id}`;
                      const isAdded = extension.installed || added.has(extension.id);
                      return (
                        <div
                          key={extension.id}
                          className={cn(
                            "flex items-center gap-3 px-3 py-2",
                            index > 0 && "border-t border-border/60",
                          )}
                        >
                          <div className="min-w-0 flex-1">
                            <p className="truncate text-sm text-foreground">{extension.name}</p>
                            {extension.description ? (
                              <p className="truncate text-xs text-muted-foreground">
                                {extension.description}
                              </p>
                            ) : null}
                          </div>
                          <Button
                            size="xs"
                            variant={isAdded ? "ghost" : "outline"}
                            disabled={isAdded || adding !== null}
                            onClick={() => add(profile, extension.id, extension.name)}
                          >
                            {isAdded ? "Added" : adding === key ? "Adding…" : "Add"}
                          </Button>
                        </div>
                      );
                    })}
                  </div>
                </section>
              ))}
            </div>
          )}
        </DialogPanel>
        <DialogFooter variant="bare">
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Done
          </Button>
        </DialogFooter>
      </DialogPopup>
    </Dialog>
  );
}

function WebStoreDialog({
  open,
  onOpenChange,
}: {
  readonly open: boolean;
  readonly onOpenChange: (open: boolean) => void;
}) {
  const bridge = previewBridge?.extensions ?? null;
  const [reference, setReference] = useState("");
  const [installing, setInstalling] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const close = (next: boolean) => {
    if (!next) {
      setReference("");
      setError(null);
    }
    onOpenChange(next);
  };
  const install = (event?: FormEvent) => {
    event?.preventDefault();
    if (!bridge || reference.trim() === "" || installing) return;
    setInstalling(true);
    setError(null);
    bridge
      .installFromWebStore(reference.trim())
      .then(
        (extension) => {
          toastManager.add({ type: "success", title: `Added ${extension.name}` });
          close(false);
        },
        (failure: unknown) => setError(extensionErrorMessage(failure)),
      )
      .finally(() => setInstalling(false));
  };

  return (
    <Dialog open={open} onOpenChange={close}>
      <DialogPopup className="max-w-md">
        <DialogHeader>
          <DialogTitle>Add from the Chrome Web Store</DialogTitle>
          <DialogDescription>
            Paste the extension&rsquo;s Chrome Web Store link. Most extensions work; ones that rely
            on Chrome-only features may not.
          </DialogDescription>
        </DialogHeader>
        <DialogPanel>
          <form className="grid gap-1.5" onSubmit={install}>
            <Label htmlFor="extension-web-store-link">Link or extension id</Label>
            <Input
              id="extension-web-store-link"
              placeholder="https://chromewebstore.google.com/detail/…"
              value={reference}
              onChange={(event) => setReference(event.target.value)}
              autoFocus
            />
            {error ? <p className="text-xs text-destructive">{error}</p> : null}
          </form>
        </DialogPanel>
        <DialogFooter variant="bare">
          <Button variant="outline" onClick={() => close(false)}>
            Cancel
          </Button>
          <Button onClick={() => install()} disabled={reference.trim() === "" || installing}>
            {installing ? "Adding…" : "Add extension"}
          </Button>
        </DialogFooter>
      </DialogPopup>
    </Dialog>
  );
}
