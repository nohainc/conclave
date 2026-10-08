import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it, vi } from "vitest";
import type { ToolProfileV1 } from "@conclave/tool-profile";
import {
  ToolProfileRegistryError,
  toolProfileReleaseSigningMessage,
  validateToolProfileAcceptanceEvidence,
  validateToolProfileReleasePayload,
  validateProviderCompatibilityForPublication,
  resolveLogicalWorkerCatalog,
  listAdminWorkerCatalog,
  listToolProfileDefinitions,
  getToolProfileDefinition,
  getToolProfileRelease,
  listToolProfileChannelPointers,
  rollbackToolProfileChannel,
  submitToolProfileReleaseEvidence,
  listToolProfileReleaseEvidence,
  listToolProfileAudit,
  promoteToolProfileRelease,
  submitToolProfileLocalQualification,
  publishDraftToolProfileRelease,
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
  it("requires configured, non-placeholder provider ranges for publication", () => {
    const profile = validateToolProfileReleasePayload(fixture);
    expect(() =>
      validateProviderCompatibilityForPublication(profile),
    ).not.toThrow();
    expect(() =>
      validateProviderCompatibilityForPublication({
        ...profile,
        providerTool: { ...profile.providerTool, supportedVersions: [] },
      }),
    ).toThrow(/must be configured/);
    expect(() =>
      validateProviderCompatibilityForPublication({
        ...profile,
        providerTool: {
          ...profile.providerTool,
          supportedVersions: [{ min: "0.0.1", maxExclusive: "99.0.0" }],
        },
      }),
    ).toThrow(/placeholder range/);
  });

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
      /reserved environment variable names/,
    );
  });
});

describe("approved logical Worker catalog projection", () => {
  it.each(["stable", "beta", "testing"] as const)(
    "resolves descriptors for the Workspace's %s channel",
    async (channel) => {
      let query = "";
      const statement = {
        bind: vi.fn(function (this: unknown) {
          return this;
        }),
        all: vi.fn(async () => ({ results: [] })),
      };
      const db = {
        prepare: vi.fn((sql: string) => {
          query = sql;
          return statement;
        }),
      } as unknown as D1Database;

      await expect(
        resolveLogicalWorkerCatalog(db, undefined, channel),
      ).resolves.toEqual([]);
      expect(statement.bind).toHaveBeenCalledWith(channel, null);
      expect(query).toContain("worker.release_stage IN ('beta','stable')");
      expect(query).toContain("worker.release_stage = 'stable'");
      expect(query).toContain("?1 = 'testing'");
    },
  );

  it("returns a new Cloud Worker descriptor without a code-level provider case", async () => {
    const rows = [
      {
        worker_type_id: "claude",
        display_name: "Claude",
        description: "Claude Code CLI integration",
        engine_family: "cli",
        visibility_state: "visible",
        release_stage: "testing",
        capabilities_json: '["text","thread_read"]',
        sort_order: 15,
        profile_definition_id: "claude-code",
        provider_tool_name: "claude",
      },
    ];
    const statement = {
      bind: vi.fn(function (this: unknown) {
        return this;
      }),
      all: vi.fn(async () => ({ results: rows })),
    };
    const db = { prepare: vi.fn(() => statement) } as unknown as D1Database;
    const result = await resolveLogicalWorkerCatalog(db, undefined, "testing");
    expect(result).toEqual([
      {
        workerTypeId: "claude",
        displayName: "Claude",
        description: "Claude Code CLI integration",
        engineFamily: "cli",
        visibilityState: "visible",
        releaseStage: "testing",
        capabilities: ["text", "thread_read"],
        sortOrder: 15,
        profileDefinitionId: "claude-code",
        providerToolName: "claude",
      },
    ]);
    expect(statement.bind).toHaveBeenCalledWith("testing", null);
  });

  it("fails closed on an unknown product capability", async () => {
    const statement = {
      bind: vi.fn(function (this: unknown) {
        return this;
      }),
      all: vi.fn(async () => ({
        results: [
          {
            worker_type_id: "fixture-worker",
            display_name: "Fixture",
            description: "",
            engine_family: "cli",
            visibility_state: "visible",
            release_stage: "stable",
            capabilities_json: '["run_shell"]',
            sort_order: 1,
            profile_definition_id: "fixture-cli",
            provider_tool_name: "fixture",
          },
        ],
      })),
    };
    const db = { prepare: vi.fn(() => statement) } as unknown as D1Database;
    await expect(resolveLogicalWorkerCatalog(db)).rejects.toThrow(
      /capabilities are invalid/,
    );
  });

  it("normalizes retired workstream capability names from persisted catalogs", async () => {
    const statement = {
      bind: vi.fn(function (this: unknown) {
        return this;
      }),
      all: vi.fn(async () => ({
        results: [
          {
            worker_type_id: "legacy-worker",
            display_name: "Legacy Worker",
            description: "",
            engine_family: "cli",
            visibility_state: "visible",
            release_stage: "stable",
            capabilities_json: '["text","workstream_read","workstream_write"]',
            sort_order: 1,
            profile_definition_id: "legacy-cli",
            provider_tool_name: "legacy",
          },
        ],
      })),
    };
    const db = { prepare: vi.fn(() => statement) } as unknown as D1Database;

    await expect(resolveLogicalWorkerCatalog(db)).resolves.toMatchObject([
      {
        workerTypeId: "legacy-worker",
        capabilities: ["text", "thread_read", "thread_write"],
      },
    ]);
  });
});

