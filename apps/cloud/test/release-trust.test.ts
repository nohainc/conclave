import { generateKeyPairSync, sign } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
  canonicalReleaseJson,
  verifyEd25519ReleaseSignature,
} from "../src/release-trust.js";

describe("public-key release trust", () => {
  it("verifies Ed25519 release signatures and fails closed for unknown or malformed roots", async () => {
    const { privateKey, publicKey } = generateKeyPairSync("ed25519");
    const rawPublic = publicKey
      .export({ format: "der", type: "spki" })
      .subarray(-32);
    const message =
      "conclave-v7-adapter-release-v1\n" +
      "a".repeat(64) +
      "\n" +
      canonicalReleaseJson({ adapterVersion: "1.2.3", workerTypeId: "codex" });
    const signature = sign(null, Buffer.from(message), privateKey).toString(
      "base64",
    );
    const trustKeysJson = JSON.stringify({
      conclave: { "adapter-2026": rawPublic.toString("base64") },
    });
    expect(
      await verifyEd25519ReleaseSignature({
        trustKeysJson,
        publisher: "conclave",
        signingKeyId: "adapter-2026",
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
        signingKeyId: "adapter-2026",
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
});
