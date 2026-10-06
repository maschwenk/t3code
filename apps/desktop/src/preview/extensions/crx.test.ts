// @effect-diagnostics nodeBuiltinImport:off -- Test fixtures generate keys and signatures with Node's crypto.
import * as NodeCrypto from "node:crypto";

import { describe, expect, it } from "vite-plus/test";

import { CrxFormatError, extensionIdFromPublicKey, manifestKeyFor, parseCrx } from "./crx.ts";

// 1Password's public manifest key, from its published extension.
const ONE_PASSWORD_KEY =
  "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnHpaUll4uWujpAdbIXOQY2WE6hk8PllsYsnoUaj5qHXwv4IB6A9pONqGaTL2KL20u6E6XVhncY6Ae6SQSBQqiIkgjPsiG0NDNsDlju/kzBnfimKFC/bpzOrqFqbhswQHifnet5uHlpG97whTzLO3ka0M5aqB9V9mD/0qVXvNgAVVnSTULH254YqpeCcAhmsKiFZSL6OrOZmCp8kZ/OeOUK9iYWYylL7VcOXVrZf10EPrlaCNXzVk7K35dPuQ7svhA0Pgju3kngB4RLa5Iojhw3IT+B5+m8pisjOSd1oKMrRmhGs7rDhF5IEtAiVxqVp7uOOMPQj3vrbMDAzf7vqLtQIDAQAB";

const varint = (value: number): Array<number> => {
  const bytes: Array<number> = [];
  while (value > 0x7f) {
    bytes.push((value & 0x7f) | 0x80);
    value = Math.floor(value / 128);
  }
  bytes.push(value);
  return bytes;
};
const field = (number: number, value: Uint8Array) =>
  Uint8Array.from([...varint(number * 8 + 2), ...varint(value.length), ...value]);
const concat = (...parts: ReadonlyArray<Uint8Array>) => {
  const out = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
};
const uint32 = (value: number) => {
  const bytes = new Uint8Array(4);
  new DataView(bytes.buffer).setUint32(0, value, true);
  return bytes;
};

describe("extension packages", () => {
  it("derives Chrome's extension id from a manifest key", () => {
    expect(extensionIdFromPublicKey(Buffer.from(ONE_PASSWORD_KEY, "base64"))).toBe(
      "aeblfdkhhhdcdjpifhhbdiojplfjncoa",
    );
  });

  it("reads the archive and keys of a CRX3 package", () => {
    const { publicKey } = NodeCrypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
    const der = new Uint8Array(publicKey.export({ type: "spki", format: "der" }));
    const proof = concat(field(1, der), field(2, Uint8Array.from([1, 2, 3])));
    // An unrelated field before the key proof, as real headers carry signed data.
    const header = concat(field(10000, Uint8Array.from([9, 9])), field(2, proof));
    const archive = new TextEncoder().encode("PK\u0003\u0004 zip bytes");
    const crx = concat(
      new TextEncoder().encode("Cr24"),
      uint32(3),
      uint32(header.length),
      header,
      archive,
    );

    const parsed = parseCrx(crx);

    expect([...parsed.archive]).toEqual([...archive]);
    expect(parsed.publicKeys.map((key) => [...key])).toEqual([[...der]]);
    const id = extensionIdFromPublicKey(der);
    expect(manifestKeyFor(parsed, id)).toBe(Buffer.from(der).toString("base64"));
    expect(manifestKeyFor(parsed, "a".repeat(32))).toBeUndefined();
  });

  it("rejects files that are not extension packages", () => {
    expect(() => parseCrx(new TextEncoder().encode("PK\u0003\u0004"))).toThrow(CrxFormatError);
  });
});
