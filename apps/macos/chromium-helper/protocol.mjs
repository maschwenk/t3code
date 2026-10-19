import * as NodeCrypto from "node:crypto";
import * as NodeFSP from "node:fs/promises";
import * as NodePath from "node:path";
import * as NodeOS from "node:os";

export const ONE_PASSWORD_ID = "aeblfdkhhhdcdjpifhhbdiojplfjncoa";
export const WIRE_PREFIX = "T3CHROMIUM ";
export function pageURL(value) {
  if (value === "about:blank") return value;
  if (typeof value !== "string" || value.length > 16384) throw new Error("Invalid page URL.");
  const url = new URL(value);
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) {
    throw new Error("Only HTTP(S) pages without URL credentials are allowed.");
  }
  return url.href;
}
export function identity(value) {
  if (
    typeof value !== "string" ||
    !value.length ||
    value.length > 512 ||
    value.split("").some((character) => character.charCodeAt(0) < 32)
  ) {
    throw new Error("Invalid browser identity.");
  }
  return value;
}
export function authenticated(value, token) {
  if (typeof value !== "string" || !/^[a-f0-9]{64}$/.test(value) || !/^[a-f0-9]{64}$/.test(token))
    return false;
  return NodeCrypto.timingSafeEqual(Buffer.from(value, "hex"), Buffer.from(token, "hex"));
}
export class CommandDecoder {
  #buffer = "";
  constructor(token) {
    this.token = token;
  }
  push(chunk) {
    this.#buffer += chunk;
    if (Buffer.byteLength(this.#buffer) > 1024 * 1024)
      throw new Error("Helper command exceeds the limit.");
    const result = [];
    let end;
    while ((end = this.#buffer.indexOf("\n")) >= 0) {
      const line = this.#buffer.slice(0, end);
      this.#buffer = this.#buffer.slice(end + 1);
      const value = JSON.parse(line);
      if (!authenticated(value.token, this.token))
        throw new Error("Unauthenticated helper command.");
      identity(value.id);
      identity(value.method);
      result.push(value);
    }
    return result;
  }
}
export async function stateDirectory(value) {
  const allowed = NodePath.join(NodeOS.homedir(), "Library/Application Support/T3Native/Chromium");
  const root = NodePath.resolve(value ?? allowed);
  if (root !== NodePath.resolve(allowed))
    throw new Error("The helper requires its managed Chromium state directory.");
  await NodeFSP.mkdir(root, { recursive: true, mode: 0o700 });
  if ((await NodeFSP.realpath(root)) !== root)
    throw new Error("The Chromium state directory cannot be a symlink.");
  return root;
}
export async function selectedProfile(root, selection) {
  if (
    typeof selection !== "string" ||
    !selection ||
    selection.includes("/") ||
    selection.includes("\\") ||
    selection === "." ||
    selection === ".."
  ) {
    throw new Error("Select an existing browser profile.");
  }
  const canonicalRoot = await NodeFSP.realpath(root);
  const candidate = await NodeFSP.realpath(NodePath.join(canonicalRoot, selection));
  const part = NodePath.relative(canonicalRoot, candidate);
  if (part.startsWith("..") || NodePath.isAbsolute(part) || !part)
    throw new Error("The selected profile is outside its browser.");
  return candidate;
}
