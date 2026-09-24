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
];
const schema = migrationFiles
  .map((file) => readFileSync(fileURLToPath(new URL(`../migrations-v6/${file}`, import.meta.url)), "utf8"))
  .join("\n");

function apply(sql: string): unknown[] {
  return JSON.parse(
    execFileSync("sqlite3", ["-json", ":memory:"], {
      input: `${schema}\n${sql}`,
      encoding: "utf8",
    }),
  ) as unknown[];
}

describe("V6 clean-room solo acceptance", () => {
  it("completes the solo lifecycle from an empty database", () => {
    const result = apply(`
      INSERT INTO users VALUES ('u1', 'owner@example.test', 'Owner', 'active', '2026-01-01', '2026-01-01');
      INSERT INTO execution_workspaces VALUES ('ws1', 'u1', 'Solo Workspace', 'online', '2026-01-01', '2026-01-01');
      INSERT INTO workspace_runtime_identities VALUES ('runtime1', 'ws1', 'key-ref', '2026-01-01', NULL);
      INSERT INTO workers VALUES ('worker1', 'Codex Worker', 'active', '2026-01-01', '2026-01-01');
      INSERT INTO worker_versions VALUES ('worker-version-1', 'worker1', '1.0.0', '["git"]', '["repository.read","repository.write"]', 'digest', '2026-01-01');
      INSERT INTO workspace_worker_installations VALUES ('install1', 'ws1', 'worker1', 'worker-version-1', 'ready', '2026-01-01', '2026-01-01');
      INSERT INTO ai_accounts VALUES ('account1', 'u1', 'worker1', 'ws1', 'Private Account', 'ready', '2026-01-01', '2026-01-01');
      INSERT INTO projects (id, owner_user_id, name, description, repository_id, created_at, updated_at)
        VALUES ('p1', 'u1', 'Solo Project', NULL, 'repo1', '2026-01-01', '2026-01-01');
      INSERT INTO project_memberships VALUES ('pm1', 'p1', 'u1', 'owner', '2026-01-01', '2026-01-01');
      INSERT INTO workspace_project_grants (id, project_id, workspace_id, granted_by_user_id, scope, created_at, updated_at)
        VALUES ('grant1', 'p1', 'ws1', 'u1', 'project_repository', '2026-01-01', '2026-01-01');
      INSERT INTO project_account_grants (id, project_id, account_id, granted_by_user_id, created_at)
        VALUES ('account-grant1', 'p1', 'account1', 'u1', '2026-01-01');
      INSERT INTO workstreams VALUES ('stream1', 'p1', 'Solo Workstream', 'active', '{}', 'u1', '2026-01-01', '2026-01-01');
      INSERT INTO workstream_execution_policies VALUES ('stream1', 'stateful', 'ws1', 1, 1);
      INSERT INTO workflow_definitions VALUES ('wf1', 'p1', 'Full Cycle', '', 'wfv1', 'u1', '2026-01-01', '2026-01-01');
      INSERT INTO workflow_versions VALUES ('wfv1', 'wf1', 1, 'u1', '2026-01-01');
      INSERT INTO workflow_steps VALUES ('step1', 'wfv1', 'Implementation', 'implementation', '["git"]', 'stateful_workstream', 0, '[]', 'none', 1000, '{}');
      INSERT INTO workstream_checkouts VALUES ('checkout1', 'stream1', 'ws1', 'repo1', 'base-sha', 'managed/stream1', 'ready', '2026-01-01', '2026-01-01');
      INSERT INTO discussion_messages VALUES ('message1', 'stream1', 'u1', 'Start implementation', '[]', NULL, '2026-01-01');
      INSERT INTO work_requests VALUES ('request1', 'stream1', 'u1', 'stateful', 'wf1', 'wfv1', '{"steps":["step1"]}', 'completed', 'ws1', 'checkout1', '{}', '2026-01-01', '2026-01-01');
      INSERT INTO runs (id, project_id, workstream_id, work_request_id, workflow_version_id, checkout_id, status, created_at, updated_at)
        VALUES ('run1', 'p1', 'stream1', 'request1', 'wfv1', 'checkout1', 'completed', '2026-01-01', '2026-01-01');
      INSERT INTO workstream_checkpoints VALUES ('checkpoint1', 'stream1', 'checkout1', 1, 'checkpoint-sha-1', 'Implementation complete', 'request1', '2026-01-01');
      INSERT INTO workstream_current_checkpoints VALUES ('stream1', 'checkpoint1', '2026-01-01');
      INSERT INTO work_requests VALUES ('request2', 'stream1', 'u1', 'stateful', 'wf1', 'wfv1', '{}', 'queued', 'ws1', 'checkout1', '{"baseCheckpointRevision":"checkpoint-sha-1"}', '2026-01-02', '2026-01-02');
      INSERT INTO workstream_integrations (id, project_id, workstream_id, requested_by_user_id, provider, status, branch_name, base_revision, head_revision, pull_request_number, pull_request_url, created_at, updated_at)
        VALUES ('integration1', 'p1', 'stream1', 'u1', 'github', 'pr_open', 'workstream/stream1', 'base-sha', 'checkpoint-sha-1', 1, 'https://github.test/org/repo/pull/1', '2026-01-02', '2026-01-02');
      SELECT
        (SELECT status FROM workspace_worker_installations WHERE id = 'install1') AS worker_status,
        (SELECT status FROM workspace_project_grants WHERE id = 'grant1') AS grant_status,
        (SELECT revision FROM workstream_checkpoints WHERE id = 'checkpoint1') AS checkpoint_revision,
        (SELECT input_json FROM work_requests WHERE id = 'request2') AS second_base,
        (SELECT status FROM workstream_integrations WHERE id = 'integration1') AS integration_status;
    `);

    expect(result).toEqual([
      {
        worker_status: "ready",
        grant_status: "active",
        checkpoint_revision: "checkpoint-sha-1",
        second_base: '{"baseCheckpointRevision":"checkpoint-sha-1"}',
        integration_status: "pr_open",
      },
    ]);
  });
});
