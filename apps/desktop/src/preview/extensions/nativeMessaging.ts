/**
 * Chrome's native messaging protocol: each message is UTF-8 JSON prefixed
 * with its byte length as a 32-bit little-endian integer (the native byte
 * order on every platform Chrome supports).
 */

/** Chrome's limit for a single message from the host. */
export const MAX_HOST_MESSAGE_BYTES = 1024 * 1024;

export function encodeNativeMessage(message: unknown): Uint8Array {
  const body = new TextEncoder().encode(JSON.stringify(message));
  const frame = new Uint8Array(4 + body.length);
  new DataView(frame.buffer).setUint32(0, body.length, true);
  frame.set(body, 4);
  return frame;
}

export class NativeMessageDecoder {
  #pending = new Uint8Array(0);

  /** The complete messages so far. Throws on a frame larger than Chrome allows. */
  push(chunk: Uint8Array): ReadonlyArray<unknown> {
    const joined = new Uint8Array(this.#pending.length + chunk.length);
    joined.set(this.#pending);
    joined.set(chunk, this.#pending.length);
    const messages: Array<unknown> = [];
    let offset = 0;
    while (joined.length - offset >= 4) {
      const length = new DataView(joined.buffer, offset, 4).getUint32(0, true);
      if (length > MAX_HOST_MESSAGE_BYTES) {
        throw new Error(`Native host message of ${length} bytes exceeds the 1 MB limit.`);
      }
      if (joined.length - offset - 4 < length) break;
      const body = joined.subarray(offset + 4, offset + 4 + length);
      messages.push(JSON.parse(new TextDecoder().decode(body)));
      offset += 4 + length;
    }
    this.#pending = joined.slice(offset);
    return messages;
  }
}

export interface NativeHostManifest {
  readonly name: string;
  readonly path: string;
  readonly type: string;
  readonly allowed_origins?: ReadonlyArray<string>;
}

/**
 * Where Chromium browsers look for host manifests, user directories first.
 * Hosts register with a particular browser; reading the common browsers'
 * directories lets a host installed for any of them work here too.
 */
export function nativeHostManifestDirectories(
  platform: string,
  home: string,
): ReadonlyArray<string> {
  if (platform === "darwin") {
    const support = `${home}/Library/Application Support`;
    return [
      `${support}/Google/Chrome/NativeMessagingHosts`,
      `${support}/Chromium/NativeMessagingHosts`,
      `${support}/Microsoft Edge/NativeMessagingHosts`,
      `${support}/BraveSoftware/Brave-Browser/NativeMessagingHosts`,
      "/Library/Google/Chrome/NativeMessagingHosts",
      "/Library/Application Support/Chromium/NativeMessagingHosts",
      "/Library/Microsoft/Edge/NativeMessagingHosts",
    ];
  }
  if (platform === "linux") {
    return [
      `${home}/.config/google-chrome/NativeMessagingHosts`,
      `${home}/.config/chromium/NativeMessagingHosts`,
      `${home}/.config/microsoft-edge/NativeMessagingHosts`,
      `${home}/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts`,
      "/etc/opt/chrome/native-messaging-hosts",
      "/etc/chromium/native-messaging-hosts",
    ];
  }
  return [];
}

/** Host names are dot-separated lowercase identifiers; anything else could leave the directory. */
export const isValidNativeHostName = (name: string): boolean =>
  /^[a-z0-9_]+(\.[a-z0-9_]+)*$/.test(name);

/** Whether a host manifest lets this extension connect, as Chrome checks it. */
export function nativeHostAllows(
  manifest: NativeHostManifest,
  extensionId: string,
  name: string,
): boolean {
  return (
    manifest.name === name &&
    manifest.type === "stdio" &&
    (manifest.allowed_origins ?? []).includes(`chrome-extension://${extensionId}/`)
  );
}
