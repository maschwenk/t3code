import { RotatingFileSink, RotatingFileSinkError } from "@t3tools/shared/logging";
import * as Context from "effect/Context";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import * as Schema from "effect/Schema";

import * as ServerConfig from "../config.ts";
import { encodeWave } from "./wave.ts";

export const VOICE_LOG_FILE = "voice.ndjson";
export const VOICE_RECORDINGS_DIR = "voice-recordings";
// Server traces rotate within the hour; this keeps weeks of dictations at a few hundred bytes each.
const LOG_MAX_BYTES = 1024 * 1024;
const KEPT_RECORDINGS = 10;
const encodeLine = Schema.encodeUnknownEffect(Schema.fromJsonString(Schema.Unknown));

type VoiceLogValue = string | number | boolean | ReadonlyArray<number>;
export type VoiceLogFields = Readonly<Record<string, VoiceLogValue | undefined>>;

export class VoiceLog extends Context.Service<
  VoiceLog,
  {
    readonly record: (event: string, fields: VoiceLogFields) => Effect.Effect<void>;
    /** Saves the audio as WAV next to the log, keeping the newest few; returns the file name. */
    readonly keepRecording: (pcm: Float32Array) => Effect.Effect<string | undefined>;
  }
>()("t3/speech/VoiceLog") {}

const decibels = (value: number) => (value > 0 ? Math.round(200 * Math.log10(value)) / 10 : -120);

export function audioLevels(pcm: Float32Array) {
  let peak = 0;
  let energy = 0;
  for (const sample of pcm) {
    peak = Math.max(peak, Math.abs(sample));
    energy += sample * sample;
  }
  return {
    peakDb: decibels(peak),
    rmsDb: decibels(pcm.length ? Math.sqrt(energy / pcm.length) : 0),
  };
}

/** Why a transcription looks like it lost speech, or undefined when it looks whole. */
export function suspectedLoss(input: {
  readonly audioSeconds: number;
  readonly keptSeconds: number;
  readonly chars: number;
}): string | undefined {
  if (input.chars === 0 && input.keptSeconds >= 2) return "speech-without-text";
  if (input.keptSeconds >= 5 && input.chars / input.keptSeconds < 6) return "little-text";
  if (input.audioSeconds >= 30 && input.keptSeconds / input.audioSeconds < 0.25)
    return "mostly-dropped-as-silence";
  return undefined;
}

const make = Effect.gen(function* () {
  const { logsDir } = yield* ServerConfig.ServerConfig;
  const fileSystem = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const filePath = path.join(logsDir, VOICE_LOG_FILE);
  const recordingsDir = path.join(logsDir, VOICE_RECORDINGS_DIR);
  const sink = yield* Effect.try({
    try: () => new RotatingFileSink({ filePath, maxBytes: LOG_MAX_BYTES, maxFiles: 2 }),
    catch: (cause) => new RotatingFileSinkError({ operation: "initialize", filePath, cause }),
  }).pipe(
    Effect.catch((cause) =>
      Effect.logWarning("voice log unavailable", { filePath, cause }).pipe(Effect.as(undefined)),
    ),
  );

  return VoiceLog.of({
    record: Effect.fn("VoiceLog.record")(function* (event, fields) {
      if (!sink) return;
      const time = DateTime.formatIso(yield* DateTime.now);
      yield* encodeLine({ time, event, ...fields }).pipe(
        Effect.map((line) => sink.write(`${line}\n`)),
        Effect.catch((cause) => Effect.logWarning("voice log entry not written", { event, cause })),
      );
    }),
    keepRecording: Effect.fn("VoiceLog.keepRecording")(function* (pcm) {
      const name = `${DateTime.formatIso(yield* DateTime.now).replaceAll(":", "-")}.wav`;
      return yield* Effect.gen(function* () {
        yield* fileSystem.makeDirectory(recordingsDir, { recursive: true });
        yield* fileSystem.writeFile(path.join(recordingsDir, name), encodeWave(pcm, 16_000));
        const recordings = (yield* fileSystem.readDirectory(recordingsDir))
          .filter((entry) => entry.endsWith(".wav"))
          .toSorted();
        yield* Effect.forEach(
          recordings.slice(0, Math.max(0, recordings.length - KEPT_RECORDINGS)),
          (entry) => fileSystem.remove(path.join(recordingsDir, entry)),
          { discard: true },
        );
        return name;
      }).pipe(
        Effect.catch((cause) =>
          Effect.logWarning("voice recording could not be kept", { recordingsDir, cause }).pipe(
            Effect.as(undefined),
          ),
        ),
      );
    }),
  });
});

export const layer = Layer.effect(VoiceLog, make);
