// @effect-diagnostics nodeBuiltinImport:off -- verifies the signature with the key's public half.
import * as NodeCrypto from "node:crypto";

import { assert, describe, it } from "@effect/vitest";

import { makeApnsAlertPayload, makeApnsProviderToken } from "./apns.ts";

const decodeSegment = (segment: string | undefined): unknown =>
  JSON.parse(Buffer.from(segment ?? "", "base64url").toString("utf8"));

describe("makeApnsProviderToken", () => {
  it("signs an ES256 token that the key's public half verifies, in the raw form APNs requires", () => {
    const { privateKey, publicKey } = NodeCrypto.generateKeyPairSync("ec", {
      namedCurve: "P-256",
    });
    const pem = privateKey.export({ format: "pem", type: "pkcs8" }).toString();

    const token = makeApnsProviderToken(
      { teamId: "ABCDE12345", keyId: "KEY1234567", privateKey: pem },
      1_763_294_400,
    );

    const [header, payload, signature] = token.split(".");
    assert.deepStrictEqual(decodeSegment(header), { alg: "ES256", kid: "KEY1234567" });
    assert.deepStrictEqual(decodeSegment(payload), { iss: "ABCDE12345", iat: 1_763_294_400 });
    const signatureBytes = Buffer.from(signature ?? "", "base64url");
    // A DER signature (~70 bytes) is rejected by APNs; JWS wants r || s.
    assert.equal(signatureBytes.length, 64);
    assert.isTrue(
      NodeCrypto.verify(
        "sha256",
        Buffer.from(`${header}.${payload}`),
        { key: publicKey, dsaEncoding: "ieee-p1363" },
        signatureBytes,
      ),
    );
  });
});

describe("makeApnsAlertPayload", () => {
  it("puts the thread route where the app's notification tap handler reads it", () => {
    assert.deepStrictEqual(
      makeApnsAlertPayload({
        title: "Fix the flaky test",
        body: "Done: t3code",
        environmentId: "env-1",
        threadId: "thread-1",
        deepLink: "/threads/env-1/thread-1",
      }),
      {
        aps: {
          alert: { title: "Fix the flaky test", body: "Done: t3code" },
          sound: "default",
          "thread-id": "env-1/thread-1",
        },
        body: {
          environmentId: "env-1",
          threadId: "thread-1",
          deepLink: "/threads/env-1/thread-1",
        },
      },
    );
  });
});
