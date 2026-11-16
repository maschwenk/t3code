import { useAtomSet, useAtomValue } from "@effect/atom-react";
import {
  isAtomCommandInterrupted,
  settleAsyncResult,
  settlePromise,
  squashAtomCommandFailure,
} from "@t3tools/client-runtime/state/runtime";
import * as Notifications from "expo-notifications";
import { useSyncExternalStore } from "react";
import { Linking } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { AppText as Text } from "../../components/ui/AppText";
import * as Dialog from "../../components/ui/Dialog";
import { ScreenScrollView as ScrollView } from "../../components/ui/ScreenScrollView";
import { makePermissionStatusAtom } from "../../lib/permissionStatusAtom";
import { runtime } from "../../lib/runtime";
import {
  type DirectPushComputerStatus,
  getDirectPushComputers,
  subscribeDirectPushComputers,
  syncDirectPushRegistrations,
} from "../agent-awareness/directPushRegistration";
import { requestAgentNotificationPermission } from "../agent-awareness/notificationPermissions";
import { SettingsRow } from "./components/SettingsRow";
import { SettingsScreen } from "./components/SettingsScreen";
import { SettingsSection } from "./components/SettingsSection";
import { SettingsSwitchRow } from "./components/SettingsSwitchRow";

const permissionAtom = makePermissionStatusAtom<"checking" | "granted" | "off">({
  label: "mobile:direct-push-notification-permission",
  initial: "checking",
  read: async () => {
    const result = await settlePromise(() => Notifications.getPermissionsAsync());
    return result._tag === "Success" && result.value.granted ? "granted" : "off";
  },
});

const STATUS_TEXT: Record<DirectPushComputerStatus, string> = {
  registering: "Registering this phone…",
  sending: "Sends alerts to this phone",
  ready: "Sends alerts once notifications are on",
  "needs-key": "Run `t3 push key` on this computer to send alerts",
  unsupported: "This computer's T3 Code can't send alerts directly",
  failed: "Couldn't register. Retries when you reopen the app",
};

function openSystemSettings(title: string, message: string): void {
  Dialog.alert(title, message, [
    { text: "Cancel", style: "cancel" },
    { text: "Open Settings", onPress: () => void Linking.openSettings() },
  ]);
}

/** Notifications for builds signed by your own Apple team, which T3 Connect cannot alert. */
export function DirectPushNotificationsScreen() {
  const insets = useSafeAreaInsets();
  const permission = useAtomValue(permissionAtom);
  const setPermission = useAtomSet(permissionAtom);
  const computers = useSyncExternalStore(
    subscribeDirectPushComputers,
    getDirectPushComputers,
    getDirectPushComputers,
  );

  const enableNotifications = async () => {
    const result = await settleAsyncResult(() =>
      runtime.runPromiseExit(requestAgentNotificationPermission),
    );
    if (result._tag === "Failure") {
      if (!isAtomCommandInterrupted(result)) {
        const error = squashAtomCommandFailure(result);
        Dialog.alert(
          "Notifications unavailable",
          error instanceof Error ? error.message : "Could not request notification permission.",
        );
      }
      return;
    }
    if (result.value.type === "granted") {
      setPermission("granted");
      await syncDirectPushRegistrations({ force: true });
      return;
    }
    setPermission("off");
    if (result.value.type === "denied" && !result.value.canAskAgain) {
      openSystemSettings(
        "Notifications disabled",
        "Notifications were denied for this app. Open Settings to enable them.",
      );
    }
  };

  const handleChange = (enabled: boolean) => {
    if (enabled) {
      void enableNotifications();
      return;
    }
    openSystemSettings(
      "Turn off notifications",
      "iOS lets apps turn notifications on but not off. Open Settings to turn them off.",
    );
  };

  return (
    <SettingsScreen title="Notifications">
      <ScrollView
        contentInsetAdjustmentBehavior="automatic"
        showsVerticalScrollIndicator={false}
        className="flex-1"
        contentContainerClassName="gap-6 px-5 pt-4"
        contentContainerStyle={{ paddingBottom: Math.max(insets.bottom, 18) + 18 }}
      >
        <SettingsSection title="Agent activity">
          <SettingsSwitchRow
            icon="bell.badge"
            label="Device Notifications"
            subtitle="Your computers send alerts straight to this phone with your APNs key"
            disabled={permission === "checking"}
            value={permission === "granted"}
            onValueChange={handleChange}
          />
        </SettingsSection>
        <SettingsSection title="Computers">
          {computers.size === 0 ? (
            <Text className="px-4 py-3 text-base text-foreground-muted">
              {permission === "granted"
                ? "Connect to a computer to get its alerts."
                : "Turn on notifications, then connect to a computer to get its alerts."}
            </Text>
          ) : (
            [...computers].map(([environmentId, computer]) => (
              <SettingsRow
                key={environmentId}
                icon="server.rack"
                label={computer.label}
                value={STATUS_TEXT[computer.status]}
                valuePosition="below"
              />
            ))
          )}
        </SettingsSection>
      </ScrollView>
    </SettingsScreen>
  );
}