describe("stable Tool Profile acceptance evidence", () => {
  const profile = validateToolProfileReleasePayload(fixture);
  const identity = { profileDefinitionId: "fixture-cli", releaseVersion: 1 };
  const evidence = {
    formatVersion: 2,
    profileDefinitionId: identity.profileDefinitionId,
    releaseVersion: identity.releaseVersion,
    profileReleaseVersion: "1",
    logicalWorkerTypeId: "fixture-worker",
    profileDigest: "a".repeat(64),
    engineVersion: "1.0.0",
    providerToolName: "Fixture CLI",
    providerToolVersion: "0.3.0",
    acceptedAt: new Date().toISOString(),
    scenarios: {
      passive_probe: "passed",
      live_probe: "passed",
      model_selection: "not_applicable",
      representative_thread_write: "not_applicable",
      durable_session_start: "not_applicable",
      durable_session_resume: "not_applicable",
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

  it("rejects incomplete local qualification scenarios", () => {
    const incomplete = {
      ...evidence,
      scenarios: { ...evidence.scenarios, live_probe: "not_applicable" },
    };
    expect(() =>
      validateToolProfileAcceptanceEvidence(
        incomplete,
        {
          identity,
          payloadDigest: "a".repeat(64),
          profile,
        },
        "local qualification",
      ),
    ).toThrow(
      /Draft publication requires a complete local execution qualification/,
    );
  });

  it("stores complete local qualification immutably against a draft digest", async () => {
    const draftRow = {
      payload_digest: "a".repeat(64),
      payload_json: JSON.stringify(fixture),
      worker_type_id: "fixture-worker",
      lifecycle_state: "draft",
      published_at: null,
    };
    const statement = {
      bind: vi.fn(function (this: unknown) {
        return this;
      }),
      first: vi.fn(async () => draftRow),
      run: vi.fn(async () => ({ meta: { changes: 1 } })),
    };
    const db = {
      prepare: vi.fn(() => statement),
    } as unknown as D1Database;
    const result = await submitToolProfileLocalQualification(
      db,
      identity,
      evidence,
      "admin-1",
    );

    expect(result).toMatchObject({
      status: "qualified",
      payloadDigest: "a".repeat(64),
    });
    expect(result.qualificationEvidenceId).toBeTruthy();
    expect(statement.run).toHaveBeenCalledOnce();
    expect(statement.bind).toHaveBeenCalledWith(
      result.qualificationEvidenceId,
      identity.profileDefinitionId,
      identity.releaseVersion,
      "a".repeat(64),
      "1.0.0",
      "0.3.0",
      JSON.stringify(evidence),
      "admin-1",
      evidence.acceptedAt,
      expect.any(String),
    );
  });

  it("does not publish without a stored local qualification ID", async () => {
    await expect(
      publishDraftToolProfileRelease(
        {} as unknown as Parameters<typeof publishDraftToolProfileRelease>[0],
        identity,
        "admin-1",
        "",
      ),
    ).rejects.toMatchObject({
      status: 409,
      message: expect.stringContaining("qualificationEvidenceId is required"),
    });
  });

  it("promotes only by a stored qualifying evidence ID", async () => {
    const acceptedAt = new Date().toISOString();
    const storedEvidence = { ...evidence, acceptedAt };
    const releaseRow = {
      lifecycle_state: "beta",
      published_at: acceptedAt,
      payload_digest: "a".repeat(64),
      payload_json: JSON.stringify(fixture),
      worker_type_id: "fixture-worker",
    };
    const evidenceRow = {
      id: "evidence-1",
      payload_digest: "a".repeat(64),
      engine_version: "1.0.0",
      provider_tool_version: "0.3.0",
      evidence_json: JSON.stringify(storedEvidence),
      accepted_at: acceptedAt,
    };
    const preparedSql: string[] = [];
    const batch = vi.fn(async (statements: unknown[]) =>
      statements.map(() => ({ meta: { changes: 1 } })),
    );
    const db = {
      prepare: vi.fn((sql: string) => {
        preparedSql.push(sql);
        return {
          bind: vi.fn(() => ({
            first: vi.fn(async () => {
              if (sql.includes("FROM tool_profile_releases")) return releaseRow;
              if (sql.includes("FROM tool_profile_acceptance_evidence")) {
                return evidenceRow;
              }
              return null;
            }),
          })),
        };
      }),
      batch,
    } as unknown as D1Database;

    const result = await promoteToolProfileRelease(
      db,
      identity,
      "stable",
      "admin-1",
      "evidence-1",
    );
    expect(result).toMatchObject({
      channel: "stable",
      releaseVersion: 1,
      acceptanceEvidenceId: "evidence-1",
    });
    expect(
      preparedSql.some((sql) =>
        sql.includes("INSERT INTO tool_profile_acceptance_evidence"),
      ),
    ).toBe(false);
    expect(batch).toHaveBeenCalledOnce();
  });

  it("rejects unknown, mismatched, or ad-hoc evidence at promotion", async () => {
    const releaseRow = {
      lifecycle_state: "beta",
      published_at: new Date().toISOString(),
      payload_digest: "a".repeat(64),
      payload_json: JSON.stringify(fixture),
      worker_type_id: "fixture-worker",
    };
    const db = {
      prepare: vi.fn((sql: string) => ({
        bind: vi.fn(() => ({
          first: vi.fn(async () =>
            sql.includes("FROM tool_profile_releases") ? releaseRow : null,
          ),
        })),
      })),
      batch: vi.fn(),
    } as unknown as D1Database;

    await expect(
      promoteToolProfileRelease(
        db,
        identity,
        "stable",
        "admin-1",
        "unknown-evidence",
      ),
    ).rejects.toThrow(/Stored acceptance evidence does not qualify/);
    await expect(
      promoteToolProfileRelease(db, identity, "stable", "admin-1", {
        ...evidence,
      } as unknown as string),
    ).rejects.toThrow(/stored acceptanceEvidenceId is required/);
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

  it("derives optional scenario applicability from Profile capabilities", () => {
    const modelProfile = structuredClone(profile) as ToolProfileV1;
    modelProfile.model.supported = true;
    modelProfile.model.allowlist = ["fixture-model"];
    const modelEvidence = {
      ...evidence,
      scenarios: { ...evidence.scenarios, model_selection: "passed" },
    };
    expect(
      validateToolProfileAcceptanceEvidence(modelEvidence, {
        identity,
        payloadDigest: "a".repeat(64),
        profile: modelProfile,
      }),
    ).toMatchObject(modelEvidence);

    const threadProfile = structuredClone(profile) as ToolProfileV1;
    (threadProfile.capabilities as string[]).push("thread_write");
    const applicableEvidence = {
      ...evidence,
      scenarios: {
        ...evidence.scenarios,
        representative_thread_write: "passed",
      },
    };
    expect(
      validateToolProfileAcceptanceEvidence(applicableEvidence, {
        identity,
        payloadDigest: "a".repeat(64),
        profile: threadProfile,
      }),
    ).toMatchObject(applicableEvidence);

    const sessionProfile = structuredClone(profile) as ToolProfileV1;
    (sessionProfile.capabilities as string[]).push("durable_session");
    sessionProfile.session.supported = true;
    const sessionEvidence = {
      ...evidence,
      scenarios: {
        ...evidence.scenarios,
        durable_session_start: "passed",
        durable_session_resume: "passed",
      },
    };
    expect(
      validateToolProfileAcceptanceEvidence(sessionEvidence, {
        identity,
        payloadDigest: "a".repeat(64),
        profile: sessionProfile,
      }),
    ).toMatchObject(sessionEvidence);

    expect(() =>
      validateToolProfileAcceptanceEvidence(
        {
          ...evidence,
          scenarios: {
            ...evidence.scenarios,
            representative_thread_write: "passed",
          },
        },
        { identity, payloadDigest: "a".repeat(64), profile },
      ),
    ).toThrow(
      /Stable promotion requires complete real Profile acceptance evidence/,
    );

    const inconsistentSessionProfile = structuredClone(
      profile,
    ) as ToolProfileV1;
    (inconsistentSessionProfile.capabilities as string[]).push(
      "durable_session",
    );
    expect(() =>
      validateToolProfileAcceptanceEvidence(evidence, {
        identity,
        payloadDigest: "a".repeat(64),
        profile: inconsistentSessionProfile,
      }),
    ).toThrow(
      /Stable promotion requires complete real Profile acceptance evidence/,
    );
  });
});

describe("Phase 7 Profile Admin read models and operations", () => {
  it("lists all administrative workers in worker_catalog", async () => {
    const rows = [
      {
        worker_type_id: "claude",
        display_name: "Claude Code",
        description: "Anthropic Claude CLI integration",
        lifecycle_state: "active",
        engine_family: "cli",
        visibility_state: "visible",
        release_stage: "beta",
        capabilities_json: '["text","tools"]',
        sort_order: 10,
        created_at: "2026-01-01T00:00:00.000Z",
        updated_at: "2026-01-01T00:00:00.000Z",
        profile_definition_id: "claude-code",
        provider_tool_name: "claude",
      },
    ];
    const statement = {
      all: vi.fn(async () => ({ results: rows })),
    };
    const db = { prepare: vi.fn(() => statement) } as unknown as D1Database;

    const result = await listAdminWorkerCatalog(db);
    expect(result.workers).toHaveLength(1);
    expect(result.workers[0]).toMatchObject({
      workerTypeId: "claude",
      displayName: "Claude Code",
      capabilities: ["text", "tools"],
      profileDefinitionId: "claude-code",
      providerToolName: "claude",
      releaseStage: "beta",
    });
  });

  it("lists tool profile definitions with aggregated channels and release counts", async () => {
    const defRows = [
      {
        profile_definition_id: "claude-code",
        worker_type_id: "claude",
        display_name: "Claude Code Profile",
        provider_tool_name: "claude",
        engine_family: "cli",
        schema_version: 1,
        lifecycle_state: "active",
        created_by_user_id: "admin-1",
        created_at: "2026-01-01T00:00:00.000Z",
        updated_at: "2026-01-01T00:00:00.000Z",
        worker_display_name: "Claude Code",
        worker_release_stage: "beta",
        latest_release_version: 3,
        release_count: 3,
      },
    ];
    const pointerRows = [
      {
        profile_definition_id: "claude-code",
        channel: "beta",
        release_version: 3,
      },
      {
        profile_definition_id: "claude-code",
        channel: "testing",
        release_version: 3,
      },
    ];

    const db = {
      prepare: vi.fn((sql: string) => {
        if (sql.includes("tool_profile_definitions")) {
          return { all: vi.fn(async () => ({ results: defRows })) };
        }
        return { all: vi.fn(async () => ({ results: pointerRows })) };
      }),
    } as unknown as D1Database;

    const result = await listToolProfileDefinitions(db);
    expect(result.definitions).toHaveLength(1);
    expect(result.definitions![0]!.channels).toEqual({ beta: 3, testing: 3 });
    expect(result.definitions![0]!.latestReleaseVersion).toBe(3);
    expect(result.definitions![0]!.releaseCount).toBe(3);
  });

  it("retrieves a single tool profile definition by id", async () => {
    const defRow = {
      profile_definition_id: "claude-code",
      worker_type_id: "claude",
      display_name: "Claude Code Profile",
      provider_tool_name: "claude",
      engine_family: "cli",
      schema_version: 1,
      lifecycle_state: "active",
      created_by_user_id: "admin-1",
      created_at: "2026-01-01T00:00:00.000Z",
      updated_at: "2026-01-01T00:00:00.000Z",
      worker_display_name: "Claude Code",
      worker_release_stage: "beta",
      latest_release_version: 2,
      release_count: 2,
    };
    const pointerRows = [
      { channel: "stable", release_version: 1 },
      { channel: "beta", release_version: 2 },
    ];

    const db = {
      prepare: vi.fn((sql: string) => {
        if (sql.includes("tool_profile_definitions")) {
          return {
            bind: vi.fn(() => ({ first: vi.fn(async () => defRow) })),
          };
        }
        return {
          bind: vi.fn(() => ({
            all: vi.fn(async () => ({ results: pointerRows })),
          })),
        };
      }),
    } as unknown as D1Database;

    const result = await getToolProfileDefinition(db, "claude-code");
    expect(result.profileDefinitionId).toBe("claude-code");
    expect(result.channels).toEqual({ stable: 1, beta: 2 });
  });

  it("throws 404 when tool profile definition is not found", async () => {
    const db = {
      prepare: vi.fn(() => ({
        bind: vi.fn(() => ({
          first: vi.fn(async () => null),
          all: vi.fn(async () => ({ results: [] })),
        })),
      })),
    } as unknown as D1Database;

    await expect(getToolProfileDefinition(db, "nonexistent")).rejects.toThrow(
      /Tool Profile definition was not found/,
    );
  });

  it("retrieves a single tool profile release with parsed profile", async () => {
    const releaseRow = {
      release_version: 1,
      worker_type_id: "fixture-worker",
      lifecycle_state: "stable",
      schema_version: 1,
      engine_family: "cli",
      engine_compatibility_min: "1.0.0",
      engine_compatibility_max_exclusive: "2.0.0",
      payload_json: JSON.stringify(fixture),
      payload_digest: "a".repeat(64),
      signature: "sig123",
      signing_key_id: "key-1",
      publisher: "conclave",
      published_at: "2026-01-01T00:00:00.000Z",
      lifecycle_reason: "Promoted to stable",
      revoked_at: null,
      created_by_user_id: "admin-1",
      updated_by_user_id: "admin-1",
      created_at: "2026-01-01T00:00:00.000Z",
      updated_at: "2026-01-01T00:00:00.000Z",
      acceptance_evidence_json: null,
    };

    const db = {
      prepare: vi.fn(() => ({
        bind: vi.fn(() => ({
          first: vi.fn(async () => releaseRow),
        })),
      })),
    } as unknown as D1Database;

    const result = await getToolProfileRelease(db, {
      profileDefinitionId: "fixture-cli",
      releaseVersion: 1,
    });
    expect(result.releaseVersion).toBe(1);
    expect(result.lifecycleState).toBe("stable");
    expect(result.payloadDigest).toBe("a".repeat(64));
    expect(result.profile).toEqual(fixture);
  });

  it("lists and queries channel pointers", async () => {
    const pointers = [
      {
        profile_definition_id: "fixture-cli",
        channel: "stable",
        release_version: 2,
        modified_by_user_id: "admin-1",
        updated_at: "2026-01-01T00:00:00.000Z",
      },
    ];
    const db = {
      prepare: vi.fn(() => ({
        bind: vi.fn(() => ({
          all: vi.fn(async () => ({ results: pointers })),
        })),
      })),
    } as unknown as D1Database;

    const allChannels = await listToolProfileChannelPointers(db);
    expect(allChannels.channels).toHaveLength(1);
    expect(allChannels.channels![0]!.releaseVersion).toBe(2);

    const filtered = await listToolProfileChannelPointers(db, "fixture-cli");
    expect(filtered.channels).toHaveLength(1);
  });

  it("performs safe channel pointer rollback", async () => {
    const currentPointer = { release_version: 3 };
    const targetRelease = {
      release_version: 2,
      lifecycle_state: "stable",
      published_at: "2026-01-01T00:00:00.000Z",
    };

    const batchMock = vi.fn(async () => [{ meta: { changes: 1 } }]);
    const db = {
      prepare: vi.fn((sql: string) => ({
        bind: vi.fn(() => ({
          first: vi.fn(async () => {
            if (sql.includes("tool_profile_channel_pointers")) {
              return currentPointer;
            }
            return targetRelease;
          }),
        })),
      })),
      batch: batchMock,
    } as unknown as D1Database;

    const rollbackResult = await rollbackToolProfileChannel(db, {
      profileDefinitionId: "fixture-cli",
      channel: "stable",
      targetReleaseVersion: 2,
      actorUserId: "admin-1",
      reason: "Emergency rollback due to regression",
    });

    expect(rollbackResult).toEqual({
      profileDefinitionId: "fixture-cli",
      channel: "stable",
      releaseVersion: 2,
      previousReleaseVersion: 3,
      action: "rolled_back",
    });
    expect(batchMock).toHaveBeenCalledOnce();
  });

  it("rejects rollback when channel pointer already points to target version", async () => {
    const db = {
      prepare: vi.fn(() => ({
        bind: vi.fn(() => ({
          first: vi.fn(async () => ({ release_version: 2 })),
        })),
      })),
    } as unknown as D1Database;

    await expect(
      rollbackToolProfileChannel(db, {
        profileDefinitionId: "fixture-cli",
        channel: "stable",
        targetReleaseVersion: 2,
        actorUserId: "admin-1",
      }),
    ).rejects.toThrow(/already at the requested release version/);
  });

  it("submits and lists acceptance evidence bound to release digest", async () => {
    const _profile = validateToolProfileReleasePayload(fixture);
    const identity = { profileDefinitionId: "fixture-cli", releaseVersion: 1 };
    const digest = "a".repeat(64);
    const validEvidence = {
      formatVersion: 2,
      profileDefinitionId: identity.profileDefinitionId,
      releaseVersion: identity.releaseVersion,
      profileReleaseVersion: "1",
      logicalWorkerTypeId: "fixture-worker",
      profileDigest: digest,
      engineVersion: "1.0.0",
      providerToolName: "Fixture CLI",
      providerToolVersion: "0.3.0",
      acceptedAt: new Date().toISOString(),
      scenarios: {
        passive_probe: "passed",
        live_probe: "passed",
        model_selection: "not_applicable",
        representative_thread_write: "not_applicable",
        durable_session_start: "not_applicable",
        durable_session_resume: "not_applicable",
        cancellation: "passed",
        timeout: "passed",
      },
    };

    const releaseRow = {
      release_version: 1,
      payload_digest: digest,
      payload_json: JSON.stringify(fixture),
      worker_type_id: "fixture-worker",
      lifecycle_state: "testing",
      published_at: new Date().toISOString(),
    };

    const runMock = vi.fn(async () => ({ meta: { changes: 1 } }));
    const db = {
      prepare: vi.fn((sql: string) => ({
        bind: vi.fn(() => ({
          first: vi.fn(async () => {
            if (sql.includes("tool_profile_releases")) return releaseRow;
            return null;
          }),
          run: runMock,
          all: vi.fn(async () => ({
            results: [
              {
                id: "evidence-1",
                profile_definition_id: identity.profileDefinitionId,
                release_version: 1,
                payload_digest: digest,
                engine_version: "1.0.0",
                provider_tool_version: "0.3.0",
                evidence_json: JSON.stringify(validEvidence),
                submitted_by_user_id: "admin-1",
                accepted_at: validEvidence.acceptedAt,
                submitted_at: validEvidence.acceptedAt,
              },
            ],
          })),
        })),
      })),
    } as unknown as D1Database;

    const submission = await submitToolProfileReleaseEvidence(
      db,
      identity,
      validEvidence,
      "admin-1",
    );
    expect(submission.status).toBe("accepted");
    expect(submission.payloadDigest).toBe(digest);
    const nextSubmission = await submitToolProfileReleaseEvidence(
      db,
      identity,
      validEvidence,
      "admin-1",
    );
    expect(nextSubmission.status).toBe("accepted");
    expect(nextSubmission.id).not.toBe(submission.id);
    expect(runMock).toHaveBeenCalledTimes(2);

    const evidenceList = await listToolProfileReleaseEvidence(db, identity);
    expect(evidenceList.evidence).toHaveLength(1);
    expect(evidenceList.evidence![0]!.payloadDigest).toBe(digest);
  });

  it("submits the canonical evidence contract and rejects extras or secrets", async () => {
    const identity = { profileDefinitionId: "fixture-cli", releaseVersion: 1 };
    const digest = "a".repeat(64);
    const normalizedEvidence = {
      formatVersion: 2,
      profileDefinitionId: identity.profileDefinitionId,
      releaseVersion: identity.releaseVersion,
      profileReleaseVersion: "1",
      logicalWorkerTypeId: "fixture-worker",
      profileDigest: digest,
      engineVersion: "1.0.0",
      providerToolName: "Fixture CLI",
      providerToolVersion: "0.3.0",
      acceptedAt: new Date().toISOString(),
      scenarios: {
        passive_probe: "passed",
        live_probe: "passed",
        model_selection: "not_applicable",
        representative_thread_write: "not_applicable",
        durable_session_start: "not_applicable",
        durable_session_resume: "not_applicable",
        cancellation: "passed",
        timeout: "passed",
      },
    };

    const releaseRow = {
      release_version: 1,
      payload_digest: digest,
      payload_json: JSON.stringify(fixture),
      worker_type_id: "fixture-worker",
      lifecycle_state: "testing",
      published_at: new Date().toISOString(),
    };

    const runMock = vi.fn(async () => ({ meta: { changes: 1 } }));
    const db = {
      prepare: vi.fn((sql: string) => ({
        bind: vi.fn(() => ({
          first: vi.fn(async () => {
            if (sql.includes("tool_profile_releases")) return releaseRow;
            return null;
          }),
          run: runMock,
        })),
      })),
    } as unknown as D1Database;

    const submission = await submitToolProfileReleaseEvidence(
      db,
      identity,
      normalizedEvidence,
      "admin-1",
    );
    expect(submission.status).toBe("accepted");

    await expect(
      submitToolProfileReleaseEvidence(
        db,
        identity,
        { ...normalizedEvidence, normalizedResult: "pass" },
        "admin-1",
      ),
    ).rejects.toThrow(ToolProfileRegistryError);

    // Must reject raw provider secrets or env dumps
    const dirtyEvidence = {
      ...normalizedEvidence,
      env: { PATH: "/usr/bin", SECRET_KEY: "supersecret" },
    };

    await expect(
      submitToolProfileReleaseEvidence(db, identity, dirtyEvidence, "admin-1"),
    ).rejects.toThrow(/forbidden in Cloud evidence/);
  });

  it("lists global and definition audit events", async () => {
    const auditRows = [
      {
        id: "audit-1",
        profile_definition_id: "fixture-cli",
        release_version: 1,
        actor_user_id: "admin-1",
        actor_display_name: "Vitalii",
        worker_display_name: "ChatGPT",
        action: "draft_created",
        previous_release_version: null,
        channel: null,
        from_state: null,
        to_state: "draft",
        reason: null,
        details_json: "{}",
        created_at: "2026-01-01T00:00:00.000Z",
      },
    ];
    const db = {
      prepare: vi.fn(() => ({
        bind: vi.fn(() => ({
          all: vi.fn(async () => ({ results: auditRows })),
        })),
      })),
    } as unknown as D1Database;

    const globalAudit = await listToolProfileAudit(db);
    expect(globalAudit.events).toHaveLength(1);
    expect(globalAudit.events![0]!.action).toBe("draft_created");
    expect(globalAudit.events[0]!.actorDisplayName).toBe("Vitalii");
    expect(globalAudit.events[0]!.workerDisplayName).toBe("ChatGPT");

    const defAudit = await listToolProfileAudit(db, "fixture-cli");
    expect(defAudit.events).toHaveLength(1);
  });
});
