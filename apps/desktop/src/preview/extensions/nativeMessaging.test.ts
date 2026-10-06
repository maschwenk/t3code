import { describe, expect, it } from "vite-plus/test";

import {
  MAX_HOST_MESSAGE_BYTES,
  NativeMessageDecoder,
  encodeNativeMessage,
  nativeHostAllows,
} from "./nativeMessaging.ts";

describe("native messaging", () => {
  it("decodes messages split across arbitrary chunks", () => {
    const frames = [
      encodeNativeMessage({ type: "hello", text: "héllo" }),
      encodeNativeMessage([1, 2, 3]),
    ];
    const stream = new Uint8Array([...frames[0]!, ...frames[1]!]);
    const decoder = new NativeMessageDecoder();
    const received: Array<unknown> = [];
    for (let offset = 0; offset < stream.length; offset += 3) {
      received.push(...decoder.push(stream.subarray(offset, offset + 3)));
    }
    expect(received).toEqual([{ type: "hello", text: "héllo" }, [1, 2, 3]]);
  });

  it("refuses a frame larger than Chrome allows", () => {
    const header = new Uint8Array(4);
    new DataView(header.buffer).setUint32(0, MAX_HOST_MESSAGE_BYTES + 1, true);
    expect(() => new NativeMessageDecoder().push(header)).toThrow(/1 MB/);
  });

  it("only lets extensions the host lists connect", () => {
    const manifest = {
      name: "com.example.host",
      path: "/bin/host",
      type: "stdio",
      allowed_origins: ["chrome-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/"],
    };
    expect(nativeHostAllows(manifest, "aeblfdkhhhdcdjpifhhbdiojplfjncoa", "com.example.host")).toBe(
      true,
    );
    expect(nativeHostAllows(manifest, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "com.example.host")).toBe(
      false,
    );
    expect(
      nativeHostAllows(manifest, "aeblfdkhhhdcdjpifhhbdiojplfjncoa", "com.example.other"),
    ).toBe(false);
  });
});
