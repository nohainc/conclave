import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { makeArchive, digestPackage } from "./release/publish-worker-releases.mjs";

function currentPlatform() {
  const platform =
    os.platform() === "darwin"
      ? "macos"
      : os.platform() === "win32"
        ? "windows"
        : os.platform();
  const architecture = os.arch() === "arm64" ? "arm64" : "x64";
  if (!["macos", "windows", "linux"].includes(platform)) {
    throw new Error(`unsupported development platform: ${os.platform()}`);
  }
  return `${platform}-${architecture}`;
}

async function packageWorker({ workerTypeId, version, root, platform }) {
  if (!["chatgpt", "gemini"].includes(workerTypeId)) {
    throw new Error(`unsupported first-party Worker: ${workerTypeId}`);
  }
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version)) {
    throw new Error("Worker version must be semantic version text");
  }
  const extension = platform.startsWith("windows-") ? ".exe" : "";
  const binaryName = `conclave-${workerTypeId}-worker${extension}`;
  const binaryPath = path.resolve(root, platform, workerTypeId, binaryName);
  const binary = await readFile(binaryPath);
  if (binary.length === 0 || binary.length > 512 * 1024 * 1024) {
    throw new Error(`invalid Worker executable: ${binaryPath}`);
  }
  const mode = platform.startsWith("windows-") ? 0o777 : 0o755;
  const archive = makeArchive(binary, mode);
  const unsignedManifest = {
    manifestVersion: 2,
    workerTypeId,
    workerVersion: version,
    publisher: "local-development",
    platform,
    protocol: { min: "3.0", max: "3.0" },
    stateSchema: { readMin: 1, readMax: 1, write: 1 },
    capabilities: ["initialize", "probe", "execute", "durable_session"],
    permissions: [
      workerTypeId === "chatgpt" ? "network:openai" : "network:google",
      "credentials:read",
    ],
    executable: "bin/conclave-worker",
    releaseChannel: "development",
    packageDigest: digestPackage("bin/conclave-worker", mode, binary),
    archiveSha256: createHash("sha256").update(archive).digest("hex"),
    signingKeyId: "unsigned-development",
  };
  const manifest = {
    ...unsignedManifest,
    signature: "unsigned-development",
  };
  const directory = path.resolve(root, platform, workerTypeId);
  await mkdir(directory, { recursive: true });
  await writeFile(path.join(directory, "worker-release.tgz"), archive);
  await writeFile(
    path.join(directory, "worker-release.json"),
    `${JSON.stringify(manifest, null, 2)}\n`,
  );
  process.stdout.write(
    `Packaged unsigned development Worker ${workerTypeId} ${version} (${platform})\n`,
  );
}

async function main() {
  const workerTypeId = process.argv[2];
  const version = process.argv[3];
  const root = path.resolve(process.argv[4] ?? "dist/workers");
  if (!workerTypeId || !version) {
    throw new Error(
      "Usage: node scripts/package-development-worker.mjs <chatgpt|gemini> <version> [artifact-root]",
    );
  }
  await packageWorker({
    workerTypeId,
    version,
    root,
    platform: currentPlatform(),
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}

export { currentPlatform, packageWorker };
