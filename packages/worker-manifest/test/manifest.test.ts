import { describe, it, expect } from "vitest";
import {
  type WorkerBillingMode,
  type WorkerManifest,
  type WorkerCredentialSharingPolicy,
  type WorkerCredentialAuthMode,
  validateWorkerManifest,
  isWorkerCompatibleWithHost,
  satisfiesSemverRange,
} from "../src/manifest.js";

describe("WorkerManifest (v4 Package Contract)", () => {
  const sampleCodexManifest: WorkerManifest = {
    workerId: "codex",
    version: "1.0.0",
    displayName: "Codex Worker",
    description: "Official OpenAI Codex worker for code generation and review",
    publisher: "conclave-official",
    channel: "stable",
    protocolVersion: "4.0",
    minimumHostVersion: "0.1.0",
    supportedOS: ["macos", "linux", "windows"],
    supportedArchitecture: ["arm64", "x64"],
    roles: ["implementer", "reviewer"],
    capabilities: ["code_editing", "terminal_execution", "git_workspace"],
    permissions: ["fs:read", "fs:write", "process:spawn"],
    credentialRequirements: [
      {
        name: "codex_auth",
        authMode: "oauth_browser",
        sharingPolicy: "owner_controlled",
        required: true,
        description: "OpenAI or Codex subscription credentials",
      },
    ],
    credentialSharingPolicy: "owner_controlled",
    configurationSchema: {
      type: "object",
      properties: {
        model: { type: "string", default: "codex-1" },
        temperature: { type: "number", default: 0.2 },
      },
    },
    sessionModes: ["isolated_workspace", "reuse_session"],
    concurrencyModel: {
      maxConcurrentAssignments: 4,
      persistentRuntime: false,
      isolation: "process",
    },
    entrypoint: "bin/codex_worker.dart",
    billingModes: ["subscription", "api_metered"],
    digest:
      "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    signature: "sig_rsa_test_123",
  };

  const sampleOpenAIManifest: WorkerManifest = {
    workerId: "openai",
    version: "1.2.0",
    displayName: "OpenAI API Worker",
    description: "Direct OpenAI API worker for LLM inference",
    publisher: "conclave-official",
    channel: "stable",
    protocolVersion: "4.0",
    minimumHostVersion: "0.1.0",
    supportedOS: ["macos", "linux", "windows"],
    supportedArchitecture: ["arm64", "x64"],
    roles: ["implementer", "researcher", "reviewer"],
    capabilities: ["model_inference", "structured_outputs"],
    permissions: ["net:http"],
    credentialRequirements: [
      {
        name: "openai_api_key",
        authMode: "api_key",
        sharingPolicy: "workspace_capable",
        required: true,
        envVar: "OPENAI_API_KEY",
        description: "OpenAI API Secret Key",
      },
    ],
    credentialSharingPolicy: "workspace_capable",
    configurationSchema: {
      type: "object",
      properties: {
        model: { type: "string", default: "gpt-4o" },
      },
    },
    sessionModes: ["stateless"],
    concurrencyModel: {
      maxConcurrentAssignments: 10,
      persistentRuntime: false,
      isolation: "thread",
    },
    entrypoint: "bin/openai_worker.dart",
    billingModes: ["api_metered"],
    digest:
      "sha256:1111111111fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    signature: "sig_rsa_test_456",
  };

  const sampleAnthropicManifest: WorkerManifest = {
    workerId: "anthropic",
    version: "1.1.0",
    displayName: "Anthropic Claude Worker",
    description: "Anthropic Claude models integration",
    publisher: "conclave-official",
    channel: "stable",
    protocolVersion: "4.0",
    minimumHostVersion: "0.1.0",
    supportedOS: ["macos", "linux"],
    supportedArchitecture: ["arm64", "x64"],
    roles: ["implementer", "reviewer"],
    capabilities: ["model_inference", "tool_calling"],
    permissions: ["net:http"],
    credentialRequirements: [
      {
        name: "anthropic_api_key",
        authMode: "api_key",
        sharingPolicy: "workspace_capable",
        required: true,
        envVar: "ANTHROPIC_API_KEY",
      },
    ],
    credentialSharingPolicy: "workspace_capable",
    configurationSchema: {},
    sessionModes: ["stateless"],
    concurrencyModel: {
      maxConcurrentAssignments: 8,
      persistentRuntime: false,
      isolation: "process",
    },
    entrypoint: "bin/anthropic_worker.dart",
    billingModes: ["api_metered"],
    digest:
      "sha256:2222222222fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  };

  const sampleNoAuthManifest: WorkerManifest = {
    workerId: "git-test",
    version: "0.5.0",
    displayName: "Git & Test Verification Worker",
    description:
      "Runs local git operations and tests without external credentials",
    publisher: "conclave-official",
    channel: "stable",
    protocolVersion: "4.0",
    minimumHostVersion: "0.1.0",
    supportedOS: ["macos", "linux", "windows"],
    supportedArchitecture: ["arm64", "x64"],
    roles: ["verifier", "tester"],
    capabilities: ["git_ops", "test_runner"],
    permissions: ["fs:read", "fs:write", "process:spawn"],
    credentialRequirements: [
      {
        authMode: "none",
        sharingPolicy: "workspace_capable",
        required: false,
      },
    ],
    credentialSharingPolicy: "workspace_capable",
    configurationSchema: {},
    sessionModes: ["stateless", "isolated_workspace"],
    concurrencyModel: {
      maxConcurrentAssignments: 2,
      persistentRuntime: false,
      isolation: "process",
    },
    entrypoint: "bin/git_test_worker.dart",
    billingModes: ["free", "local_compute"],
    digest:
      "sha256:3333333333fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  };

  describe("First-Party Worker Manifests Validation", () => {
    it("validates Codex Worker manifest successfully", () => {
      const validated = validateWorkerManifest(sampleCodexManifest);
      expect(validated.workerId).toBe("codex");
      expect(validated.credentialRequirements[0]?.authMode).toBe(
        "oauth_browser",
      );
      expect(validated.credentialSharingPolicy).toBe("owner_controlled");
      expect(validated.sessionModes).toContain("isolated_workspace");
      expect(validated.concurrencyModel.maxConcurrentAssignments).toBe(4);
    });

    it("validates OpenAI Worker manifest successfully", () => {
      const validated = validateWorkerManifest(sampleOpenAIManifest);
      expect(validated.workerId).toBe("openai");
      expect(validated.credentialRequirements[0]?.authMode).toBe("api_key");
      expect(validated.credentialSharingPolicy).toBe("workspace_capable");
      expect(validated.concurrencyModel.isolation).toBe("thread");
    });

    it("validates Anthropic Worker manifest successfully", () => {
      const validated = validateWorkerManifest(sampleAnthropicManifest);
      expect(validated.workerId).toBe("anthropic");
      expect(validated.credentialRequirements[0]?.authMode).toBe("api_key");
    });

    it("validates a no-auth Worker manifest (local compute / free)", () => {
      const validated = validateWorkerManifest(sampleNoAuthManifest);
      expect(validated.workerId).toBe("git-test");
      expect(validated.credentialRequirements[0]?.authMode).toBe("none");
      expect(validated.billingModes).toContain("free");
    });

    it("accepts local CLI session and interactive/custom auth modes", () => {
      const cliManifest = validateWorkerManifest({
        ...sampleCodexManifest,
        workerId: "claude-code",
        credentialRequirements: [
          {
            authMode: "local_cli_session",
            sharingPolicy: "private_only",
          },
        ],
        credentialSharingPolicy: "private_only",
      });
      expect(cliManifest.credentialRequirements[0]?.authMode).toBe(
        "local_cli_session",
      );

      const customManifest = validateWorkerManifest({
        ...sampleCodexManifest,
        workerId: "custom-ai",
        credentialRequirements: [
          {
            authMode: "interactive/custom",
            sharingPolicy: "owner_controlled",
          },
        ],
      });
      expect(customManifest.credentialRequirements[0]?.authMode).toBe(
        "interactive_custom",
      );
    });
  });

  describe("Validation & Invariants Enforcement", () => {
    it("rejects invalid semantic versioning", () => {
      expect(() =>
        validateWorkerManifest({
          ...sampleCodexManifest,
          version: "v1.2",
        }),
      ).toThrow(/version must follow semantic versioning/);

      expect(() =>
        validateWorkerManifest({
          ...sampleCodexManifest,
          version: "1.0",
        }),
      ).toThrow(/version must follow semantic versioning/);

      expect(() =>
        validateWorkerManifest({
          ...sampleCodexManifest,
          version: "beta-1",
        }),
      ).toThrow(/version must follow semantic versioning/);
    });

    it("rejects invalid workerId format", () => {
      expect(() =>
        validateWorkerManifest({
          ...sampleCodexManifest,
          workerId: "INVALID ID WITH SPACES",
        }),
      ).toThrow(/workerId must be alphanumeric/);

      expect(() =>
        validateWorkerManifest({
          ...sampleCodexManifest,
          workerId: "",
        }),
      ).toThrow();
    });

    it("rejects invalid sharing policies", () => {
      expect(() =>
        validateWorkerManifest({
          ...sampleCodexManifest,
          credentialSharingPolicy:
            "public_to_internet" as WorkerCredentialSharingPolicy,
        }),
      ).toThrow();

      expect(() =>
        validateWorkerManifest({
          ...sampleCodexManifest,
          credentialRequirements: [
            {
              authMode: "api_key",
              sharingPolicy: "invalid_policy" as WorkerCredentialSharingPolicy,
            },
          ],
        }),
      ).toThrow();
    });

    it("rejects credential requirement sharing policy exceeding manifest private_only policy", () => {
      expect(() =>
        validateWorkerManifest({
          ...sampleCodexManifest,
          credentialSharingPolicy: "private_only",
          credentialRequirements: [
            {
              authMode: "api_key",
              sharingPolicy: "workspace_capable",
            },
          ],
        }),
      ).toThrow(/violates manifest 'private_only' policy/);
    });

    it("rejects invalid auth mode", () => {
      expect(() =>
        validateWorkerManifest({
          ...sampleCodexManifest,
          credentialRequirements: [
            {
              authMode: "magic_handshake" as WorkerCredentialAuthMode,
            },
          ],
        }),
      ).toThrow();
    });

    it("rejects empty roles or capabilities", () => {
      expect(() =>
        validateWorkerManifest({
          ...sampleCodexManifest,
          roles: [],
        }),
      ).toThrow(/At least one role is required/);

      expect(() =>
        validateWorkerManifest({
          ...sampleCodexManifest,
          capabilities: [],
        }),
      ).toThrow(/At least one capability is required/);
    });

    it("rejects invalid billing modes", () => {
      expect(() =>
        validateWorkerManifest({
          ...sampleCodexManifest,
          billingModes: ["invalid_mode" as unknown as WorkerBillingMode],
        }),
      ).toThrow();
    });

    it("supports release channels (stable, beta, development)", () => {
      const beta = validateWorkerManifest({
        ...sampleCodexManifest,
        channel: "beta",
      });
      expect(beta.channel).toBe("beta");

      const dev = validateWorkerManifest({
        ...sampleCodexManifest,
        channel: "development",
      });
      expect(dev.channel).toBe("development");
    });
  });

  describe("Host Compatibility Verification", () => {
    it("checks host compatibility against OS, Arch, and minimum host version", () => {
      const compatibleResult = isWorkerCompatibleWithHost(sampleCodexManifest, {
        os: "macos",
        architecture: "arm64",
        hostVersion: "0.2.0",
      });
      expect(compatibleResult.compatible).toBe(true);

      const incompatibleOS = isWorkerCompatibleWithHost(
        sampleAnthropicManifest,
        {
          os: "windows",
          architecture: "arm64",
          hostVersion: "0.2.0",
        },
      );
      expect(incompatibleOS.compatible).toBe(false);
      expect(incompatibleOS.reason).toMatch(
        /Host OS 'windows' is not supported/,
      );

      const incompatibleArch = isWorkerCompatibleWithHost(
        { ...sampleCodexManifest, supportedArchitecture: ["x64"] },
        {
          os: "macos",
          architecture: "arm64",
          hostVersion: "0.2.0",
        },
      );
      expect(incompatibleArch.compatible).toBe(false);
      expect(incompatibleArch.reason).toMatch(
        /Host architecture 'arm64' is not supported/,
      );

      const incompatibleHostVersion = isWorkerCompatibleWithHost(
        { ...sampleCodexManifest, minimumHostVersion: "0.3.0" },
        {
          os: "macos",
          architecture: "arm64",
          hostVersion: "0.1.0",
        },
      );
      expect(incompatibleHostVersion.compatible).toBe(false);
      expect(incompatibleHostVersion.reason).toMatch(
        /below minimum required version/,
      );
    });
  });

  describe("Semver Range Satisfaction", () => {
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

  describe("Backward Compatibility Translation", () => {
    it("translates legacy workerCatalogId and minimumAgentVersion seamlessly", () => {
      const legacyRaw = {
        workerCatalogId: "legacy-worker",
        version: "1.0.0",
        displayName: "Legacy Worker",
        publisher: "test",
        minimumAgentVersion: "0.2.0",
        supportedOS: ["macos"],
        supportedArchitecture: ["arm64"],
        roles: ["implementer"],
        capabilities: ["code_editing"],
        entrypoint: "dist/index.js",
        digest: "sha256:abc123",
      };

      const validated = validateWorkerManifest(legacyRaw);
      expect(validated.workerId).toBe("legacy-worker");
      expect(validated.minimumHostVersion).toBe("0.2.0");

      const comp = isWorkerCompatibleWithHost(validated, {
        os: "macos",
        architecture: "arm64",
        hostVersion: "0.2.5",
      });
      expect(comp.compatible).toBe(true);
    });
  });
});
