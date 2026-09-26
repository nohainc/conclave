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
];

const schema = migrationFiles
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
        requested_by_user_id, status, input_json, output_json,
        created_at, updated_at
      ) VALUES (
        'assignment1', 'p1', 'run1', 'stream1', 'request1', 'wfv1',
        'checkout1', 'ws1', 'runtime1', 'codex',
        'u1', 'completed', '{}', '{"status":"ok"}',
        '2026-01-01', '2026-01-01'
      );

      SELECT
        (SELECT status FROM workspace_worker_inventory WHERE worker_id = 'v7-codex-1') AS inventory_status,
        (SELECT credential_status FROM workspace_worker_inventory WHERE worker_id = 'v7-codex-1') AS credential_status,
        (SELECT worker_id FROM worker_assignments WHERE id = 'assignment1') AS assigned_worker,
        (SELECT status FROM worker_assignments WHERE id = 'assignment1') AS assignment_status,
        (SELECT COUNT(*) FROM ai_accounts) AS ai_account_count;
    `);

    expect(result).toEqual([
      {
        inventory_status: "ready",
        credential_status: "ready",
        assigned_worker: "codex",
        assignment_status: "completed",
        ai_account_count: 0,
      },
    ]);
  });
});
