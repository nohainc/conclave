import { createPrivateKey, createPublicKey, sign, verify } from "node:crypto";

const required = [
  "CONCLAVE_RELEASE_PRIVATE_KEY",
  "CONCLAVE_RELEASE_PUBLISHER",
  "CONCLAVE_RELEASE_SIGNING_KEY_ID",
  "CONCLAVE_RELEASE_TRUST_KEYS_JSON",
];
const missing = required.filter((name) => !process.env[name]?.trim());
if (missing.length > 0) {
  console.error(
    `Missing Tool Profile signer configuration: ${missing.join(", ")}`,
  );
  process.exit(1);
}

try {
  const privateValue = process.env.CONCLAVE_RELEASE_PRIVATE_KEY.trim();
  let privateInput = privateValue;
  let privateFormat = "pem";
  let privateType;
  if (!privateValue.includes("-----BEGIN")) {
    let bytes = Buffer.from(privateValue, "base64");
    if (bytes.length === 32) {
      bytes = Buffer.concat([
        Buffer.from("302e020100300506032b657004220420", "hex"),
        bytes,
      ]);
    }
    privateInput = bytes;
    privateFormat = "der";
    privateType = "pkcs8";
  }
  const privateKey = createPrivateKey({
    key: privateInput,
    format: privateFormat,
    ...(privateType ? { type: privateType } : {}),
  });
  if (privateKey.asymmetricKeyType !== "ed25519") {
    throw new Error("configured private key is not Ed25519");
  }

  const publisher = process.env.CONCLAVE_RELEASE_PUBLISHER.trim();
  const signingKeyId = process.env.CONCLAVE_RELEASE_SIGNING_KEY_ID.trim();
  const roots = JSON.parse(process.env.CONCLAVE_RELEASE_TRUST_KEYS_JSON);
  const encodedPublicKey = roots?.[publisher]?.[signingKeyId];
  if (typeof encodedPublicKey !== "string") {
    throw new Error(
      "configured publisher and key ID have no public trust root",
    );
  }
  const rawPublicKey = Buffer.from(encodedPublicKey, "base64");
  if (rawPublicKey.length !== 32) {
    throw new Error("configured public trust root is not a raw Ed25519 key");
  }
  const publicKey = createPublicKey({
    key: Buffer.concat([
      Buffer.from("302a300506032b6570032100", "hex"),
      rawPublicKey,
    ]),
    format: "der",
    type: "spki",
  });
  const challenge = Buffer.from(
    "conclave-tool-profile-production-signer-preflight-v1",
  );
  const signature = sign(null, challenge, privateKey);
  if (!verify(null, challenge, publicKey, signature)) {
    throw new Error(
      "configured private signer does not match the public trust root",
    );
  }
  console.log(
    "Production Tool Profile signer and trust root preflight passed.",
  );
} catch (error) {
  console.error(
    `Tool Profile signer preflight failed: ${error instanceof Error ? error.message : "invalid configuration"}`,
  );
  process.exit(1);
}
