import { describe, expect, it } from "vitest";
import {
  parseWorkerReleaseManifestV2,
  WorkerReleaseManifestV2Schema,
} from "../src/worker-release-v2.js";

const validManifest = {
  manifestVersion: 2,
  workerTypeId: "test",
  workerVersion: "0.1.0",
  publisher: "Conclave Test",
  platform: "macos-arm64",
  protocol: { min: "3.0", max: "3.0" },
  stateSchema: { readMin: 1, readMax: 1, write: 1 },
  capabilities: ["execute", "passive_probe", "live_probe"],
  permissions: ["workspace:read"],
  executable: "bin/conclave-test-worker",
  releaseChannel: "development",
  packageDigest: "a".repeat(64),
  archiveSha256: "b".repeat(64),
  signingKeyId: "test-ed25519-v1",
  signature: "fixture-signature",
};

describe("Worker release manifest v2", () => {
  it("parses provider-neutral native Worker release metadata", () => {
    expect(parseWorkerReleaseManifestV2(validManifest)).toEqual(validManifest);
  });

  it("rejects legacy provider and adapter metadata", () => {
    expect(
      WorkerReleaseManifestV2Schema.safeParse({
        ...validManifest,
        prerequisites: [{ kind: "executable", executable: "node" }],
        adapterVersion: "0.1.0",
      }).success,
    ).toBe(false);
  });

  it("rejects unsupported protocol ranges and unsafe executable paths", () => {
    expect(
      WorkerReleaseManifestV2Schema.safeParse({
        ...validManifest,
        protocol: { min: "3.1", max: "3.0" },
      }).success,
    ).toBe(false);
    expect(
      WorkerReleaseManifestV2Schema.safeParse({
        ...validManifest,
        executable: "../outside",
      }).success,
    ).toBe(false);
  });

  it("requires its write schema to be readable by the release", () => {
    expect(
      WorkerReleaseManifestV2Schema.safeParse({
        ...validManifest,
        stateSchema: { readMin: 2, readMax: 3, write: 1 },
      }).success,
    ).toBe(false);
  });
});
