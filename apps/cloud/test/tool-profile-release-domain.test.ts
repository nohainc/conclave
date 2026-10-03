import { execFileSync, spawnSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const migrationRoot = fileURLToPath(
  new URL("../migrations-v8/", import.meta.url),
);
const migrations = readdirSync(migrationRoot)
  .filter((file) => /^\d+.*\.sql$/.test(file))
  .sort()
  .map((file) => readFileSync(`${migrationRoot}${file}`, "utf8"))
  .join("\n");

function apply(sql: string): unknown[] {
  return JSON.parse(
    execFileSync("sqlite3", ["-bail", "-json", ":memory:"], {
      input: `${migrations}\n${sql}`,
      encoding: "utf8",
    }),
  ) as unknown[];
}

function expectSqlFailure(sql: string, message: string): void {
  const result = spawnSync("sqlite3", ["-json", ":memory:"], {
    input: `${migrations}\n${sql}`,
    encoding: "utf8",
  });
  expect(result.stderr).toContain(message);
}

function profileRelease(version: number, state: string, time: string): string {
  return `
    INSERT INTO tool_profile_releases (
      profile_definition_id, release_version, worker_type_id, lifecycle_state,
      schema_version, engine_family, engine_compatibility_min,
      engine_compatibility_max_exclusive, payload_json, payload_digest,
      signature, signing_key_id, publisher, published_at, created_at, updated_at
    ) VALUES (
      'chatgpt-codex', ${version}, 'chatgpt', '${state}', 1, 'cli',
      '1.0.0', '2.0.0', '{"releaseVersion":${version}}', '${String(version).padStart(64, "0")}',
      ${state === "draft" ? "NULL, NULL, NULL, NULL" : "'sig', 'key-1', 'conclave', '" + time + "'"},
      '${time}', '${time}'
    );
  `;
}

function publishedRelease(version: number): string {
  const time = `2026-10-0${version}T00:00:00Z`;
  return `
    ${profileRelease(version, "draft", time)}
    UPDATE tool_profile_releases
       SET lifecycle_state = 'testing', signature = 'sig',
           signing_key_id = 'key-1', publisher = 'conclave', published_at = '${time}'
     WHERE profile_definition_id = 'chatgpt-codex' AND release_version = ${version};
  `;
}

describe("v8 Tool Profile Cloud release domain", () => {
  it("seeds bounded v8 logical Worker metadata and rejects arbitrary enum values", () => {
    expect(
      apply(`
      SELECT worker_type_id, engine_family, visibility_state, release_stage,
             capabilities_json, sort_order FROM worker_catalog ORDER BY sort_order;
    `),
    ).toEqual([
      {
        worker_type_id: "chatgpt",
        engine_family: "cli",
        visibility_state: "visible",
        release_stage: "stable",
        capabilities_json:
          '["text","local_file","workstream_read","workstream_write","durable_session"]',
        sort_order: 10,
      },
      {
        worker_type_id: "gemini",
        engine_family: "cli",
        visibility_state: "visible",
        release_stage: "stable",
        capabilities_json:
          '["text","local_file","workstream_read","workstream_write","durable_session"]',
        sort_order: 20,
      },
    ]);
    expectSqlFailure(
      `UPDATE worker_catalog SET release_stage = 'private' WHERE worker_type_id = 'chatgpt';`,
      "CHECK constraint failed",
    );
    expectSqlFailure(
      `UPDATE worker_catalog SET engine_family = 'shell' WHERE worker_type_id = 'chatgpt';`,
      "CHECK constraint failed",
    );
    expectSqlFailure(
      `
      INSERT INTO tool_profile_definitions (
        profile_definition_id, worker_type_id, display_name, provider_tool_name,
        engine_family, schema_version, created_at, updated_at
      ) VALUES ('chatgpt-second', 'chatgpt', 'Second profile', 'other-cli', 'cli', 1, 'now', 'now');
    `,
      "UNIQUE constraint failed",
    );
  });

  it("seeds logical Workers and the initial official Profile definitions", () => {
    expect(
      apply(`
        SELECT 'worker' AS kind, worker_type_id AS id, display_name AS name, '' AS parent, '' AS tool
          FROM worker_catalog
        UNION ALL
        SELECT 'definition', profile_definition_id, '', worker_type_id, provider_tool_name
          FROM tool_profile_definitions
        ORDER BY kind, id;
      `),
    ).toEqual([
      {
        kind: "definition",
        id: "chatgpt-codex",
        name: "",
        parent: "chatgpt",
        tool: "codex",
      },
      {
        kind: "definition",
        id: "gemini-antigravity",
        name: "",
        parent: "gemini",
        tool: "agy",
      },
      {
        kind: "worker",
        id: "chatgpt",
        name: "ChatGPT",
        parent: "",
        tool: "",
      },
      {
        kind: "worker",
        id: "gemini",
        name: "Gemini",
        parent: "",
        tool: "",
      },
    ]);
  });

  it("preserves Worker identity when its implementation Definition is replaced", () => {
    expect(
      apply(`
        UPDATE tool_profile_definitions
           SET lifecycle_state = 'retired', updated_at = 'now'
         WHERE profile_definition_id = 'chatgpt-codex';
        INSERT INTO tool_profile_definitions (
          profile_definition_id, worker_type_id, display_name,
          provider_tool_name, engine_family, schema_version, lifecycle_state,
          created_at, updated_at
        ) VALUES (
          'chatgpt-next-cli', 'chatgpt', 'Replacement CLI',
          'next-cli', 'cli', 1, 'active', 'now', 'now'
        );
        SELECT worker.worker_type_id, worker.display_name,
               definition.profile_definition_id, definition.provider_tool_name
          FROM worker_catalog worker
          JOIN tool_profile_definitions definition
            ON definition.worker_type_id = worker.worker_type_id
         WHERE worker.worker_type_id = 'chatgpt'
           AND definition.lifecycle_state = 'active';
      `),
    ).toEqual([
      {
        worker_type_id: "chatgpt",
        display_name: "ChatGPT",
        profile_definition_id: "chatgpt-next-cli",
        provider_tool_name: "next-cli",
      },
    ]);
  });

  it("defaults Workspaces to stable and stores explicit testing or beta opt-ins", () => {
    const defaultChannel = apply(`
        INSERT INTO users (id, email, display_name, status, created_at, updated_at)
        VALUES ('u-channel', 'channel@example.test', 'Channel Admin', 'active', '2026-10-01', '2026-10-01');
        INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at)
        VALUES ('workspace-channel', 'u-channel', 'Internal Test', 'offline', '2026-10-01', '2026-10-01');
        SELECT ew.id, COALESCE(channel.channel, 'stable') AS selected
          FROM execution_workspaces ew
          LEFT JOIN workspace_tool_profile_channels channel ON channel.workspace_id = ew.id
         WHERE ew.id = 'workspace-channel';
      `);
    expect(defaultChannel).toEqual([
      { id: "workspace-channel", selected: "stable" },
    ]);

    const optedInChannel = apply(`
        INSERT INTO users (id, email, display_name, status, created_at, updated_at)
        VALUES ('u-channel', 'channel@example.test', 'Channel Admin', 'active', '2026-10-01', '2026-10-01');
        INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at)
        VALUES ('workspace-channel', 'u-channel', 'Internal Test', 'offline', '2026-10-01', '2026-10-01');
        INSERT INTO workspace_tool_profile_channels
          (workspace_id, channel, updated_by_user_id, updated_at)
        VALUES ('workspace-channel', 'testing', 'u-channel', '2026-10-02');
        UPDATE workspace_tool_profile_channels SET channel = 'beta'
         WHERE workspace_id = 'workspace-channel';
        SELECT workspace_id, channel FROM workspace_tool_profile_channels;
      `);
    expect(optedInChannel).toEqual([
      { workspace_id: "workspace-channel", channel: "beta" },
    ]);
  });

  it("rejects arbitrary Workspace Profile channel values", () => {
    expectSqlFailure(
      `
        INSERT INTO users (id, email, display_name, status, created_at, updated_at)
        VALUES ('u-channel', 'channel@example.test', 'Channel Admin', 'active', '2026-10-01', '2026-10-01');
        INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at)
        VALUES ('workspace-channel', 'u-channel', 'Internal Test', 'offline', '2026-10-01', '2026-10-01');
        INSERT INTO workspace_tool_profile_channels
          (workspace_id, channel, updated_by_user_id, updated_at)
        VALUES ('workspace-channel', 'development', 'u-channel', '2026-10-02');
      `,
      "CHECK constraint failed",
    );
  });

  it("stores immutable releases and audits stable promotion and rollback", () => {
    const result = apply(`
      INSERT INTO users (id, email, display_name, status, created_at, updated_at)
      VALUES ('u1', 'admin@example.test', 'Admin', 'active', '2026-10-01', '2026-10-01');
      ${profileRelease(1, "draft", "2026-10-01T00:00:00Z")}
      UPDATE tool_profile_releases
         SET lifecycle_state = 'testing', signature = 'sig', signing_key_id = 'key-1', publisher = 'conclave',
             published_at = '2026-10-01T00:01:00Z'
       WHERE profile_definition_id = 'chatgpt-codex' AND release_version = 1;
      UPDATE tool_profile_releases SET lifecycle_state = 'stable'
       WHERE profile_definition_id = 'chatgpt-codex' AND release_version = 1;
      INSERT INTO tool_profile_channel_pointers
        (profile_definition_id, channel, release_version, updated_at)
      VALUES ('chatgpt-codex', 'stable', 1, '2026-10-01T00:02:00Z');

      ${profileRelease(2, "draft", "2026-10-02T00:00:00Z")}
      UPDATE tool_profile_releases
         SET lifecycle_state = 'testing', signature = 'sig', signing_key_id = 'key-1', publisher = 'conclave',
             published_at = '2026-10-02T00:01:00Z'
       WHERE profile_definition_id = 'chatgpt-codex' AND release_version = 2;
      UPDATE tool_profile_releases SET lifecycle_state = 'stable'
       WHERE profile_definition_id = 'chatgpt-codex' AND release_version = 2;
      UPDATE tool_profile_channel_pointers
         SET release_version = 2, updated_at = '2026-10-02T00:02:00Z'
       WHERE profile_definition_id = 'chatgpt-codex' AND channel = 'stable';

      UPDATE tool_profile_channel_pointers
         SET release_version = 1, updated_at = '2026-10-03T00:00:00Z'
       WHERE profile_definition_id = 'chatgpt-codex' AND channel = 'stable';
      SELECT 'pointer' AS kind, CAST(release_version AS TEXT) AS value, '' AS action,
             '' AS previous_release_version
        FROM tool_profile_channel_pointers
       WHERE profile_definition_id = 'chatgpt-codex' AND channel = 'stable'
      UNION ALL
      SELECT 'audit', '', action, COALESCE(CAST(previous_release_version AS TEXT), '')
        FROM tool_profile_release_audit
       WHERE action IN ('promoted_to_stable', 'channel_promoted', 'stable_rollback')
      UNION ALL
      SELECT 'count', CAST(COUNT(*) AS TEXT), '', '' FROM tool_profile_releases
       WHERE profile_definition_id = 'chatgpt-codex';
    `) as {
      kind: string;
      value: string;
      action: string;
      previous_release_version: string;
    }[];

    expect(result.find((row) => row.kind === "pointer")?.value).toBe("1");
    expect(result.filter((row) => row.action === "stable_rollback")).toEqual([
      {
        kind: "audit",
        value: "",
        action: "stable_rollback",
        previous_release_version: "2",
      },
    ]);
    expect(result.find((row) => row.kind === "count")?.value).toBe("2");

    expectSqlFailure(
      `
        ${publishedRelease(1)}
        UPDATE tool_profile_releases SET payload_json = '{"tampered":true}'
         WHERE profile_definition_id = 'chatgpt-codex' AND release_version = 1;
      `,
      "published Tool Profile release payload is immutable",
    );
    expectSqlFailure(
      `
        ${publishedRelease(1)}
        DELETE FROM tool_profile_releases
         WHERE profile_definition_id = 'chatgpt-codex' AND release_version = 1;
      `,
      "published Tool Profile releases cannot be deleted",
    );
  });

  it("rejects illegal lifecycle transitions and channel pointers", () => {
    expectSqlFailure(
      `
        ${profileRelease(1, "draft", "2026-10-01T00:00:00Z")}
        UPDATE tool_profile_releases SET lifecycle_state = 'stable'
         WHERE profile_definition_id = 'chatgpt-codex' AND release_version = 1;
      `,
      "invalid Tool Profile lifecycle transition",
    );

    expectSqlFailure(
      `
        ${profileRelease(1, "draft", "2026-10-01T00:00:00Z")}
        INSERT INTO tool_profile_channel_pointers
          (profile_definition_id, channel, release_version, updated_at)
        VALUES ('chatgpt-codex', 'stable', 1, '2026-10-01T00:00:00Z');
      `,
      "channel pointer must target an eligible published release",
    );
  });

  it("stores multiple digest-bound acceptance records immutably", () => {
    const inserted = apply(`
      ${publishedRelease(1)}
      INSERT INTO tool_profile_acceptance_evidence (
        id, profile_definition_id, release_version, payload_digest,
        engine_version, provider_tool_version, evidence_json,
        accepted_at, submitted_at
      ) VALUES (
        'evidence-1', 'chatgpt-codex', 1, '${"1".repeat(64)}',
        '1.0.0', '0.180.1', '{"formatVersion":1}',
        '2026-10-01T00:00:00Z', '2026-10-01T00:01:00Z'
      );
      INSERT INTO tool_profile_acceptance_evidence (
        id, profile_definition_id, release_version, payload_digest,
        engine_version, provider_tool_version, evidence_json,
        accepted_at, submitted_at
      ) VALUES (
        'evidence-2', 'chatgpt-codex', 1, '${"1".repeat(64)}',
        '1.0.0', '0.180.1', '{"formatVersion":1}',
        '2026-10-02T00:00:00Z', '2026-10-02T00:01:00Z'
      );
      SELECT count(*) AS evidence_count FROM tool_profile_acceptance_evidence
       WHERE profile_definition_id = 'chatgpt-codex' AND release_version = 1;
    `);
    expect(inserted).toEqual([{ evidence_count: 2 }]);
    expectSqlFailure(
      `
        ${publishedRelease(1)}
        INSERT INTO tool_profile_acceptance_evidence (
          id, profile_definition_id, release_version, payload_digest,
          engine_version, provider_tool_version, evidence_json,
          accepted_at, submitted_at
        ) VALUES (
          'evidence-1', 'chatgpt-codex', 1, '${"1".repeat(64)}',
          '1.0.0', '0.180.1', '{"formatVersion":1}',
          '2026-10-01T00:00:00Z', '2026-10-01T00:01:00Z'
        );
        UPDATE tool_profile_acceptance_evidence
           SET evidence_json = '{"tampered":true}' WHERE id = 'evidence-1';
      `,
      "Tool Profile acceptance evidence is immutable",
    );
    expectSqlFailure(
      `
        ${publishedRelease(1)}
        INSERT INTO tool_profile_acceptance_evidence (
          id, profile_definition_id, release_version, payload_digest,
          engine_version, provider_tool_version, evidence_json,
          accepted_at, submitted_at
        ) VALUES (
          'evidence-1', 'chatgpt-codex', 1, '${"1".repeat(64)}',
          '1.0.0', '0.180.1', '{"formatVersion":1}',
          '2026-10-01T00:00:00Z', '2026-10-01T00:01:00Z'
        );
        DELETE FROM tool_profile_acceptance_evidence WHERE id = 'evidence-1';
      `,
      "Tool Profile acceptance evidence cannot be deleted",
    );
  });
});
