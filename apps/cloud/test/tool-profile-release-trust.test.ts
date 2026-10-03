import { generateKeyPairSync, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it, vi } from "vitest";
import {
  canonicalReleaseJson,
  verifyEd25519ReleaseSignature,
} from "../src/release-trust.js";
import {
  toolProfileReleaseSigningMessage,
  toolProfileSigningPreflight,
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
  it("requires a configured signer that matches an active trust root", async () => {
    const { generateEd25519ReleaseKeyPair } = await import(
      "../src/release-trust.js"
    );
    const keyPair = generateEd25519ReleaseKeyPair();
    const statement = {
      first: vi.fn(async () => null),
      bind: vi.fn(function (this: unknown) {
        return this;
      }),
    };
    const env = {
      CONCLAVE_DB: {
        prepare: vi.fn(() => statement),
      },
      CONCLAVE_RELEASE_PUBLISHER: "conclave",
      CONCLAVE_RELEASE_SIGNING_KEY_ID: "profile-2026",
      CONCLAVE_RELEASE_PRIVATE_KEY: keyPair.privateKeyBase64,
      CONCLAVE_RELEASE_TRUST_KEYS_JSON: JSON.stringify({
        conclave: { "profile-2026": keyPair.publicKeyBase64 },
      }),
    } as unknown as Parameters<typeof toolProfileSigningPreflight>[0];

    await expect(toolProfileSigningPreflight(env)).resolves.toEqual({
      ready: true,
      publisher: "conclave",
      signingKeyId: "profile-2026",
      issues: [],
    });
  });

  it("fails closed when the signer is absent or does not match its trust root", async () => {
    const emptyDb = {
      prepare: () => ({
        bind() {
          return this;
        },
        first: async () => null,
      }),
    };
    await expect(
      toolProfileSigningPreflight({ CONCLAVE_DB: emptyDb } as never),
    ).resolves.toMatchObject({
      ready: false,
      issues: [
        "publisher_missing",
        "signing_key_id_missing",
        "private_key_missing",
        "trust_roots_missing",
      ],
    });
    const { generateEd25519ReleaseKeyPair } = await import(
      "../src/release-trust.js"
    );
    const signer = generateEd25519ReleaseKeyPair();
    const differentTrustRoot = generateEd25519ReleaseKeyPair();
    await expect(
      toolProfileSigningPreflight({
        CONCLAVE_DB: emptyDb,
        CONCLAVE_RELEASE_PUBLISHER: "conclave",
        CONCLAVE_RELEASE_SIGNING_KEY_ID: "profile-2026",
        CONCLAVE_RELEASE_PRIVATE_KEY: signer.privateKeyBase64,
        CONCLAVE_RELEASE_TRUST_KEYS_JSON: JSON.stringify({
          conclave: { "profile-2026": differentTrustRoot.publicKeyBase64 },
        }),
      } as never),
    ).resolves.toMatchObject({
      ready: false,
      issues: ["signer_trust_mismatch"],
    });
  });

  it("fails closed when the configured signing key has been revoked", async () => {
    const { generateEd25519ReleaseKeyPair } = await import(
      "../src/release-trust.js"
    );
    const keyPair = generateEd25519ReleaseKeyPair();
    const db = {
      prepare: () => ({
        bind() {
          return this;
        },
        first: async () => ({ key_id: "profile-2026" }),
      }),
    };
    await expect(
      toolProfileSigningPreflight({
        CONCLAVE_DB: db,
        CONCLAVE_RELEASE_PUBLISHER: "conclave",
        CONCLAVE_RELEASE_SIGNING_KEY_ID: "profile-2026",
        CONCLAVE_RELEASE_PRIVATE_KEY: keyPair.privateKeyBase64,
        CONCLAVE_RELEASE_TRUST_KEYS_JSON: JSON.stringify({
          conclave: { "profile-2026": keyPair.publicKeyBase64 },
        }),
      } as never),
    ).resolves.toMatchObject({
      ready: false,
      issues: ["signing_key_revoked"],
    });
  });

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
