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
        description="Let agents inspect and operate allowed macOS apps on this environment's machine, including when you connect remotely. Moves the visible system cursor while operating the foreground app. Requires macOS Accessibility permission. Turning this off blocks the next tool call."
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
        description="Let agents capture the foreground app window. Images can include overlapping windows and sensitive content. Requires macOS Screen Recording permission. Keep this off for text-only control."
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
    </SettingsSection>
  );
}
