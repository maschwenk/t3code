import * as NodeServices from "@effect/platform-node/NodeServices";
import { it } from "@effect/vitest";
import * as SecureRandom from "effect/crypto/SecureRandom";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { expect, vi } from "vite-plus/test";

import * as ServerConfig from "../config.ts";
import * as CloudSpeech from "./CloudSpeech.ts";
import * as SpeechModelStore from "./SpeechModelStore.ts";
import * as SpeechSynthesis from "./SpeechSynthesis.ts";

it.effect("reads aloud with ElevenLabs as 24 kHz WAV without fetching the local voice", () =>
  Effect.gen(function* () {
    const download = vi.fn(() => Effect.die("the local voice must not download"));
    const speak = vi.fn(() =>
      Effect.succeed({ pcm: new Uint8Array([1, 0, 255, 127]), sampleRate: 24_000 }),
    );
    const synthesis = yield* SpeechSynthesis.SpeechSynthesis.pipe(
      Effect.provide(
        SpeechSynthesis.layer.pipe(
          Layer.provide(
            Layer.mock(CloudSpeech.CloudSpeech)({
              configured: Effect.succeed({
                openai: false,
                xai: false,
                openrouter: false,
                elevenlabs: true,
              }),
              speak,
            }),
          ),
          Layer.provide(Layer.mock(SpeechModelStore.SpeechModelStore)({ download })),
          Layer.provide(
            Layer.succeed(
              SecureRandom.SecureRandom,
              SecureRandom.make((size) => new Uint8Array(size)),
            ),
          ),
          Layer.provide(ServerConfig.layerTest(process.cwd(), { prefix: "t3-speech-synthesis-" })),
          Layer.provide(NodeServices.layer),
        ),
      ),
    );
    const request = { text: "Ready for review.", nextText: "Open it?" };
    const wav = yield* synthesis.speak(request);
    expect(speak).toHaveBeenCalledWith(request);
    const view = new DataView(wav.buffer, wav.byteOffset, wav.byteLength);
    expect(new TextDecoder().decode(wav.subarray(0, 4))).toBe("RIFF");
    expect(view.getUint32(24, true)).toBe(24_000);
    expect(view.getUint32(40, true)).toBe(4);
    expect([...wav.subarray(44)]).toEqual([1, 0, 255, 127]);
    expect(download).not.toHaveBeenCalled();
  }),
);
