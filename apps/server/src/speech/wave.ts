/** 16-bit mono PCM WAV, which every client can play without a decoder. */
function waveFile(dataBytes: number, sampleRate: number) {
  const bytes = new Uint8Array(44 + dataBytes);
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
  view.setUint32(40, dataBytes, true);
  return { bytes, view };
}

export function encodeWave(samples: Float32Array, sampleRate: number): Uint8Array {
  const { bytes, view } = waveFile(samples.length * 2, sampleRate);
  for (let index = 0; index < samples.length; index += 1) {
    const sample = Math.max(-1, Math.min(1, samples[index] ?? 0));
    view.setInt16(44 + index * 2, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true);
  }
  return bytes;
}

export function wrapPcm16(pcm: Uint8Array, sampleRate: number): Uint8Array {
  const { bytes } = waveFile(pcm.byteLength, sampleRate);
  bytes.set(pcm, 44);
  return bytes;
}
