import * as Speech from "expo-speech";
import { useSyncExternalStore } from "react";
import { Platform, Settings } from "react-native";

import {
  acquireAudioSession,
  activateAudioSession,
  isAudioSessionOwner,
  releaseAudioSession,
} from "../../lib/audioSession";
import { markdownToSpeechText, pickReadAloudVoice, splitSpeechText } from "./readAloudModel";

interface Reading {
  readonly scope: string;
  readonly key: string;
  readonly token: ReturnType<typeof acquireAudioSession>;
}

let reading: Reading | null = null;
let lastStop: Promise<unknown> = Promise.resolve();
const listeners = new Set<() => void>();

function publish(next: Reading | null): void {
  reading = next;
  for (const listener of listeners) listener();
}

function finish(current: Reading): void {
  if (reading !== current) return;
  publish(null);
  // The session is released after the synthesizer stops so other audio comes back up.
  lastStop = Speech.stop()
    .catch(() => {})
    .then(() => releaseAudioSession(current.token))
    .catch(() => {});
}

function preferredLocale(): string {
  // The app ships in English only, so Intl reports English even for other system languages.
  const languages: unknown = Settings.get("AppleLanguages");
  const first = Array.isArray(languages) ? languages[0] : undefined;
  return typeof first === "string" ? first : Intl.DateTimeFormat().resolvedOptions().locale;
}

async function voiceOptions(): Promise<Speech.SpeechOptions> {
  // Android engines rate nearly every voice as enhanced; their default is the one picked in system settings.
  if (Platform.OS !== "ios") return {};
  const locale = preferredLocale();
  const voices = await Speech.getAvailableVoicesAsync().catch(() => []);
  const voice = pickReadAloudVoice(voices, locale);
  return voice ? { voice } : { language: locale };
}

async function speak(current: Reading, text: string): Promise<void> {
  const [options] = await Promise.all([voiceOptions(), lastStop]);
  if (!(await activateAudioSession(current.token)) || reading !== current) return;
  const chunks = splitSpeechText(text, Speech.maxSpeechInputLength);
  const end = () => finish(current);
  chunks.forEach((chunk, index) => {
    Speech.speak(chunk, {
      ...options,
      ...(index === chunks.length - 1 ? { onDone: end } : {}),
      onStopped: end,
      onError: end,
    });
  });
}

/** Speaks a reply, or stops it when it is already speaking. One reply speaks at a time. */
export function toggleReadAloud(scope: string, key: string, markdown: string): void {
  const previous = reading;
  if (previous) finish(previous);
  if (previous?.scope === scope && previous.key === key) return;
  const text = markdownToSpeechText(markdown);
  if (!text) return;
  // Recording keeps the session, and anything that takes it later stops the speech.
  const current: Reading = {
    scope,
    key,
    token: acquireAudioSession("speech", () => finish(current)),
  };
  if (!isAudioSessionOwner(current.token)) return;
  publish(current);
  speak(current, text).catch(() => finish(current));
}

/** Stops speech that started from the scope, such as a thread the reader is leaving. */
export function stopReadAloud(scope: string): void {
  if (reading?.scope === scope) finish(reading);
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export function useReadingAloud(scope: string, key: string): boolean {
  return useSyncExternalStore(subscribe, () => reading?.scope === scope && reading.key === key);
}
