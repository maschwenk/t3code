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
        description="Let agents inspect and operate allowed macOS apps on this environment's machine, including when you connect remotely. Accessibility controls work in the background with an agent cursor. Other gestures follow the pointer setting below. Requires macOS Accessibility permission. Turning this off stops further actions."
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
        {...searchableSetting("computer-allowed-apps")}
        serverScoped
        settingKeys={["computerUseAllowedApps"]}
        description="Exact names of running apps, separated by commas. Start with Calculator or a test app. An empty list permits no apps."
        control={
          <DraftInput
            aria-label="Allowed computer apps"
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
        description="Hovering, double-clicking, dragging and clicking inside canvases need the real pointer. When you have not touched the mouse or keyboard for a few seconds, agents may bring the app forward for that one gesture, then put your pointer and front app back. If you are active, the agent waits and asks instead."
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
