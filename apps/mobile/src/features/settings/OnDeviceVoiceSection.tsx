import { useAtomSet, useAtomValue } from "@effect/atom-react";
import { AsyncResult, Atom } from "effect/reactivity";
import { View } from "react-native";

import * as Dialog from "../../components/ui/Dialog";
import { ListActionRow } from "../../components/ui/ListActionRow";
import { ListChoiceRow } from "../../components/ui/ListChoiceRow";
import { Progress } from "../../components/ui/Progress";
import { formatBytes } from "../../lib/formatBytes";
import { PARAKEET_DOWNLOAD_BYTES, parakeet, type ParakeetModule } from "../../native/parakeet";
import { mobilePreferencesAtom, updateMobilePreferencesAtom } from "../../state/preferences";
import { SettingsSection } from "./components/SettingsSection";

const size = formatBytes(PARAKEET_DOWNLOAD_BYTES);

const parakeetModelAtom = Atom.make((get) => {
  if (!parakeet) return null;
  const subscription = parakeet.addListener("onParakeetModel", (status) => get.setSelf(status));
  get.addFinalizer(() => subscription.remove());
  return parakeet.getParakeetModel();
});

function download(native: ParakeetModule) {
  native.downloadParakeetModel().catch((error: unknown) => {
    Dialog.alert(
      "Could not download Parakeet",
      error instanceof Error ? error.message : String(error),
    );
  });
}

/** The on-device engine choice. Only iOS builds with Parakeet offer one. */
export function OnDeviceVoiceSection(props: { readonly systemAvailable: boolean }) {
  const preferences = useAtomValue(mobilePreferencesAtom);
  const savePreferences = useAtomSet(updateMobilePreferencesAtom);
  const model = useAtomValue(parakeetModelAtom);
  if (!parakeet || !model || !AsyncResult.isSuccess(preferences)) return null;
  const native = parakeet;
  const engine = preferences.value.onDeviceVoiceEngine ?? "system";

  const confirmDownload = (onConfirm?: () => void) =>
    Dialog.confirm({
      title: `Download Parakeet (${size})?`,
      message:
        "T3 Code downloads NVIDIA’s Parakeet speech model once, then transcribes on this device without a network connection.",
      confirmText: "Download",
      onConfirm: () => {
        onConfirm?.();
        download(native);
      },
    });

  return (
    <SettingsSection title="Engine on this device">
      <ListChoiceRow
        label="Apple"
        description={
          props.systemAvailable
            ? "Built into iOS. Uses your preferred languages."
            : "Needs iOS 26 or later on a supported device."
        }
        selected={engine === "system"}
        onPress={() => savePreferences({ onDeviceVoiceEngine: "system" })}
      />
      <ListChoiceRow
        label="Parakeet"
        description={`NVIDIA Parakeet. 25 European languages, ${size} download.`}
        selected={engine === "parakeet"}
        separated
        onPress={() => {
          if (engine === "parakeet") return;
          if (model.state === "missing")
            confirmDownload(() => savePreferences({ onDeviceVoiceEngine: "parakeet" }));
          else savePreferences({ onDeviceVoiceEngine: "parakeet" });
        }}
      />
      {model.state === "downloading" ? (
        <View className="border-t border-border-subtle">
          <ListActionRow
            icon="xmark"
            label={model.phase === "compiling" ? "Setting up Parakeet" : "Downloading Parakeet"}
            description={
              model.phase === "compiling"
                ? `${Math.round(model.progress * 100)}% · Optimizing for this device, a few minutes · Tap to cancel`
                : `${Math.round(model.progress * 100)}% · ${size} download · Tap to cancel`
            }
            onPress={() => native.cancelParakeetModelDownload()}
          />
          <Progress
            className="bg-grouped-card px-4 pb-3"
            value={model.progress}
            label="Parakeet download progress"
          />
        </View>
      ) : model.state === "ready" ? (
        <View className="border-t border-border-subtle">
          <ListActionRow
            icon="trash"
            tone="danger"
            label="Delete Parakeet"
            description={`Frees ${size} on this device`}
            onPress={() =>
              Dialog.confirm({
                title: "Delete Parakeet?",
                message:
                  engine === "parakeet"
                    ? "Dictation on this device stops until you download it again or choose Apple."
                    : undefined,
                confirmText: "Delete",
                destructive: true,
                onConfirm: () =>
                  void native.deleteParakeetModel().catch((error: unknown) => {
                    Dialog.alert(
                      "Could not delete Parakeet",
                      error instanceof Error ? error.message : String(error),
                    );
                  }),
              })
            }
          />
        </View>
      ) : engine === "parakeet" ? (
        <View className="border-t border-border-subtle">
          <ListActionRow
            icon="tray.and.arrow.down"
            label="Download Parakeet"
            description={`${size} · Stays on this device`}
            onPress={() => confirmDownload()}
          />
        </View>
      ) : null}
    </SettingsSection>
  );
}
