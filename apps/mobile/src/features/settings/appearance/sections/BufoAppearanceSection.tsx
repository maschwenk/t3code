import { useAtomSet, useAtomValue } from "@effect/atom-react";
import { AsyncResult } from "effect/reactivity";

import { mobilePreferencesAtom, updateMobilePreferencesAtom } from "../../../../state/preferences";
import { SettingsSection } from "../../components/SettingsSection";
import { SettingsSwitchRow } from "../../components/SettingsSwitchRow";

export function BufoAppearanceSection() {
  const savePreferences = useAtomSet(updateMobilePreferencesAtom);
  const preferences = useAtomValue(mobilePreferencesAtom);
  const loaded = AsyncResult.isSuccess(preferences);

  return (
    <SettingsSection title="Header">
      <SettingsSwitchRow
        icon="face.smiling"
        label="Bufo mode"
        subtitle="Bufos take the place of the T3 Code wordmark. A new set each launch."
        value={loaded && preferences.value.bufoMode === true}
        disabled={!loaded}
        onValueChange={(value) => savePreferences({ bufoMode: value })}
      />
    </SettingsSection>
  );
}
