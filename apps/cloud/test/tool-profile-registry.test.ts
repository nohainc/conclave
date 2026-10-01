import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it, vi } from "vitest";
import {
  ToolProfileRegistryError,
  toolProfileReleaseSigningMessage,
  validateToolProfileAcceptanceEvidence,
  validateToolProfileReleasePayload,
  resolveLogicalWorkerCatalog,
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

describe("Tool Profile release payload admission", () => {
  it("binds identity and compatibility metadata to the signed payload digest", () => {
    const profile = validateToolProfileReleasePayload(fixture);
    const signingMessage = toolProfileReleaseSigningMessage({
      publisher: "conclave",
      signingKeyId: "profile-key-v1",
      payloadDigest: "a".repeat(64),
      profile,
    });
    expect(signingMessage).toContain("conclave-tool-profile-release-v1");
    expect(signingMessage).toContain('"logicalWorkerTypeId":"fixture-worker"');
    expect(signingMessage).toContain('"providerCompatibility":');
    expect(signingMessage).toContain('"signingKeyId":"profile-key-v1"');
  });

  it("accepts a canonical v1 fixture with provider secrets passed by name", () => {
    const profile = structuredClone(fixture) as Record<string, unknown>;
    const environment = profile.environment as Record<string, unknown>;
    environment.passthrough = ["OPENAI_API_KEY"];
    expect(() => validateToolProfileReleasePayload(profile)).not.toThrow();
  });

  it("rejects plaintext credentials before they can be stored in D1", () => {
    const profile = structuredClone(fixture) as Record<string, unknown>;
    const environment = profile.environment as Record<string, unknown>;
    environment.set = { OPENAI_API_KEY: "sk-proj-012345678901234567890123" };
    expect(() => validateToolProfileReleasePayload(profile)).toThrow(
      ToolProfileRegistryError,
    );

    environment.set = { NO_COLOR: "api_key=literal-secret-value" };
    expect(() => validateToolProfileReleasePayload(profile)).toThrow(
      /plaintext credential material/,
    );

    environment.set = {};
    environment.passthrough = ["WORKSPACE_API_TOKEN"];
    expect(() => validateToolProfileReleasePayload(profile)).toThrow(
      /reserved host environment names/,
    );
  });
});

describe("approved logical Worker catalog projection", () => {
  it("returns catalog metadata without requiring a published Profile release", async () => {
    const rows = [{
      worker_type_id: "fixture-worker",
      display_name: "Fixture Worker",
      description: "approved",
      engine_family: "cli",
      visibility_state: "visible",
      release_stage: "testing",
      capabilities_json: '["text","workstream_read"]',
      sort_order: 15,
      profile_definition_id: "fixture-cli",
      provider_tool_name: "fixture",
    }];
    const statement = {
      bind: vi.fn(function (this: unknown) { return this; }),
      all: vi.fn(async () => ({ results: rows })),
    };
    const db = { prepare: vi.fn(() => statement) } as unknown as D1Database;
    const result = await resolveLogicalWorkerCatalog(db, undefined, "testing");
    expect(result).toEqual([{
      workerTypeId: "fixture-worker",
      displayName: "Fixture Worker",
      description: "approved",
      engineFamily: "cli",
      visibilityState: "visible",
      releaseStage: "testing",
      capabilities: ["text", "workstream_read"],
      sortOrder: 15,
      profileDefinitionId: "fixture-cli",
      providerToolName: "fixture",
    }]);
    expect(statement.bind).toHaveBeenCalledWith("testing", null);
  });

  it("fails closed on an unknown product capability", async () => {
    const statement = {
      bind: vi.fn(function (this: unknown) { return this; }),
      all: vi.fn(async () => ({ results: [{
        worker_type_id: "fixture-worker", display_name: "Fixture",
        description: "", engine_family: "cli", visibility_state: "visible",
        release_stage: "stable", capabilities_json: '["run_shell"]',
        sort_order: 1, profile_definition_id: "fixture-cli",
        provider_tool_name: "fixture",
      }] })),
    };
    const db = { prepare: vi.fn(() => statement) } as unknown as D1Database;
    await expect(resolveLogicalWorkerCatalog(db)).rejects.toThrow(/capabilities are invalid/);
  });
});

describe("stable Tool Profile acceptance evidence", () => {
  const profile = validateToolProfileReleasePayload(fixture);
  const identity = { profileDefinitionId: "fixture-cli", releaseVersion: 1 };
  const evidence = {
    formatVersion: 1,
    profileDefinitionId: identity.profileDefinitionId,
    releaseVersion: identity.releaseVersion,
    profileReleaseVersion: "1",
    logicalWorkerTypeId: "fixture-worker",
    profileDigest: "a".repeat(64),
    engineVersion: "1.0.0",
    providerToolName: "Fixture CLI",
    providerToolVersion: "1.2.3",
    acceptedAt: new Date().toISOString(),
    scenarios: {
      passive_probe: "passed",
      live_probe: "passed",
      representative_workstream_write: "passed",
      durable_session_start: "passed",
      durable_session_resume: "passed",
      cancellation: "passed",
      timeout: "passed",
    },
  };

  it("accepts complete evidence bound to the exact release digest", () => {
    expect(
      validateToolProfileAcceptanceEvidence(evidence, {
        identity,
        payloadDigest: "a".repeat(64),
        profile,
      }),
    ).toMatchObject(evidence);
  });

  it("rejects missing scenarios, altered digests, and unsupported versions", () => {
    const incomplete = structuredClone(evidence);
    delete (incomplete.scenarios as Record<string, string>).cancellation;
    expect(() =>
      validateToolProfileAcceptanceEvidence(incomplete, {
        identity,
        payloadDigest: "a".repeat(64),
        profile,
      }),
    ).toThrow(ToolProfileRegistryError);

    expect(() =>
      validateToolProfileAcceptanceEvidence(
        { ...evidence, profileDigest: "b".repeat(64) },
        { identity, payloadDigest: "a".repeat(64), profile },
      ),
    ).toThrow(ToolProfileRegistryError);

    expect(() =>
      validateToolProfileAcceptanceEvidence(
        { ...evidence, providerToolVersion: "99.0.0" },
        { identity, payloadDigest: "a".repeat(64), profile },
      ),
    ).toThrow(ToolProfileRegistryError);
  });
});
