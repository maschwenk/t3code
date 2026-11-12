import type { VoiceTranscriber } from "@t3tools/client-runtime/voice-input";

/** "system" is Apple's or Google's built-in speech; Parakeet runs only on iOS. */
export type OnDeviceVoiceEngine = "system" | "parakeet";

export async function getLocalVoiceTranscriber(
  _engine: OnDeviceVoiceEngine = "system",
): Promise<VoiceTranscriber | null> {
  return null;
}
