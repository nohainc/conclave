import { describe, expect, it } from "vitest";
import {
  V7_ADAPTER_MAX_FRAME_BYTES,
  V7_ADAPTER_PROTOCOL_VERSION,
  isPackageRelativePath,
  parseV7AdapterFrame,
  parseV7AdapterManifest,
  serializeV7AdapterFrame,
} from "../src/adapter-v7.js";

const manifest = {
  workerTypeId: "codex",
  adapterVersion: "1.2.3",
  protocolVersion: V7_ADAPTER_PROTOCOL_VERSION,
  publisher: "Conclave",
  displayName: "Codex",
  supportedPlatforms: ["macos-arm64"],
  capabilities: ["code"],
  permissions: ["workstream_filesystem", "shell_execution"],
  authStrategies: ["browser_auth"],
  modelSelectionMode: "allow_list",
  prerequisites: [
    {
      kind: "executable",
      executable: "codex",
      minimumVersion: "1.0.0",
      versionArgs: ["--version"],
    },
  ],
  executable: "bin/adapter.js",
  launchArgs: ["--stdio"],
  secretRequirements: [],
  healthCheck: { mode: "protocol", timeoutMs: 5000 },
  packageDigest: "a".repeat(64),
  signature: "signature",
  releaseChannel: "stable",
};

describe("Architecture v7 adapter manifest and protocol", () => {
  it("parses a signed adapter integration manifest", () => {
    expect(parseV7AdapterManifest(manifest)).toMatchObject({
      workerTypeId: "codex",
      executable: "bin/adapter.js",
    });
  });

  it.each([
    "../escape",
    "/usr/bin/codex",
    "C:/tools/codex",
    "bin/../escape",
    "./adapter",
  ])(
    "rejects executable path outside the package boundary: %s",
    (executable) => {
      expect(() => parseV7AdapterManifest({ ...manifest, executable })).toThrow(
        /verified package/,
      );
    },
  );

  it("requires prerequisite commands to be names resolved by Workspace policy", () => {
    expect(() =>
      parseV7AdapterManifest({
        ...manifest,
        prerequisites: [{ kind: "executable", executable: "../../bin/codex" }],
      }),
    ).toThrow(/command name, not a path/);
  });

  it("keeps a model out of the Worker Type namespace", () => {
    expect(() =>
      parseV7AdapterManifest({ ...manifest, workerTypeId: "gpt-" + "5" }),
    ).toThrow(/integration, not a model/);
  });

  it("uses structured, strict protocol frames with a byte limit and no CWD field", () => {
    const message = {
      type: "execute.request",
      protocolVersion: V7_ADAPTER_PROTOCOL_VERSION,
      requestId: "req-1",
      assignmentId: "assignment-1",
      prompt: "Inspect the project",
    } as const;
    const frame = serializeV7AdapterFrame(message);
    expect(parseV7AdapterFrame(frame)).toEqual(message);
    expect(() =>
      parseV7AdapterFrame(JSON.stringify({ ...message, cwd: "/private" })),
    ).toThrow();
    expect(() =>
      parseV7AdapterFrame(" ".repeat(V7_ADAPTER_MAX_FRAME_BYTES + 1)),
    ).toThrow(/1 MB protocol limit/);
  });

  it("rejects malformed JSON and unknown protocol message types", () => {
    expect(() => parseV7AdapterFrame("{")).toThrow();
    expect(() =>
      parseV7AdapterFrame(
        JSON.stringify({
          type: "execute",
          protocolVersion: V7_ADAPTER_PROTOCOL_VERSION,
        }),
      ),
    ).toThrow();
  });

  it("accepts only normalized package-relative paths", () => {
    expect(isPackageRelativePath("bin/adapter")).toBe(true);
    expect(isPackageRelativePath("bin/../adapter")).toBe(false);
    expect(isPackageRelativePath("/bin/adapter")).toBe(false);
  });
});
