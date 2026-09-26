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
  "0021_workspace_worker_inventory.sql",
  "0022_v7_adapter_releases.sql",
  "0024_v7_worker_scheduling.sql",
  "0025_v7_assignment_runtime.sql",
  "0026_remove_v6_configured_workers.sql",
  "0027_public_key_release_trust.sql",
];

const schema = migrationFiles
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
      INSERT INTO workspace_runtime_identities VALUES ('runtime1', 'ws1', 'key-ref', '2026-01-01', NULL);
      INSERT INTO workers VALUES ('codex', 'Codex', 'active', '2026-01-01', '2026-01-01');

      -- V7 Workspace-owned worker inventory synced from local Conclave Workspace
      INSERT INTO workspace_worker_inventory (
        workspace_id, worker_id, owner_user_id, name, worker_type_id,
        auth_strategy, default_model, allowed_models_json, capabilities_json,
        local_permissions_summary_json, local_concurrency_limit, adapter_version,
        credential_status, status, revision, created_at, updated_at, last_seen_at
      ) VALUES (
        'ws1', 'v7-codex-1', 'u1', 'Codex Local', 'codex',
        'browser_auth', 'gpt-5.5', '["gpt-5.5"]', '["code","repository"]',
        '["repository:read","repository:write"]', 2, '1.0.0',
        'ready', 'ready', 1, '2026-01-01', '2026-01-01', '2026-01-01'
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
        (SELECT status FROM workspace_worker_inventory WHERE worker_id = 'v7-codex-1') AS inventory_status,
        (SELECT credential_status FROM workspace_worker_inventory WHERE worker_id = 'v7-codex-1') AS credential_status,
        (SELECT worker_id FROM worker_assignments WHERE id = 'assignment1') AS assigned_worker,
        (SELECT workspace_worker_id FROM worker_assignments WHERE id = 'assignment1') AS workspace_worker,
        (SELECT status FROM worker_assignments WHERE id = 'assignment1') AS assignment_status,
        (SELECT COUNT(*) FROM ai_accounts) AS ai_account_count;
    `);

    expect(result).toEqual([
      {
        inventory_status: "ready",
        credential_status: "ready",
        assigned_worker: "codex",
        workspace_worker: "v7-codex-1",
        assignment_status: "completed",
        ai_account_count: 0,
      },
    ]);
  });
});
