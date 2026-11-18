import type { EnvironmentId } from "@t3tools/contracts";
import {
  DEFAULT_SNOOZE_PRESETS,
  SnoozePresetSetting,
  type TimestampFormat,
} from "@t3tools/contracts/settings";
import {
  pickSnoozePreset as pickSharedSnoozePreset,
  resolveRepeatSnooze,
  resolveSnoozePresets as resolveSharedSnoozePresets,
  snoozeLengthSetting,
  snoozePresetId,
  snoozeWakeLabel,
  type SnoozePreset,
} from "@t3tools/client-runtime/state/thread-settled";

import { getLocalStorageItem, setLocalStorageItem } from "../hooks/useLocalStorage";
import { appAtomRegistry } from "../rpc/atomRegistry";
import { serverEnvironment } from "../state/server";
import { formatShortTimestamp } from "../timestampFormat";
import { toastManager } from "./ui/toast";

export { snoozeWakeLabel, type SnoozePreset };

const LAST_SNOOZE_KEY = "t3code:last-snooze";

/** The snooze menu for a thread, from its environment's presets, read when the menu opens. */
export function resolveSnoozePresets(
  now: Date,
  timestampFormat: TimestampFormat,
  environmentId: EnvironmentId,
): ReadonlyArray<SnoozePreset> {
  return resolveSharedSnoozePresets(now, snoozeOptions(timestampFormat, environmentId));
}

/** A shown menu choice as picked; see the shared `pickSnoozePreset`. */
export function pickSnoozePreset(
  shown: ReadonlyArray<SnoozePreset>,
  id: string,
  timestampFormat: TimestampFormat,
  environmentId: EnvironmentId,
): SnoozePreset | undefined {
  const options = snoozeOptions(timestampFormat, environmentId);
  const picked = pickSharedSnoozePreset({ shown, id, now: new Date(), ...options });
  if (!picked) {
    toastManager.add({
      type: "warning",
      title: "Could not snooze thread",
      description: "That snooze time has passed. Choose another time.",
    });
    return undefined;
  }
  const setting = (options.presets ?? DEFAULT_SNOOZE_PRESETS).find(
    (candidate) => snoozePresetId(candidate) === id,
  );
  if (setting) rememberSnooze(setting);
  return picked;
}

export function rememberCustomSnooze(snoozedUntil: string, now: Date): void {
  const setting = snoozeLengthSetting(snoozedUntil, now);
  if (setting) rememberSnooze(setting);
}

/** The snooze shortcut repeats the last choice made in any snooze menu on this device. */
export function resolveShortcutSnooze(environmentId: EnvironmentId): SnoozePreset | null {
  const presets = environmentSnoozePresets(environmentId);
  return resolveRepeatSnooze(readRememberedSnooze(), new Date(), presets ? { presets } : {});
}

function rememberSnooze(setting: SnoozePresetSetting) {
  try {
    setLocalStorageItem(LAST_SNOOZE_KEY, setting, SnoozePresetSetting);
  } catch {
    // Storage can be full or blocked; the shortcut then keeps the previous choice.
  }
}

function readRememberedSnooze(): SnoozePresetSetting | null {
  try {
    return getLocalStorageItem(LAST_SNOOZE_KEY, SnoozePresetSetting);
  } catch {
    return null;
  }
}

function environmentSnoozePresets(environmentId: EnvironmentId) {
  return appAtomRegistry.get(serverEnvironment.settingsValueAtom(environmentId))?.snoozePresets;
}

function snoozeOptions(timestampFormat: TimestampFormat, environmentId: EnvironmentId) {
  const presets = environmentSnoozePresets(environmentId);
  return {
    ...(presets ? { presets } : {}),
    formatTime: (date: Date) => formatShortTimestamp(date.toISOString(), timestampFormat),
  };
}
