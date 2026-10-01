import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const migrationFiles = readdirSync(
  fileURLToPath(new URL("../migrations-v6/", import.meta.url)),
)
  .filter((file) => file.endsWith(".sql"))
  .sort();

const schema = migrationFiles
  .map((file) =>
    readFileSync(
      fileURLToPath(new URL(`../migrations-v6/${file}`, import.meta.url)),
      "utf8",
    ),
  )
  .join("\n");
const schemaBeforePairingIntents = migrationFiles
  .filter((file) => file !== "0028_workspace_pairing_intents.sql")
  .map((file) =>
    readFileSync(
      fileURLToPath(new URL(`../migrations-v6/${file}`, import.meta.url)),
      "utf8",
    ),
  )
  .join("\n");
const preCleanupSchema = migrationFiles
  .filter((file) => file !== "0026_remove_v6_configured_workers.sql")
  .map((file) =>
    readFileSync(
      fileURLToPath(new URL(`../migrations-v6/${file}`, import.meta.url)),
      "utf8",
    ),
  )
  .join("\n");

function apply(sql: string): unknown[] {
  return JSON.parse(
    execFileSync("sqlite3", ["-json", ":memory:"], {
      input: `${schema}\n${sql}`,
      encoding: "utf8",
    }),
  ) as unknown[];
}

