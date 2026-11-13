import type { PreparedConnection } from "@t3tools/client-runtime/connection";
import { speakEnvironmentText } from "@t3tools/client-runtime/voice-input";
import { SPEECH_SYNTHESIS_MAX_CHARS } from "@t3tools/contracts";
import { createAudioPlayer, type AudioPlayer } from "expo-audio";
import { File, Paths } from "expo-file-system";
import { useSyncExternalStore } from "react";

import {
  acquireAudioSession,
  activateAudioSession,
  disposeAudioPlayer,
  isAudioSessionOwner,
  releaseAudioSession,
} from "../../lib/audioSession";
import { uuidv4 } from "../../lib/uuid";
import { runSpeech } from "../voice-input/voiceDestination";
import { markdownToSpeechText, splitSpeechText } from "./readAloudModel";

// The environment speaks one piece at a time, so a short queue keeps it busy without
// synthesizing a long reply nobody stays to hear.
const PIECES_AHEAD = 2;
const MAX_PIECE_CHARS = Math.min(400, SPEECH_SYNTHESIS_MAX_CHARS);

interface Reading {
  readonly scope: string;
  readonly key: string;
  readonly token: ReturnType<typeof acquireAudioSession>;
  readonly abort: AbortController;
  player: AudioPlayer | null;
}

let reading: Reading | null = null;
const listeners = new Set<() => void>();

function publish(next: Reading | null): void {
  reading = next;
  for (const listener of listeners) listener();
}

function finish(current: Reading): void {
  if (reading !== current) return;
  publish(null);
  current.abort.abort();
  const player = current.player;
  current.player = null;
  // Releasing first lets the player's pause end the session, so ducked audio comes back up.
  void releaseAudioSession(current.token)
    .catch(() => {})
    .finally(() => {
      if (player) disposeAudioPlayer(player);
    });
}

function deleteQuietly(file: File): void {
  try {
    file.delete();
  } catch {}
}

function playToEnd(current: Reading, uri: string): Promise<void> {
  const player = current.player ?? createAudioPlayer(null);
  current.player = player;
  return new Promise((resolve) => {
    const subscription = player.addListener("playbackStatusUpdate", (status) => {
      if (status.didJustFinish || reading !== current) done();
    });
    const stop = () => done();
    current.abort.signal.addEventListener("abort", stop);
    function done() {
      subscription.remove();
      current.abort.signal.removeEventListener("abort", stop);
      resolve();
    }
    player.replace({ uri });
    player.play();
  });
}

async function speak(current: Reading, prepared: PreparedConnection, text: string): Promise<void> {
  const pieces = splitSpeechText(text, MAX_PIECE_CHARS);
  const files: Promise<File>[] = [];
  const fetchPiece = (index: number) =>
    (files[index] ??= runSpeech(
      speakEnvironmentText(prepared, pieces[index]!),
      current.abort.signal,
    ).then(async (audio) => {
      const file = new File(Paths.cache, `read-aloud-${uuidv4()}.wav`);
      await file.write(audio);
      return file;
    }));
  try {
    for (let index = 0; index < pieces.length; index += 1) {
      for (let ahead = index; ahead <= index + PIECES_AHEAD && ahead < pieces.length; ahead += 1)
        void fetchPiece(ahead).catch(() => {});
      const file = await fetchPiece(index);
      // Activate once the first audio exists, so music is not ducked during a long first download.
      if (index === 0 && !(await activateAudioSession(current.token))) return;
      if (reading !== current) return;
      await playToEnd(current, file.uri);
      if (reading !== current) return;
    }
  } finally {
    finish(current);
    for (const file of files) void file?.then(deleteQuietly, () => {});
  }
}

/** Speaks a reply, or stops it when it is already speaking. One reply speaks at a time. */
export function toggleReadAloud(
  scope: string,
  key: string,
  markdown: string,
  prepared: PreparedConnection,
): void {
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
    abort: new AbortController(),
    player: null,
  };
  if (!isAudioSessionOwner(current.token)) return;
  publish(current);
  speak(current, prepared, text).catch(() => finish(current));
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
