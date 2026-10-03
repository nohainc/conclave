import { generateKeyPairSync, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  canonicalReleaseJson,
  verifyEd25519ReleaseSignature,
} from "../src/release-trust.js";
import {
  toolProfileReleaseSigningMessage,
  validateToolProfileReleasePayload,
} from "../src/tool-profile-registry.js";

const fixture = JSON.parse(
  readFileSync(
    fileURLToPath(
      new URL(
        "../../../packages/tool-profile/test/fixtures/fixture-cli.v1.json",
        import.meta.url,
      ),
    ),
    "utf8",
  ),
) as Record<string, unknown>;

describe("Tool Profile release trust", () => {
  it("verifies Profile signatures and fails closed for unknown or missing roots", async () => {
    const { privateKey, publicKey } = generateKeyPairSync("ed25519");
    const rawPublic = publicKey
      .export({ format: "der", type: "spki" })
      .subarray(-32);
    const message = toolProfileReleaseSigningMessage({
      publisher: "conclave",
      signingKeyId: "profile-2026",
      payloadDigest: "a".repeat(64),
      profile: validateToolProfileReleasePayload(fixture),
    });
    const signature = sign(null, Buffer.from(message), privateKey).toString(
      "base64",
    );
    const trustKeysJson = JSON.stringify({
      conclave: { "profile-2026": rawPublic.toString("base64") },
    });
    expect(
      await verifyEd25519ReleaseSignature({
        trustKeysJson,
        publisher: "conclave",
        signingKeyId: "profile-2026",
        signature,
        message,
      }),
    ).toBe(true);
    expect(
      await verifyEd25519ReleaseSignature({
        trustKeysJson,
        publisher: "conclave",
        signingKeyId: "retired-key",
        signature,
        message,
      }),
    ).toBe(false);
    expect(
      await verifyEd25519ReleaseSignature({
        trustKeysJson: undefined,
        publisher: "conclave",
        signingKeyId: "profile-2026",
        signature,
        message,
      }),
    ).toBe(false);
  });

  it("canonicalizes nested maps independent of insertion order", () => {
    expect(canonicalReleaseJson({ z: 1, a: { d: 2, b: 3 } })).toBe(
      '{"a":{"b":3,"d":2},"z":1}',
    );
  });

  it("generates Ed25519 key pairs and signs messages verified by trust policy", async () => {
    const { generateEd25519ReleaseKeyPair, signEd25519ReleaseMessage } =
      await import("../src/release-trust.js");
    const keyPair = generateEd25519ReleaseKeyPair();
    const message = "test-signing-message";
    const signature = signEd25519ReleaseMessage({
      privateKeyBase64OrPem: keyPair.privateKeyBase64,
      message,
    });
    const trustKeysJson = JSON.stringify({
      conclave: { "profile-key-v1": keyPair.publicKeyBase64 },
    });
    const valid = await verifyEd25519ReleaseSignature({
      trustKeysJson,
      publisher: "conclave",
      signingKeyId: "profile-key-v1",
      signature,
      message,
    });
    expect(valid).toBe(true);
  });
});
