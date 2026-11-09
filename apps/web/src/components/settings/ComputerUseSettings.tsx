import { DraftInput } from "../ui/draft-input";
import { searchableSetting } from "./settingsSearch";
import { ScopedSwitch } from "./ScopedSwitch";
import { SettingsRow, SettingsSection } from "./settingsLayout";
import { useScopedSettings, useUpdateScopedSettings } from "./useScopedSettings";

export function ComputerUseSettings() {
  const settings = useScopedSettings();
  const updateSettings = useUpdateScopedSettings();
  return (
    <SettingsSection id="computer-use" title="Computer use">
      <SettingsRow
        {...searchableSetting("agent-computer-access")}
        serverScoped
        settingKeys={["enableAgentComputerAccess"]}
        description="Let agents operate allowed macOS apps on this machine, also when you connect remotely. They work in the background with an agent cursor. Needs macOS Accessibility permission."
        control={
          <ScopedSwitch
            settingKeys={["enableAgentComputerAccess"]}
            checked={settings.enableAgentComputerAccess}
            aria-label="Agent computer access"
            onCheckedChange={(checked) =>
              updateSettings({ enableAgentComputerAccess: Boolean(checked) })
            }
          />
        }
      />
      <SettingsRow
        {...searchableSetting("computer-all-apps")}
        serverScoped
        settingKeys={["computerUseAllowAllApps"]}
        description="Let agents open, read and control any macOS app on this environment's machine, including newly installed apps. No per-app approval is needed. Turn this off to use the app list below."
        control={
          <ScopedSwitch
            settingKeys={["computerUseAllowAllApps"]}
            checked={settings.computerUseAllowAllApps}
            aria-label="Allow all computer apps"
            onCheckedChange={(checked) =>
              updateSettings({ computerUseAllowAllApps: Boolean(checked) })
            }
          />
        }
      />
      <SettingsRow
        {...searchableSetting("computer-allowed-apps")}
        serverScoped
        settingKeys={["computerUseAllowedApps"]}
        description="Used when Allow all computer apps is off. Enter exact app names, separated by commas. An empty list permits no apps."
        control={
          <DraftInput
            aria-label="Allowed computer apps"
            disabled={settings.computerUseAllowAllApps}
            value={settings.computerUseAllowedApps.join(", ")}
            placeholder="Calculator, TextEdit"
            onCommit={(value) =>
              updateSettings({
                computerUseAllowedApps: [
                  ...new Set(
                    value
                      .split(",")
                      .map((name) => name.trim())
                      .filter(Boolean),
                  ),
                ],
              })
            }
          />
        }
      />
      <SettingsRow
        {...searchableSetting("computer-screen-capture")}
        serverScoped
        settingKeys={["enableComputerScreenCapture"]}
        description="Let agents capture a window of an allowed app, even behind other windows. Both this switch and macOS Screen Recording permission must be enabled. Keep this off for text-only control."
        control={
          <ScopedSwitch
            settingKeys={["enableComputerScreenCapture"]}
            checked={settings.enableComputerScreenCapture}
            aria-label="Allow computer screen captures"
            onCheckedChange={(checked) =>
              updateSettings({ enableComputerScreenCapture: Boolean(checked) })
            }
          />
        }
      />
      <SettingsRow
        {...searchableSetting("computer-pointer-takeover")}
        serverScoped
        settingKeys={["enableComputerPointerTakeover"]}
        description="For the rare control that ignores background input, an agent may use your real pointer for one gesture after you idle a few seconds, then restore your pointer and front app. If you're active, it asks."
        control={
          <ScopedSwitch
            settingKeys={["enableComputerPointerTakeover"]}
            checked={settings.enableComputerPointerTakeover}
            aria-label="Let agents briefly take over the pointer when you're idle"
            onCheckedChange={(checked) =>
              updateSettings({ enableComputerPointerTakeover: Boolean(checked) })
            }
          />
        }
      />
    </SettingsSection>
  );
}
