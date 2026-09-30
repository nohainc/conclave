import { createPrivateKey, createHash, sign } from "node:crypto";
import { readFile, stat } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";

const workerTypes = ["chatgpt", "gemini"];
const platforms = [
  "macos-arm64",
  "macos-x64",
  "linux-x64",
  "linux-arm64",
  "windows-x64",
];

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function digestPackage(relativePath, mode, contents) {
  const hash = createHash("sha256");
  hash.update(relativePath, "utf8");
  hash.update(Buffer.from([0]));
  hash.update(mode.toString(8), "utf8");
  hash.update(Buffer.from([0]));
  hash.update(contents);
  hash.update(Buffer.from([0]));
  return hash.digest("hex");
}

function writeOctal(buffer, value, offset, length) {
  const text = value.toString(8).padStart(length - 1, "0");
  buffer.write(text.slice(-(length - 1)), offset, length - 1, "ascii");
  buffer[offset + length - 1] = 0;
}

function tarEntry(name, contents, mode) {
  const header = Buffer.alloc(512);
  header.write(name, 0, 100, "utf8");
  writeOctal(header, mode, 100, 8);
  writeOctal(header, 0, 108, 8);
  writeOctal(header, 0, 116, 8);
  writeOctal(header, contents.length, 124, 12);
  writeOctal(header, 0, 136, 12);
  header.fill(0x20, 148, 156);
  header[156] = "0".charCodeAt(0);
  header.write("ustar\0", 257, 6, "ascii");
  header.write("00", 263, 2, "ascii");
  header.write("conclave", 265, 8, "ascii");
  header.write("conclave", 297, 8, "ascii");
  let checksum = 0;
  for (const byte of header) checksum += byte;
  const checksumText = checksum.toString(8).padStart(6, "0");
  header.write(checksumText, 148, 6, "ascii");
  header[154] = 0;
  header[155] = 0x20;
  const padding = Buffer.alloc((512 - (contents.length % 512)) % 512);
  return Buffer.concat([header, contents, padding]);
}

function makeArchive(contents, mode) {
  const tar = Buffer.concat([
    tarEntry("bin/conclave-worker", contents, mode),
    Buffer.alloc(1024),
  ]);
  return gzipSync(tar, { level: 9, mtime: 0 });
}

function signManifest(unsignedManifest, seedBase64) {
  const seed = Buffer.from(seedBase64, "base64");
  if (seed.length !== 32)
    throw new Error("signing seed must be 32 raw Ed25519 bytes");
  const derPrefix = Buffer.from("302e020100300506032b657004220420", "hex");
  const privateKey = createPrivateKey({
    key: Buffer.concat([derPrefix, seed]),
    format: "der",
    type: "pkcs8",
  });
  return sign(
    null,
    Buffer.from(
      `conclave-worker-release-manifest-v2\n${canonicalJson(unsignedManifest)}`,
    ),
    privateKey,
  ).toString("base64");
}

async function publishOne({
  baseUrl,
  token,
  artifactRoot,
  workerTypeId,
  platform,
  version,
  channel,
  publisher,
  signingKeyId,
  seedBase64,
}) {
  const extension = platform === "windows-x64" ? ".exe" : "";
  const binaryPath = path.join(
    artifactRoot,
    platform,
    workerTypeId,
    `conclave-${workerTypeId}-worker${extension}`,
  );
  const binary = await readFile(binaryPath);
  if (binary.length === 0 || binary.length > 512 * 1024 * 1024) {
    throw new Error(`invalid executable size: ${platform}/${workerTypeId}`);
  }
  const mode = platform === "windows-x64" ? 0o777 : 0o755;
  const packageDigest = digestPackage("bin/conclave-worker", mode, binary);
  const archive = makeArchive(binary, mode);
  if (archive.length > 100 * 1024 * 1024) {
    throw new Error(
      `Worker archive exceeds Cloud limit: ${platform}/${workerTypeId}`,
    );
  }
  const unsignedManifest = {
    manifestVersion: 2,
    workerTypeId,
    workerVersion: version,
    publisher,
    platform,
    protocol: { min: "3.0", max: "3.0" },
    stateSchema: { readMin: 1, readMax: 1, write: 1 },
    capabilities: ["initialize", "probe", "execute", "durable_session"],
    permissions: [
      workerTypeId === "chatgpt" ? "network:openai" : "network:google",
      "credentials:read",
    ],
    executable: "bin/conclave-worker",
    releaseChannel: channel,
    packageDigest,
    archiveSha256: createHash("sha256").update(archive).digest("hex"),
    signingKeyId,
  };
  const manifest = {
    ...unsignedManifest,
    signature: signManifest(unsignedManifest, seedBase64),
  };
  const response = await fetch(`${baseUrl}/api/worker-releases/publish`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      manifest,
      archiveBase64: archive.toString("base64"),
    }),
  });
  const responseText = await response.text();
  if (!response.ok) {
    throw new Error(
      `publish failed (${response.status}) for ${workerTypeId}/${platform}: ${responseText.slice(0, 1000)}`,
    );
  }
  process.stdout.write(
    `${workerTypeId} ${version} ${platform}: ${responseText}\n`,
  );
}

async function main() {
  const version = required("WORKER_VERSION");
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version)) {
    throw new Error("WORKER_VERSION must be a semantic version");
  }
  const channel = required("WORKER_RELEASE_CHANNEL");
  if (!["stable", "beta", "development"].includes(channel)) {
    throw new Error(
      "WORKER_RELEASE_CHANNEL must be stable, beta, or development",
    );
  }
  const baseUrl = required("CONCLAVE_CLOUD_URL").replace(/\/$/, "");
  const token = required("CONCLAVE_RELEASE_PUBLISH_TOKEN");
  const publisher = required("CONCLAVE_WORKER_PUBLISHER");
  const signingKeyId = required("CONCLAVE_WORKER_SIGNING_KEY_ID");
  const seedBase64 = required("CONCLAVE_WORKER_SIGNING_SEED");
  const artifactRoot = path.resolve(required("WORKER_ARTIFACT_DIR"));
  if (!(await stat(artifactRoot)).isDirectory())
    throw new Error("worker artifact directory is invalid");
  for (const platform of platforms) {
    const extension = platform === "windows-x64" ? ".exe" : "";
    for (const workerTypeId of workerTypes) {
      const binaryPath = path.join(
        artifactRoot,
        platform,
        workerTypeId,
        `conclave-${workerTypeId}-worker${extension}`,
      );
      const binaryStat = await stat(binaryPath);
      if (!binaryStat.isFile() || binaryStat.size === 0) {
        throw new Error(`missing native artifact: ${platform}/${workerTypeId}`);
      }
    }
  }
  for (const platform of platforms) {
    for (const workerTypeId of workerTypes) {
      await publishOne({
        baseUrl,
        token,
        artifactRoot,
        workerTypeId,
        platform,
        version,
        channel,
        publisher,
        signingKeyId,
        seedBase64,
      });
    }
  }
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  main().catch((error) => {
    process.stderr.write(
      `${error instanceof Error ? error.message : String(error)}\n`,
    );
    process.exitCode = 1;
  });
}

export {
  canonicalJson,
  digestPackage,
  makeArchive,
  platforms,
  signManifest,
  tarEntry,
};
