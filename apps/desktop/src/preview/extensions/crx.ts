// @effect-diagnostics nodeBuiltinImport:off -- Synchronous hashing for the extension id outside any Effect runtime.
import * as NodeCrypto from "node:crypto";

/**
 * Chrome Web Store packages (CRX2 and CRX3): a signed header followed by a
 * ZIP archive. Only what installation needs is read: the archive and the
 * public keys, whose hash is the extension id.
 */
export interface CrxPackage {
  readonly publicKeys: ReadonlyArray<Uint8Array>;
  readonly archive: Uint8Array;
}

export class CrxFormatError extends Error {}

const readUint32 = (bytes: Uint8Array, offset: number): number => {
  if (offset + 4 > bytes.length) throw new CrxFormatError("The package is truncated.");
  return new DataView(bytes.buffer, bytes.byteOffset + offset, 4).getUint32(0, true);
};

/** Minimal protobuf walk over the length-delimited fields of one message. */
function* lengthDelimitedFields(
  bytes: Uint8Array,
): Generator<{ readonly field: number; readonly value: Uint8Array }> {
  let offset = 0;
  const varint = () => {
    let result = 0;
    let shift = 0;
    for (;;) {
      if (offset >= bytes.length) throw new CrxFormatError("The package header is truncated.");
      const byte = bytes[offset++]!;
      result += (byte & 0x7f) * 2 ** shift;
      if ((byte & 0x80) === 0) return result;
      shift += 7;
    }
  };
  while (offset < bytes.length) {
    const tag = varint();
    const field = Math.floor(tag / 8);
    const wireType = tag & 7;
    if (wireType === 0) varint();
    else if (wireType === 1) offset += 8;
    else if (wireType === 5) offset += 4;
    else if (wireType === 2) {
      const length = varint();
      if (offset + length > bytes.length) {
        throw new CrxFormatError("The package header is truncated.");
      }
      yield { field, value: bytes.subarray(offset, offset + length) };
      offset += length;
    } else throw new CrxFormatError(`Unsupported protobuf wire type ${wireType}.`);
  }
}

export function parseCrx(bytes: Uint8Array): CrxPackage {
  if (new TextDecoder().decode(bytes.subarray(0, 4)) !== "Cr24") {
    throw new CrxFormatError("Not a Chrome extension package.");
  }
  const version = readUint32(bytes, 4);
  if (version === 2) {
    const keyLength = readUint32(bytes, 8);
    const signatureLength = readUint32(bytes, 12);
    return {
      publicKeys: [bytes.subarray(16, 16 + keyLength)],
      archive: bytes.subarray(16 + keyLength + signatureLength),
    };
  }
  if (version !== 3) throw new CrxFormatError(`Unsupported package version ${version}.`);
  const headerLength = readUint32(bytes, 8);
  const header = bytes.subarray(12, 12 + headerLength);
  const publicKeys: Array<Uint8Array> = [];
  // CrxFileHeader fields 2 and 3 hold RSA and ECDSA key proofs; field 1 of a
  // proof is the DER-encoded public key.
  for (const { field, value } of lengthDelimitedFields(header)) {
    if (field !== 2 && field !== 3) continue;
    for (const proof of lengthDelimitedFields(value)) {
      if (proof.field === 1) publicKeys.push(proof.value);
    }
  }
  return { publicKeys, archive: bytes.subarray(12 + headerLength) };
}

/** Chrome's id for a public key: the first 128 bits of its SHA-256, written with letters a-p. */
export function extensionIdFromPublicKey(publicKey: Uint8Array): string {
  const digest = NodeCrypto.createHash("sha256").update(publicKey).digest("hex").slice(0, 32);
  return digest.replace(/[0-9a-f]/g, (digit) =>
    String.fromCharCode(97 + Number.parseInt(digit, 16)),
  );
}

/**
 * The manifest `key` for `extensionId`, from the package's matching public
 * key. Electron derives an unpacked extension's id from it, so the extension
 * keeps its Chrome id (which native messaging hosts allow by name).
 */
export function manifestKeyFor(crx: CrxPackage, extensionId: string): string | undefined {
  const key = crx.publicKeys.find(
    (candidate) => extensionIdFromPublicKey(candidate) === extensionId,
  );
  return key === undefined ? undefined : Buffer.from(key).toString("base64");
}
