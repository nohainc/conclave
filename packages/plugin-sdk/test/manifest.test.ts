import { describe, it, expect } from "vitest";
import {
  type WorkerPluginBillingMode,
  type WorkerPluginManifest,
  validateWorkerPluginManifest,
  isPluginCompatibleWithAgent,
  satisfiesSemverRange,
} from "../src/manifest.js";

describe("WorkerPluginManifest", () => {
  const validManifest: WorkerPluginManifest = {
    pluginId: "conclave.codex",
    version: "1.2.0",
    displayName: "OpenAI Codex Worker Plugin",
    description: "Executes code refactoring and generation tasks",
    publisher: "conclave-official",
    channel: "stable",
    protocolVersion: "2.0",
    minimumAgentVersion: "0.2.0",
    supportedOS: ["macos", "linux"],
    supportedArchitecture: ["arm64", "x64"],
    roles: ["coder", "architect"],
    capabilities: ["code_write", "git_ops"],
    permissions: ["fs:read", "fs:write"],
    configurationSchema: {
      type: "object",
      properties: {
        model: { type: "string" },
      },
    },
    secretSchema: {
      OPENAI_API_KEY: { type: "string", required: true },
    },
    entrypoint: "dist/index.js",
    billingModes: ["api_metered", "subscription"],
    digest:
      "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    signature: "sig_rsa_test_123",
  };

  it("validates a compliant worker plugin manifest successfully", () => {
    const validated = validateWorkerPluginManifest(validManifest);
    expect(validated).toEqual(validManifest);
  });

  it("rejects invalid semver versioning in manifest", () => {
    expect(() =>
      validateWorkerPluginManifest({
        ...validManifest,
        version: "v1.2", // invalid semver format
      }),
    ).toThrow();
  });

  it("rejects empty roles or capabilities", () => {
    expect(() =>
      validateWorkerPluginManifest({
        ...validManifest,
        roles: [],
      }),
    ).toThrow();

    expect(() =>
      validateWorkerPluginManifest({
        ...validManifest,
        capabilities: [],
      }),
    ).toThrow();
  });

  it("rejects invalid billing modes", () => {
    expect(() =>
      validateWorkerPluginManifest({
        ...validManifest,
        billingModes: [
          "invalid_billing_mode" as unknown as WorkerPluginBillingMode,
        ],
      }),
    ).toThrow();
  });

  it("supports release channels (stable, beta, development)", () => {
    const betaManifest = validateWorkerPluginManifest({
      ...validManifest,
      channel: "beta",
    });
    expect(betaManifest.channel).toBe("beta");

    const devManifest = validateWorkerPluginManifest({
      ...validManifest,
      channel: "development",
    });
    expect(devManifest.channel).toBe("development");
  });

  it("checks agent compatibility against OS, Arch, and minimum agent version", () => {
    const compatibleResult = isPluginCompatibleWithAgent(validManifest, {
      os: "macos",
      architecture: "arm64",
      agentVersion: "0.2.5",
    });
    expect(compatibleResult.compatible).toBe(true);

    const incompatibleOS = isPluginCompatibleWithAgent(validManifest, {
      os: "windows",
      architecture: "arm64",
      agentVersion: "0.2.5",
    });
    expect(incompatibleOS.compatible).toBe(false);
    expect(incompatibleOS.reason).toMatch(/Host OS 'windows' is not supported/);

    const incompatibleArch = isPluginCompatibleWithAgent(
      { ...validManifest, supportedArchitecture: ["x64"] },
      {
        os: "macos",
        architecture: "arm64",
        agentVersion: "0.2.5",
      },
    );
    expect(incompatibleArch.compatible).toBe(false);
    expect(incompatibleArch.reason).toMatch(
      /Host architecture 'arm64' is not supported/,
    );

    const incompatibleAgentVersion = isPluginCompatibleWithAgent(
      { ...validManifest, minimumAgentVersion: "0.3.0" },
      {
        os: "macos",
        architecture: "arm64",
        agentVersion: "0.2.0",
      },
    );
    expect(incompatibleAgentVersion.compatible).toBe(false);
    expect(incompatibleAgentVersion.reason).toMatch(
      /below minimum required version/,
    );
  });

  it("checks semver range satisfaction (^, ~, >=, exact, latest, *)", () => {
    // Caret ranges
    expect(satisfiesSemverRange("1.4.0", "^1.4")).toBe(true);
    expect(satisfiesSemverRange("1.5.2", "^1.4")).toBe(true);
    expect(satisfiesSemverRange("2.0.0", "^1.4")).toBe(false);
    expect(satisfiesSemverRange("1.3.9", "^1.4")).toBe(false);
    expect(satisfiesSemverRange("0.2.5", "^0.2.0")).toBe(true);
    expect(satisfiesSemverRange("0.3.0", "^0.2.0")).toBe(false);

    // Tilde ranges
    expect(satisfiesSemverRange("1.4.2", "~1.4.0")).toBe(true);
    expect(satisfiesSemverRange("1.5.0", "~1.4.0")).toBe(false);

    // Relational
    expect(satisfiesSemverRange("1.5.0", ">=1.4.0")).toBe(true);
    expect(satisfiesSemverRange("1.3.0", ">=1.4.0")).toBe(false);

    // Exact and Wildcard
    expect(satisfiesSemverRange("1.4.0", "1.4.0")).toBe(true);
    expect(satisfiesSemverRange("1.4.1", "1.4.0")).toBe(false);
    expect(satisfiesSemverRange("9.9.9", "latest")).toBe(true);
    expect(satisfiesSemverRange("9.9.9", "*")).toBe(true);
  });
});