describe("v8 Workspace and database lifecycle acceptance", () => {
  it("bootstraps v8 Profile tables without native provider Worker release tables", () => {
    const tables = apply(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name;",
    ) as { name: string }[];
    const tableNames = tables.map((table) => table.name);
    expect(tableNames).toEqual(
      expect.arrayContaining([
        "worker_catalog",
        "tool_profile_definitions",
        "tool_profile_releases",
        "tool_profile_release_audit",
        "tool_profile_channel_pointers",
      ]),
    );
    expect(tableNames).not.toContain("worker_releases");
    expect(tableNames).not.toContain("v7_adapter_releases");
    expect(
      apply(
        "SELECT worker_type_id FROM worker_catalog ORDER BY worker_type_id;",
      ),
    ).toEqual([{ worker_type_id: "chatgpt" }, { worker_type_id: "gemini" }]);
  });

  it("keeps the optional v8 development seed limited to logical identities", () => {
    const seed = readFileSync(
      fileURLToPath(new URL("../seed/v6-development.sql", import.meta.url)),
      "utf8",
    );
    expect(
      apply(`${seed}
        SELECT (SELECT COUNT(*) FROM worker_catalog) AS workers,
               (SELECT COUNT(*) FROM tool_profile_definitions) AS profiles,
               (SELECT COUNT(*) FROM tool_profile_releases) AS releases,
               (SELECT COUNT(*) FROM execution_workspaces) AS workspaces,
               (SELECT COUNT(*) FROM work_requests) AS work_requests;`),
    ).toEqual([
      { workers: 3, profiles: 3, releases: 0, workspaces: 0, work_requests: 0 },
    ]);
  });

  it("maps the testing-only fixture CLI Worker to its v1 Profile release", () => {
    const seed = readFileSync(
      fileURLToPath(new URL("../seed/v6-development.sql", import.meta.url)),
      "utf8",
    );
    const rows = apply(`${seed}
      SELECT worker.worker_type_id, worker.release_stage,
             definition.profile_definition_id, definition.provider_tool_name
        FROM worker_catalog worker
        JOIN tool_profile_definitions definition
          ON definition.worker_type_id = worker.worker_type_id
       WHERE worker.worker_type_id = 'fixture-worker';`);
    expect(rows).toEqual([
      {
        worker_type_id: "fixture-worker",
        release_stage: "testing",
        profile_definition_id: "fixture-cli",
        provider_tool_name: "Fixture CLI",
      },
    ]);

    const profile = JSON.parse(
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
    expect(profile).toMatchObject({
      schemaVersion: 1,
      profileDefinitionId: "fixture-cli",
      releaseVersion: 1,
      logicalWorkerTypeId: "fixture-worker",
    });
  });

  it("creates the Workspace release table on the clean v6 baseline", () => {
    const columns = apply("PRAGMA table_info(host_releases);") as {
      name: string;
    }[];
    expect(columns.map((column) => column.name)).toEqual(
      expect.arrayContaining([
        "version",
        "channel",
        "min_supported_agent_version",
        "package_digest",
        "signature",
        "signing_key_id",
      ]),
    );
    expect(
      apply("SELECT COUNT(*) AS count FROM release_signing_key_revocations;"),
    ).toEqual([{ count: 0 }]);
  });

  it("stores pairing intent before any permanent execution Workspace exists", () => {
    const result = apply(`
      INSERT INTO users (id, email, display_name, status, created_at, updated_at)
        VALUES ('u1', 'owner@example.test', 'Owner', 'active', '2026-01-01', '2026-01-01');
      INSERT INTO workspace_pairing_intents
        (pairing_id, owner_user_id, token_hash, created_at, expires_at)
        VALUES ('pair-1', 'u1', 'sha256:token-hash', '2026-01-01', '2026-01-01T00:15:00Z');
      SELECT (SELECT COUNT(*) FROM workspace_pairing_intents) AS intent_count,
             (SELECT COUNT(*) FROM execution_workspaces) AS workspace_count;
    `) as { intent_count: number; workspace_count: number }[];
    expect(result).toEqual([{ intent_count: 1, workspace_count: 0 }]);
  });

  it("preserves paired Workspace state and runtime credentials during upgrade", () => {
    const pairingMigration = readFileSync(
      fileURLToPath(
        new URL(
          "../migrations-v6/0028_workspace_pairing_intents.sql",
          import.meta.url,
        ),
      ),
      "utf8",
    );
    const result = JSON.parse(
      execFileSync("sqlite3", ["-json", ":memory:"], {
        input: `${schemaBeforePairingIntents}
          INSERT INTO users (id, email, display_name, status, created_at, updated_at)
            VALUES ('u1', 'paired@example.test', 'Paired', 'active', '2026-01-01', '2026-01-01');
          INSERT INTO execution_workspaces VALUES ('ws1', 'u1', 'Paired Mac', 'offline', '2026-01-01', '2026-01-02');
          INSERT INTO workspace_runtime_identities
            (id, workspace_id, credential_key_ref, credential_token_hash, created_at, revoked_at)
            VALUES ('rt1', 'ws1', 'runtime-key-ref', 'sha256:existing-token', '2026-01-01', NULL);
          ${pairingMigration}
          SELECT ew.status, ri.credential_key_ref, ri.credential_token_hash,
                 ri.revoked_at, ri.installation_id,
                 (SELECT COUNT(*) FROM workspace_pairing_intents) AS pairing_intent_count
            FROM execution_workspaces ew
            JOIN workspace_runtime_identities ri ON ri.workspace_id = ew.id
           WHERE ew.id = 'ws1';`,
        encoding: "utf8",
      }),
    ) as unknown[];

    expect(result).toEqual([
      {
        status: "offline",
        credential_key_ref: "runtime-key-ref",
        credential_token_hash: "sha256:existing-token",
        revoked_at: null,
        installation_id: null,
        pairing_intent_count: 0,
      },
    ]);
  });

  it("projects paired runtime facts and V7 inventory/activity counts", () => {
    const result = apply(`
      INSERT INTO users (id, email, display_name, status, created_at, updated_at)
        VALUES ('u1', 'owner@example.test', 'Owner', 'active', '2026-01-01', '2026-01-01');
      INSERT INTO execution_workspaces VALUES ('ws1', 'u1', 'Vitalii’s MacBook Pro', 'online', '2026-01-01', '2026-09-26T12:30:00.000Z');
      INSERT INTO workspace_runtime_identities
        (id, workspace_id, credential_key_ref, credential_token_hash, created_at, revoked_at)
        VALUES ('rt1', 'ws1', 'runtime-key', 'sha256:token', '2026-01-01', NULL);
      INSERT INTO workspace_runtime_facts
        (workspace_id, platform, architecture, hostname, app_version, runtime_capabilities_json, updated_at)
        VALUES ('ws1', 'macos', 'arm64', 'vitalii-macbook.local', '1.4.2',
                '{"os":"macos","arch":"arm64","appVersion":"1.4.2","supportedRuntimes":["dart"],"maxConcurrentWorkers":2}',
                '2026-09-26T12:29:00.000Z');
      INSERT INTO workers VALUES ('codex', 'Codex', 'active', '2026-01-01', '2026-01-01');
      INSERT INTO workspace_worker_inventory (
        workspace_id, worker_id, owner_user_id, worker_type_id, activation_state,
        readiness_state, engine_version, profile_definition_id, profile_release_version, capabilities_json,
        local_concurrency_limit, revision, created_at,
        updated_at, last_seen_at
      ) VALUES
        ('ws1', 'worker-1', 'u1', 'chatgpt', 'enabled', 'ready', '1.0.0', 'chatgpt-codex', 3, '[]', 1, 1, 'now', 'now', 'now'),
        ('ws1', 'worker-2', 'u1', 'chatgpt', 'enabled', 'ready', '1.0.0', 'chatgpt-codex', 3, '[]', 1, 1, 'now', 'now', 'now'),
        ('ws1', 'worker-3', 'u1', 'chatgpt', 'enabled', 'ready', '1.0.0', 'chatgpt-codex', 3, '[]', 1, 1, 'now', 'now', 'now');
      INSERT INTO projects (id, owner_user_id, name, created_at, updated_at)
        VALUES ('p1', 'u1', 'Project', 'now', 'now');
      INSERT INTO worker_assignments
        (id, project_id, execution_workspace_id, runtime_identity_id, worker_id, status, created_at, updated_at)
        VALUES ('a1', 'p1', 'ws1', 'rt1', 'codex', 'running', 'now', 'now'),
               ('a2', 'p1', 'ws1', 'rt1', 'codex', 'created', 'now', 'now'),
               ('a3', 'p1', 'ws1', 'rt1', 'codex', 'completed', 'now', 'now');
      SELECT ew.name, f.hostname, f.platform, f.architecture, f.app_version,
             f.runtime_capabilities_json,
             (SELECT COUNT(*) FROM workspace_worker_inventory worker
               WHERE worker.workspace_id = ew.id) AS workerCount,
             (SELECT COUNT(*) FROM worker_assignments assignment
               WHERE assignment.execution_workspace_id = ew.id
                 AND assignment.status IN ('created', 'dispatched', 'acknowledged', 'running')) AS activeTaskCount,
             CASE WHEN ew.updated_at > f.updated_at THEN ew.updated_at ELSE f.updated_at END AS lastSeen
        FROM execution_workspaces ew
        JOIN workspace_runtime_facts f ON f.workspace_id = ew.id
       WHERE ew.id = 'ws1';
    `) as unknown[];

    expect(result).toEqual([
      {
        name: "Vitalii’s MacBook Pro",
        hostname: "vitalii-macbook.local",
        platform: "macos",
        architecture: "arm64",
        app_version: "1.4.2",
        runtime_capabilities_json:
          '{"os":"macos","arch":"arm64","appVersion":"1.4.2","supportedRuntimes":["dart"],"maxConcurrentWorkers":2}',
        workerCount: 3,
        activeTaskCount: 2,
        lastSeen: "2026-09-26T12:30:00.000Z",
      },
    ]);
  });

  it("exposes only v8 runtime evidence in the synchronized Worker inventory", () => {
    const columns = apply("PRAGMA table_info(workspace_worker_inventory);") as {
      name: string;
    }[];
    const names = columns.map((column) => column.name);
    expect(names).toEqual(
      expect.arrayContaining([
        "activation_state",
        "readiness_state",
        "engine_version",
        "profile_definition_id",
        "profile_release_version",
        "provider_tool_name",
        "provider_tool_version",
      ]),
    );
    expect(names).not.toContain("worker_runtime_version");
    expect(names).not.toContain("adapter_version");
    expect(names).not.toContain("provider_tool_path");
  });

  it("forward-migrates legacy assignment and audit attribution, then removes V6 tables", () => {
    const result = JSON.parse(
      execFileSync("sqlite3", ["-json", ":memory:"], {
        input: `${preCleanupSchema}
          INSERT INTO users (id, email, display_name, status, created_at, updated_at)
            VALUES ('u1', 'owner@example.test', 'Owner', 'active', '2026-01-01', '2026-01-01');
          INSERT INTO execution_workspaces VALUES ('ws1', 'u1', 'Workspace', 'online', '2026-01-01', '2026-01-01');
          INSERT INTO workspace_runtime_identities (id, workspace_id, credential_key_ref, created_at) VALUES ('rt1', 'ws1', 'ref', '2026-01-01');
          INSERT INTO workers VALUES ('type1', 'Type One', 'active', '2026-01-01', '2026-01-01');
          INSERT INTO configured_workers (id, owner_user_id, name, worker_type_id, concurrency_limit, created_at, updated_at) VALUES ('legacy1', 'u1', 'Legacy', 'type1', 1, '2026-01-01', '2026-01-01');
          INSERT INTO projects (id, owner_user_id, name, created_at, updated_at) VALUES ('p1', 'u1', 'Project', '2026-01-01', '2026-01-01');
          INSERT INTO worker_assignments (id, project_id, execution_workspace_id, runtime_identity_id, worker_id, status, created_at, updated_at, configured_worker_id) VALUES ('a1', 'p1', 'ws1', 'rt1', 'type1', 'completed', '2026-01-01', '2026-01-01', 'legacy1');
          INSERT INTO configured_worker_audit_log (id, configured_worker_id, workspace_id, actor_type, actor_id, action, target_id, created_at) VALUES ('audit1', 'legacy1', 'ws1', 'user', 'u1', 'worker.created', 'legacy1', '2026-01-01');
          ${readFileSync(fileURLToPath(new URL("../migrations-v6/0026_remove_v6_configured_workers.sql", import.meta.url)), "utf8")}
          SELECT a.workspace_worker_id, a.worker_id, a.execution_workspace_id,
                 h.worker_id AS audit_worker_id, h.workspace_id AS audit_workspace_id, h.worker_type_id AS audit_worker_type_id,
                 (SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('configured_workers', 'worker_workspace_bindings', 'workspace_worker_credentials')) AS legacy_table_count
            FROM worker_assignments a JOIN worker_attribution_audit_archive h ON h.id = 'audit1' WHERE a.id = 'a1';`,
        encoding: "utf8",
      }),
    ) as unknown[];
    expect(result).toEqual([
      {
        workspace_worker_id: "legacy1",
        worker_id: "type1",
        execution_workspace_id: "ws1",
        audit_worker_id: "legacy1",
        audit_workspace_id: "ws1",
        audit_worker_type_id: "type1",
        legacy_table_count: 0,
      },
    ]);
  });

  it("validates ownership, grants, workstream policy, and assignment attribution schema without claiming runtime execution", () => {
    const result = apply(`
      INSERT INTO users (id, email, display_name, status, created_at, updated_at)
        VALUES ('u1', 'owner@example.test', 'Owner', 'active', '2026-01-01', '2026-01-01');
      INSERT INTO execution_workspaces VALUES ('ws1', 'u1', 'MacBook Pro', 'online', '2026-01-01', '2026-01-01');
      INSERT INTO workspace_runtime_identities
        (id, workspace_id, credential_key_ref, created_at, revoked_at)
        VALUES ('runtime1', 'ws1', 'key-ref', '2026-01-01', NULL);
      INSERT INTO workers VALUES ('codex', 'Codex', 'active', '2026-01-01', '2026-01-01');

      -- V7 Workspace-owned worker inventory synced from local Conclave Workspace
      INSERT INTO workspace_worker_inventory (
        workspace_id, worker_id, owner_user_id, worker_type_id, activation_state,
        readiness_state, engine_version, profile_definition_id, profile_release_version, capabilities_json,
        local_concurrency_limit, revision, created_at, updated_at, last_seen_at
      ) VALUES (
        'ws1', 'v7-codex-1', 'u1', 'chatgpt', 'enabled',
        'ready', '1.0.0', 'chatgpt-codex', 3, '["code","repository"]',
        2, 1, '2026-01-01', '2026-01-01', '2026-01-01'
      );


      -- Project, membership, and grant
      INSERT INTO projects (id, owner_user_id, name, description, created_at, updated_at)
        VALUES ('p1', 'u1', 'Solo Project', NULL, '2026-01-01', '2026-01-01');
      INSERT INTO project_memberships VALUES ('pm1', 'p1', 'u1', 'owner', '2026-01-01', '2026-01-01');
      INSERT INTO workspace_project_grants (id, project_id, workspace_id, granted_by_user_id, scope, created_at, updated_at)
        VALUES ('grant1', 'p1', 'ws1', 'u1', 'project_repository', '2026-01-01', '2026-01-01');

      -- Workstream and execution policy
      INSERT INTO workstreams VALUES ('stream1', 'p1', 'Feature Workstream', 'active', '{}', 'u1', '2026-01-01', '2026-01-01');
      INSERT INTO workstream_execution_policies (workstream_id, mode, primary_workspace_id, require_checkout, max_concurrent_work_requests)
        VALUES ('stream1', 'stateful', 'ws1', 1, 1);

      -- Work request stores the immutable built-in selection and snapshot directly.
      INSERT INTO workstream_checkouts VALUES ('checkout1', 'stream1', 'ws1', 'repo1', 'base-sha', 'managed/stream1', 'ready', '2026-01-01', '2026-01-01');
      INSERT INTO work_requests (id, workstream_id, requested_by_user_id, mode, workflow_id, workflow_version, workflow_snapshot_json, status, primary_workspace_id, checkout_id, input_json, created_at, updated_at)
        VALUES ('request1', 'stream1', 'u1', 'stateful', 'full_cycle', 1, '{"id":"full_cycle","version":1}', 'completed', 'ws1', 'checkout1', '{}', '2026-01-01', '2026-01-01');
      INSERT INTO runs (id, project_id, workstream_id, work_request_id, checkout_id, status, created_at, updated_at)
        VALUES ('run1', 'p1', 'stream1', 'request1', 'checkout1', 'completed', '2026-01-01', '2026-01-01');

      -- Worker Assignment using V7 worker
      INSERT INTO worker_assignments (
        id, project_id, run_id, workstream_id, work_request_id,
        checkout_id, execution_workspace_id, runtime_identity_id, worker_id,
        workspace_worker_id,
        requested_by_user_id, status, input_json, output_json,
        created_at, updated_at
      ) VALUES (
        'assignment1', 'p1', 'run1', 'stream1', 'request1',
        'checkout1', 'ws1', 'runtime1', 'codex', 'v7-codex-1',
        'u1', 'completed', '{}', '{"status":"ok"}',
        '2026-01-01', '2026-01-01'
      );

      SELECT
        (SELECT activation_state FROM workspace_worker_inventory WHERE worker_id = 'v7-codex-1') AS activation_state,
        (SELECT readiness_state FROM workspace_worker_inventory WHERE worker_id = 'v7-codex-1') AS readiness_state,
        (SELECT worker_id FROM worker_assignments WHERE id = 'assignment1') AS assigned_worker,
        (SELECT workspace_worker_id FROM worker_assignments WHERE id = 'assignment1') AS workspace_worker,
        (SELECT status FROM worker_assignments WHERE id = 'assignment1') AS assignment_status,
        (SELECT COUNT(*) FROM ai_accounts) AS ai_account_count,
        (SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('workflow_definitions', 'workflow_versions', 'workflow_steps', 'workflow_step_dependencies')) AS legacy_workflow_catalog_count;
    `);

    expect(result).toEqual([
      {
        activation_state: "enabled",
        readiness_state: "ready",
        assigned_worker: "codex",
        workspace_worker: "v7-codex-1",
        assignment_status: "completed",
        ai_account_count: 0,
        legacy_workflow_catalog_count: 0,
      },
    ]);
  });
});
