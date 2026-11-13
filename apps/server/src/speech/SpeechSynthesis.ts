// @effect-diagnostics nodeBuiltinImport:off - sherpa-onnx is a CommonJS native addon and its model ships as a tar.bz2.
import * as NodeChildProcess from "node:child_process";
import * as NodeModule from "node:module";
import * as NodeUtil from "node:util";
import * as HostProcess from "@t3tools/shared/HostProcess";
import * as Context from "effect/Context";
import * as SecureRandom from "effect/crypto/SecureRandom";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import * as Semaphore from "effect/Semaphore";

import * as ServerConfig from "../config.ts";
import * as SpeechModelStore from "./SpeechModelStore.ts";
import { SpeechOperationError, SpeechUnsupportedPlatformError } from "./SpeechService.ts";

const execFile = NodeUtil.promisify(NodeChildProcess.execFile);
const requireNative = NodeModule.createRequire(import.meta.url);

// Kokoro v1.0 (int8) packaged for sherpa-onnx. sherpa-onnx-node stays on 1.x: 2.x dropped
// espeak-ng and silently skips any word missing from the lexicon, numbers included.
const KOKORO_ARCHIVE = {
  id: "k2-fsa/sherpa-onnx",
  revision: "tts-models",
  filename: "kokoro-int8-multi-lang-v1_0.tar.bz2",
  size: 132_353_410,
  sha256: "72c347230107ef8a31098ec4d468a605244beef5f1ed00db97efa13518800653",
  url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_0.tar.bz2",
};
const KOKORO_DIRECTORY = "kokoro-int8-multi-lang-v1_0";
// af_heart in the model's speaker2id table.
const HEART_SPEAKER_ID = 3;

interface KokoroVoice {
  generateAsync(request: {
    readonly text: string;
    readonly sid: number;
    readonly speed: number;
  }): Promise<{ readonly samples: Float32Array; readonly sampleRate: number }>;
}

interface SherpaOnnx {
  readonly OfflineTts: { createAsync(config: object): Promise<KokoroVoice> };
}

/** 16-bit mono PCM WAV, which every client can play without a decoder. */
function encodeWave(samples: Float32Array, sampleRate: number): Uint8Array {
  const bytes = new Uint8Array(44 + samples.length * 2);
  const view = new DataView(bytes.buffer);
  const tag = (at: number, value: string) => bytes.set(new TextEncoder().encode(value), at);
  tag(0, "RIFF");
  view.setUint32(4, bytes.length - 8, true);
  tag(8, "WAVE");
  tag(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  tag(36, "data");
  view.setUint32(40, samples.length * 2, true);
  for (let index = 0; index < samples.length; index += 1) {
    const sample = Math.max(-1, Math.min(1, samples[index] ?? 0));
    view.setInt16(44 + index * 2, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true);
  }
  return bytes;
}

export class SpeechSynthesis extends Context.Service<
  SpeechSynthesis,
  {
    /** Speaks text in Kokoro's Heart voice as WAV, downloading the model on first use. */
    readonly speak: (
      text: string,
    ) => Effect.Effect<Uint8Array, SpeechOperationError | SpeechUnsupportedPlatformError>;
  }
>()("t3/speech/SpeechSynthesis") {}

const make = Effect.gen(function* () {
  const fs = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const random = yield* SecureRandom.SecureRandom;
  const store = yield* SpeechModelStore.SpeechModelStore;
  const config = yield* ServerConfig.ServerConfig;
  const platform = yield* HostProcess.Platform;
  const architecture = yield* HostProcess.Architecture;
  const models = path.join(config.stateDir, "speech", "models");
  const modelDirectory = path.join(models, KOKORO_DIRECTORY);
  const unpackedMarker = path.join(modelDirectory, ".unpacked");
  // One generation at a time; each one already spreads across cores.
  const lock = yield* Semaphore.make(1);
  let voice: KokoroVoice | undefined;

  const failed = (operation: string) => (cause: unknown) =>
    new SpeechOperationError({ operation, cause });

  const unpack = Effect.fn("SpeechSynthesis.unpack")(function* () {
    const marker = yield* fs.readFileString(unpackedMarker).pipe(Effect.orElseSucceed(() => ""));
    if (marker === KOKORO_ARCHIVE.sha256) return;
    const archive = yield* store
      .download(KOKORO_ARCHIVE)
      .pipe(Effect.mapError(failed("voice download")));
    const staging = path.join(models, `${KOKORO_DIRECTORY}.${yield* random.uuidV4()}.tmp`);
    yield* Effect.gen(function* () {
      yield* fs.makeDirectory(staging, { recursive: true });
      yield* Effect.tryPromise({
        try: () => execFile("tar", ["-xjf", archive, "-C", staging]),
        catch: failed("voice unpack"),
      });
      yield* fs.remove(modelDirectory, { recursive: true, force: true });
      yield* fs.rename(path.join(staging, KOKORO_DIRECTORY), modelDirectory);
      yield* fs.writeFileString(unpackedMarker, KOKORO_ARCHIVE.sha256);
    }).pipe(
      Effect.mapError(failed("voice unpack")),
      Effect.ensuring(fs.remove(staging, { recursive: true, force: true }).pipe(Effect.ignore)),
    );
    yield* store.remove(KOKORO_ARCHIVE).pipe(Effect.ignore);
  });

  const load = Effect.fn("SpeechSynthesis.load")(function* () {
    if (voice) return voice;
    const sherpa = yield* Effect.try({
      try: () => requireNative("sherpa-onnx-node") as SherpaOnnx,
      catch: () => new SpeechUnsupportedPlatformError({ platform, architecture }),
    });
    yield* unpack();
    const file = (name: string) => path.join(modelDirectory, name);
    voice = yield* Effect.tryPromise({
      try: () =>
        sherpa.OfflineTts.createAsync({
          model: {
            kokoro: {
              model: file("model.int8.onnx"),
              voices: file("voices.bin"),
              tokens: file("tokens.txt"),
              lexicon: file("lexicon-us-en.txt"),
              dataDir: file("espeak-ng-data"),
              lang: "en-us",
            },
            numThreads: 4,
          },
        }),
      catch: failed("voice load"),
    });
    return voice;
  });

  return SpeechSynthesis.of({
    speak: Effect.fn("SpeechSynthesis.speak")((text: string) =>
      lock.withPermits(1)(
        Effect.gen(function* () {
          const loaded = yield* load();
          const audio = yield* Effect.tryPromise({
            try: () => loaded.generateAsync({ text, sid: HEART_SPEAKER_ID, speed: 1 }),
            catch: failed("synthesis"),
          });
          return encodeWave(audio.samples, audio.sampleRate);
        }),
      ),
    ),
  });
});

export const layer = Layer.effect(SpeechSynthesis, make);
