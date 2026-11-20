import { Image } from "expo-image";
import { View } from "react-native";

// From the community bufo emoji set (github.com/knobiknows/all-the-bufo), 112–128 px each.
const BUFOS = [
  require("../../assets/bufo/bufo-celebrate.png"),
  require("../../assets/bufo/bufo-coffee-happy.png"),
  require("../../assets/bufo/bufo-hearts.png"),
  require("../../assets/bufo/bufo-hype.gif"),
  require("../../assets/bufo/bufo-jam.gif"),
  require("../../assets/bufo/bufo-lgtm.png"),
  require("../../assets/bufo/bufo-nod.gif"),
  require("../../assets/bufo/bufo-party.gif"),
  require("../../assets/bufo/bufo-run.gif"),
] as const;

const PARADE_LENGTH = 3;

function pickBufos(): ReadonlyArray<(typeof BUFOS)[number]> {
  const shuffled = [...BUFOS];
  for (let index = shuffled.length - 1; index > 0; index -= 1) {
    const other = Math.floor(Math.random() * (index + 1));
    [shuffled[index], shuffled[other]] = [shuffled[other]!, shuffled[index]!];
  }
  return shuffled.slice(0, PARADE_LENGTH);
}

// One parade per launch, so headers that remount on navigation keep the same bufos.
const LAUNCH_PARADE = pickBufos();

/** Bufo mode's stand-in for the T3 Code wordmark. */
export function BufoParade(props: { readonly size: number }) {
  return (
    <View className="flex-row items-center" style={{ gap: props.size * 0.1 }}>
      {LAUNCH_PARADE.map((bufo) => (
        <Image
          // A parade never repeats a bufo, so the asset reference is a unique key.
          key={String(bufo)}
          source={bufo}
          contentFit="contain"
          style={{ width: props.size, height: props.size }}
        />
      ))}
    </View>
  );
}
