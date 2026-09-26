import {
  createPrivateKey,
  createPublicKey,
  createHash,
  sign,
  verify,
} from "node:crypto";
import { readFile } from "node:fs/promises";

const required = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
};
const canonical = (value) => {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
};

const archivePath = required("WORKSPACE_ARCHIVE");
const archive = await readFile(archivePath);
const version = required("WORKSPACE_VERSION");
const channel = required("RELEASE_CHANNEL");
const keyId = required("CONCLAVE_WORKSPACE_SIGNING_KEY_ID");
const publisher = "conclave";
const packageDigest = `sha256:${createHash("sha256").update(archive).digest("hex")}`;
const metadata = {
  version,
  channel,
  minSupportedHostVersion: null,
  supportedOS: ["macos"],
  supportedArch: [process.arch === "arm64" ? "arm64" : "x64"],
  releaseNotes: process.env.RELEASE_NOTES || "",
  publisher,
  signingKeyId: keyId,
  packageDigest,
};
const seed = Buffer.from(required("CONCLAVE_WORKSPACE_SIGNING_SEED"), "base64");
if (seed.length !== 32)
  throw new Error("Workspace signing seed must contain 32 bytes");
const privateKey = createPrivateKey({
  key: Buffer.concat([
    Buffer.from("302e020100300506032b657004220420", "hex"),
    seed,
  ]),
  format: "der",
  type: "pkcs8",
});
const payload = `conclave-workspace-release-metadata-v1\n${canonical(metadata)}`;
const signature = sign(null, Buffer.from(payload), privateKey).toString(
  "base64",
);
const base = required("CLOUD_API_URL").replace(/\/$/, "");
const token = required("RELEASE_PUBLISH_TOKEN");
const publish = await fetch(`${base}/api/host-releases/publish`, {
  method: "POST",
  headers: {
    authorization: `Bearer ${token}`,
    "content-type": "application/json",
  },
  body: JSON.stringify({
    version,
    channel,
    minSupportedAgentVersion: metadata.minSupportedHostVersion,
    supportedOS: metadata.supportedOS,
    supportedArch: metadata.supportedArch,
    releaseNotes: metadata.releaseNotes,
    packageDigest,
    signingKeyId: keyId,
    signature,
    packageBase64: archive.toString("base64"),
  }),
});
if (!publish.ok)
  throw new Error(`Workspace release publish failed: HTTP ${publish.status}`);

const infoResponse = await fetch(
  `${base}/api/host-releases/${encodeURIComponent(version)}`,
);
if (!infoResponse.ok)
  throw new Error(
    `Workspace release readback failed: HTTP ${infoResponse.status}`,
  );
const info = await infoResponse.json();
const roots = JSON.parse(required("CONCLAVE_RELEASE_TRUST_KEYS_JSON"));
const rawPublic = Buffer.from(roots[publisher]?.[keyId] ?? "", "base64");
if (rawPublic.length !== 32)
  throw new Error("Workspace public trust root is missing or invalid");
const publicKey = createPublicKey({
  key: Buffer.concat([
    Buffer.from("302a300506032b6570032100", "hex"),
    rawPublic,
  ]),
  format: "der",
  type: "spki",
});
const readbackMetadata = {
  version: info.version,
  channel: info.channel,
  minSupportedHostVersion: info.minSupportedAgentVersion,
  supportedOS: info.supportedOS,
  supportedArch: info.supportedArch,
  releaseNotes: info.releaseNotes,
  publisher,
  signingKeyId: info.signingKeyId,
  packageDigest: info.packageDigest,
};
if (
  !verify(
    null,
    Buffer.from(
      `conclave-workspace-release-metadata-v1\n${canonical(readbackMetadata)}`,
    ),
    publicKey,
    Buffer.from(info.signature, "base64"),
  )
) {
  throw new Error("Workspace release metadata signature readback failed");
}
const download = await fetch(
  `${base}/api/host-releases/${encodeURIComponent(version)}/download`,
  {
    headers: { authorization: `Bearer ${token}` },
  },
);
if (!download.ok)
  throw new Error(
    `Workspace release download-back failed: HTTP ${download.status}`,
  );
const downloaded = Buffer.from(await download.arrayBuffer());
const downloadedDigest = `sha256:${createHash("sha256").update(downloaded).digest("hex")}`;
if (downloadedDigest !== packageDigest)
  throw new Error("Workspace release archive digest readback failed");
console.log(`Published and verified Workspace ${version} (${channel})`);
