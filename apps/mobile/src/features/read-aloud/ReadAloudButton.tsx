import * as Haptics from "expo-haptics";
import { memo } from "react";
import { Pressable, type ColorValue } from "react-native";

import { SymbolView } from "../../components/ui/AppSymbol";
import { toggleReadAloud, useReadingAloud } from "./readAloud";

export const ReadAloudButton = memo(function ReadAloudButton(props: {
  readonly scope: string;
  readonly messageId: string;
  readonly markdown: string;
  readonly tintColor: ColorValue;
  readonly buttonSize: number;
  readonly iconSize: number;
}) {
  const speaking = useReadingAloud(props.scope, props.messageId);
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={speaking ? "Stop reading aloud" : "Read aloud"}
      hitSlop={8}
      onPress={() => {
        void Haptics.selectionAsync();
        toggleReadAloud(props.scope, props.messageId, props.markdown);
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
