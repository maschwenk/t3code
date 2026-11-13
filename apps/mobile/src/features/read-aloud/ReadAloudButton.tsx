import type { EnvironmentId } from "@t3tools/contracts";
import { useAtomValue } from "@effect/atom-react";
import * as Haptics from "expo-haptics";
import { memo } from "react";
import { Pressable, type ColorValue } from "react-native";

import { SymbolView } from "../../components/ui/AppSymbol";
import { readAloudConnectionAtom } from "../voice-input/voiceDestination";
import { stopReadAloud, toggleReadAloud, useReadingAloud } from "./readAloud";

export const ReadAloudButton = memo(function ReadAloudButton(props: {
  readonly environmentId: EnvironmentId;
  readonly scope: string;
  readonly messageId: string;
  readonly markdown: string;
  readonly tintColor: ColorValue;
  readonly buttonSize: number;
  readonly iconSize: number;
}) {
  const speaking = useReadingAloud(props.scope, props.messageId);
  // The environment machine speaks; one without a voice offers no button. A reply that is
  // already speaking keeps its stop button through a reconnect.
  const prepared = useAtomValue(readAloudConnectionAtom(props.environmentId));
  if (!prepared && !speaking) return null;
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={speaking ? "Stop reading aloud" : "Read aloud"}
      hitSlop={8}
      onPress={() => {
        void Haptics.selectionAsync();
        if (prepared) toggleReadAloud(props.scope, props.messageId, props.markdown, prepared);
        else stopReadAloud(props.scope);
      }}
      style={({ pressed }) => ({
        width: props.buttonSize,
        height: props.buttonSize,
        alignItems: "center",
        justifyContent: "center",
        opacity: pressed ? 0.52 : 1,
      })}
    >
      <SymbolView
        name={speaking ? "stop.fill" : "speaker.wave.2"}
        size={props.iconSize}
        tintColor={props.tintColor}
        type="monochrome"
      />
    </Pressable>
  );
});
