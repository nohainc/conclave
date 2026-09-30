import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const migrationFiles = [
  "0001_conclave_v6.sql",
  "0002_workstream_integrations.sql",
  "0003_usage_audit_observability.sql",
  "0004_chat_workstream_mapping.sql",
  "0005_execution_foundation.sql",
  "0007_project_settings.sql",
  "0010_workspace_project_grant_policy.sql",
  "0011_project_invitations.sql",
  "0012_remove_project_repository.sql",
  "0013_configured_workers.sql",
  "0014_configured_worker_runtime_state.sql",
  "0015_configured_worker_assignments.sql",
  "0016_worker_first_execution_policy.sql",
  "0017_configured_worker_observability.sql",
  "0018_migrate_legacy_ai_accounts.sql",
  "0019_worker_assignment_requester.sql",
  "0020_workspace_runtime_facts.sql",
  "0021_workspace_worker_inventory.sql",
  "0022_v7_adapter_releases.sql",
  "0023_workspace_runtime_credentials.sql",
  "0024_v7_worker_scheduling.sql",
  "0025_v7_assignment_runtime.sql",
  "0026_remove_v6_configured_workers.sql",
  "0027_public_key_release_trust.sql",
  "0028_workspace_pairing_intents.sql",
  "0031_worker_readiness_state.sql",
  "0032_worker_inventory_safe_projection.sql",
  "0033_workstream_worker_usage_policy.sql",
  "0035_worker_releases.sql",
  "0036_worker_inventory_v2.sql",
];

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

describe("V7 Workspace-Owned Worker schema and lifecycle acceptance", () => {
  it("stores native Worker releases by Worker, version, and platform", () => {
    const columns = apply("PRAGMA table_info(worker_releases);") as {
      name: string;
      pk: number;
    }[];
    expect(columns.map((column) => column.name)).toEqual(
      expect.arrayContaining([
        "worker_type_id",
        "version",
        "platform",
        "release_channel",
        "protocol_min",
        "protocol_max",
        "state_read_min",
        "state_read_max",
        "state_write",
        "manifest_json",
        "package_digest",
        "archive_sha256",
        "package_r2_key",
        "is_revoked",
      ]),
    );
    expect(
      columns
        .filter((column) => column.pk > 0)
        .sort((left, right) => left.pk - right.pk)
        .map((column) => column.name),
    ).toEqual(["worker_type_id", "version", "platform"]);
    expect(
      apply(
        "SELECT COUNT(*) AS count FROM sqlite_master WHERE type = 'table' AND name = 'v7_adapter_releases';",
      ),
    ).toEqual([{ count: 0 }]);
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
      INSERT INTO users VALUES ('u1', 'owner@example.test', 'Owner', 'active', '2026-01-01', '2026-01-01');
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
          INSERT INTO users VALUES ('u1', 'paired@example.test', 'Paired', 'active', '2026-01-01', '2026-01-01');
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
      INSERT INTO users VALUES ('u1', 'owner@example.test', 'Owner', 'active', '2026-01-01', '2026-01-01');
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
        readiness_state, worker_runtime_version, capabilities_json,
        local_concurrency_limit, revision, created_at,
        updated_at, last_seen_at
      ) VALUES
        ('ws1', 'worker-1', 'u1', 'chatgpt', 'enabled', 'ready', '2.0.0', '[]', 1, 1, 'now', 'now', 'now'),
        ('ws1', 'worker-2', 'u1', 'chatgpt', 'enabled', 'ready', '2.0.0', '[]', 1, 1, 'now', 'now', 'now'),
        ('ws1', 'worker-3', 'u1', 'chatgpt', 'enabled', 'ready', '2.0.0', '[]', 1, 1, 'now', 'now', 'now');
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

  it("forward-migrates legacy assignment and audit attribution, then removes V6 tables", () => {
    const result = JSON.parse(
      execFileSync("sqlite3", ["-json", ":memory:"], {
        input: `${preCleanupSchema}
          INSERT INTO users VALUES ('u1', 'owner@example.test', 'Owner', 'active', '2026-01-01', '2026-01-01');
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
      INSERT INTO users VALUES ('u1', 'owner@example.test', 'Owner', 'active', '2026-01-01', '2026-01-01');
      INSERT INTO execution_workspaces VALUES ('ws1', 'u1', 'MacBook Pro', 'online', '2026-01-01', '2026-01-01');
      INSERT INTO workspace_runtime_identities
        (id, workspace_id, credential_key_ref, created_at, revoked_at)
        VALUES ('runtime1', 'ws1', 'key-ref', '2026-01-01', NULL);
      INSERT INTO workers VALUES ('codex', 'Codex', 'active', '2026-01-01', '2026-01-01');

      -- V7 Workspace-owned worker inventory synced from local Conclave Workspace
      INSERT INTO workspace_worker_inventory (
        workspace_id, worker_id, owner_user_id, worker_type_id, activation_state,
        readiness_state, worker_runtime_version, capabilities_json,
        local_concurrency_limit, revision, created_at, updated_at, last_seen_at
      ) VALUES (
        'ws1', 'v7-codex-1', 'u1', 'chatgpt', 'enabled',
        'ready', '2.0.0', '["code","repository"]',
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

      -- Workflow and work request
      INSERT INTO workflow_definitions VALUES ('wf1', 'p1', 'Full Cycle', '', 'wfv1', 'u1', '2026-01-01', '2026-01-01');
      INSERT INTO workflow_versions VALUES ('wfv1', 'wf1', 1, 'u1', '2026-01-01');
      INSERT INTO workflow_steps VALUES ('step1', 'wfv1', 'Implementation', 'implementation', '["code"]', 'stateful_workstream', 0, '[]', 'none', 1000, '{}');
      INSERT INTO workstream_checkouts VALUES ('checkout1', 'stream1', 'ws1', 'repo1', 'base-sha', 'managed/stream1', 'ready', '2026-01-01', '2026-01-01');
      INSERT INTO work_requests VALUES ('request1', 'stream1', 'u1', 'stateful', 'wf1', 'wfv1', '{"steps":["step1"]}', 'completed', 'ws1', 'checkout1', '{}', '2026-01-01', '2026-01-01');
      INSERT INTO runs (id, project_id, workstream_id, work_request_id, workflow_version_id, checkout_id, status, created_at, updated_at)
        VALUES ('run1', 'p1', 'stream1', 'request1', 'wfv1', 'checkout1', 'completed', '2026-01-01', '2026-01-01');

      -- Worker Assignment using V7 worker
      INSERT INTO worker_assignments (
        id, project_id, run_id, workstream_id, work_request_id, workflow_version_id,
        checkout_id, execution_workspace_id, runtime_identity_id, worker_id,
        workspace_worker_id,
        requested_by_user_id, status, input_json, output_json,
        created_at, updated_at
      ) VALUES (
        'assignment1', 'p1', 'run1', 'stream1', 'request1', 'wfv1',
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
        (SELECT COUNT(*) FROM ai_accounts) AS ai_account_count;
    `);

    expect(result).toEqual([
      {
        activation_state: "enabled",
        readiness_state: "ready",
        assigned_worker: "codex",
        workspace_worker: "v7-codex-1",
        assignment_status: "completed",
        ai_account_count: 0,
      },
    ]);
  });
});
