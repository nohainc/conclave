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

describe("EW-15 configured Worker solo acceptance", () => {
  it("completes the solo lifecycle without an AI Account or manual package installation", () => {
    const result = apply(`
      INSERT INTO users VALUES ('u1', 'owner@example.test', 'Owner', 'active', '2026-01-01', '2026-01-01');
      INSERT INTO execution_workspaces VALUES ('ws1', 'u1', 'Solo Workspace', 'online', '2026-01-01', '2026-01-01');
      INSERT INTO workspace_runtime_identities VALUES ('runtime1', 'ws1', 'key-ref', '2026-01-01', NULL);
      INSERT INTO workers VALUES ('worker1', 'Codex', 'active', '2026-01-01', '2026-01-01');
      INSERT INTO worker_versions (id, worker_id, version, capabilities_json, permissions_json, package_digest, created_at)
        VALUES ('worker-version-1', 'worker1', '1.0.0', '["git"]', '["repository.read","repository.write"]', 'digest', '2026-01-01');
      INSERT INTO configured_workers
        (id, owner_user_id, name, worker_type_id, status, default_model, config_json, concurrency_limit, created_at, updated_at)
        VALUES ('configured-worker1', 'u1', 'Codex Personal', 'worker1', 'active', 'codex-latest', '{}', 1, '2026-01-01', '2026-01-01');
      INSERT INTO worker_workspace_bindings
        (worker_id, workspace_id, enabled, desired_version_policy, local_readiness, package_status, credential_status, permissions_status, last_seen, updated_at)
        VALUES ('configured-worker1', 'ws1', 1, 'stable', 'ready', 'ready', 'ready', 'ready', '2026-01-01', '2026-01-01');
      INSERT INTO workspace_worker_credentials
        (id, worker_id, workspace_id, owner_user_id, auth_type, sharing_policy, provider_metadata_json, local_secret_ref, state, created_at, updated_at)
        VALUES ('credential1', 'configured-worker1', 'ws1', 'u1', 'oauth', 'private_only', '{"provider":"openai"}', 'local://credential1', 'ready', '2026-01-01', '2026-01-01');
      INSERT INTO configured_worker_installations
        (id, configured_worker_id, workspace_id, worker_type_id, worker_version_id, resolved_version, status, installed_at, updated_at)
        VALUES ('installation1', 'configured-worker1', 'ws1', 'worker1', 'worker-version-1', '1.0.0', 'ready', '2026-01-01', '2026-01-01');
      INSERT INTO projects (id, owner_user_id, name, description, created_at, updated_at)
        VALUES ('p1', 'u1', 'Solo Project', NULL, '2026-01-01', '2026-01-01');
      INSERT INTO project_memberships VALUES ('pm1', 'p1', 'u1', 'owner', '2026-01-01', '2026-01-01');
      INSERT INTO workspace_project_grants (id, project_id, workspace_id, granted_by_user_id, scope, created_at, updated_at)
        VALUES ('grant1', 'p1', 'ws1', 'u1', 'project_repository', '2026-01-01', '2026-01-01');
      INSERT INTO workstreams VALUES ('stream1', 'p1', 'Solo Workstream', 'active', '{}', 'u1', '2026-01-01', '2026-01-01');
      INSERT INTO workstream_execution_policies (workstream_id, mode, primary_workspace_id, require_checkout, max_concurrent_work_requests)
        VALUES ('stream1', 'stateful', 'ws1', 1, 1);
      INSERT INTO workflow_definitions VALUES ('wf1', 'p1', 'Full Cycle', '', 'wfv1', 'u1', '2026-01-01', '2026-01-01');
      INSERT INTO workflow_versions VALUES ('wfv1', 'wf1', 1, 'u1', '2026-01-01');
      INSERT INTO workflow_steps VALUES ('step1', 'wfv1', 'Implementation', 'implementation', '["git"]', 'stateful_workstream', 0, '[]', 'none', 1000, '{}');
      INSERT INTO workstream_checkouts VALUES ('checkout1', 'stream1', 'ws1', 'repo1', 'base-sha', 'managed/stream1', 'ready', '2026-01-01', '2026-01-01');
      INSERT INTO discussion_messages VALUES ('message1', 'stream1', 'u1', 'Start implementation', '[]', NULL, '2026-01-01');
      INSERT INTO work_requests VALUES ('request1', 'stream1', 'u1', 'stateful', 'wf1', 'wfv1', '{"steps":["step1"]}', 'completed', 'ws1', 'checkout1', '{}', '2026-01-01', '2026-01-01');
      INSERT INTO runs (id, project_id, workstream_id, work_request_id, workflow_version_id, checkout_id, status, created_at, updated_at)
        VALUES ('run1', 'p1', 'stream1', 'request1', 'wfv1', 'checkout1', 'completed', '2026-01-01', '2026-01-01');
      INSERT INTO worker_assignments
        (id, project_id, run_id, workstream_id, work_request_id, workflow_version_id, checkout_id, execution_workspace_id, runtime_identity_id, worker_id, configured_worker_id, requested_by_user_id, status, input_json, output_json, created_at, updated_at)
        VALUES ('assignment1', 'p1', 'run1', 'stream1', 'request1', 'wfv1', 'checkout1', 'ws1', 'runtime1', 'worker1', 'configured-worker1', 'u1', 'completed', '{}', '{}', '2026-01-01', '2026-01-01');
      INSERT INTO workstream_checkpoints VALUES ('checkpoint1', 'stream1', 'checkout1', 1, 'checkpoint-sha-1', 'Implementation complete', 'request1', '2026-01-01');
      INSERT INTO workstream_current_checkpoints VALUES ('stream1', 'checkpoint1', '2026-01-01');
      INSERT INTO work_requests VALUES ('request2', 'stream1', 'u1', 'stateful', 'wf1', 'wfv1', '{}', 'queued', 'ws1', 'checkout1', '{"baseCheckpointRevision":"checkpoint-sha-1"}', '2026-01-02', '2026-01-02');
      INSERT INTO workstream_integrations (id, project_id, workstream_id, requested_by_user_id, provider, status, branch_name, base_revision, head_revision, pull_request_number, pull_request_url, created_at, updated_at)
        VALUES ('integration1', 'p1', 'stream1', 'u1', 'github', 'pr_open', 'workstream/stream1', 'base-sha', 'checkpoint-sha-1', 1, 'https://github.test/org/repo/pull/1', '2026-01-02', '2026-01-02');
      SELECT
        (SELECT local_readiness || ':' || package_status || ':' || credential_status || ':' || permissions_status
           FROM worker_workspace_bindings WHERE worker_id = 'configured-worker1' AND workspace_id = 'ws1') AS worker_readiness,
        (SELECT status FROM configured_worker_installations WHERE id = 'installation1') AS installation_status,
        (SELECT status FROM workspace_project_grants WHERE id = 'grant1') AS grant_status,
        (SELECT configured_worker_id FROM worker_assignments WHERE id = 'assignment1') AS assignment_worker,
        (SELECT COUNT(*) FROM ai_accounts) AS ai_account_count,
        (SELECT COUNT(*) FROM project_account_grants) AS account_grant_count,
        (SELECT revision FROM workstream_checkpoints WHERE id = 'checkpoint1') AS checkpoint_revision,
        (SELECT input_json FROM work_requests WHERE id = 'request2') AS second_base,
        (SELECT status FROM workstream_integrations WHERE id = 'integration1') AS integration_status;
    `);

    expect(result).toEqual([
      {
        worker_readiness: "ready:ready:ready:ready",
        installation_status: "ready",
        grant_status: "active",
        assignment_worker: "configured-worker1",
        ai_account_count: 0,
        account_grant_count: 0,
        checkpoint_revision: "checkpoint-sha-1",
        second_base: '{"baseCheckpointRevision":"checkpoint-sha-1"}',
        integration_status: "pr_open",
      },
    ]);
  });
});
