import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const schemaPath = fileURLToPath(
  new URL("../migrations-v6/0001_conclave_v6.sql", import.meta.url),
);
const schema = readFileSync(schemaPath, "utf8");
const integrationSchema = readFileSync(
  fileURLToPath(
    new URL(
      "../migrations-v6/0002_workstream_integrations.sql",
      import.meta.url,
    ),
  ),
  "utf8",
);
const observabilitySchema = readFileSync(
  fileURLToPath(
    new URL(
      "../migrations-v6/0003_usage_audit_observability.sql",
      import.meta.url,
    ),
  ),
  "utf8",
);
const chatMigrationSchema = readFileSync(
  fileURLToPath(
    new URL(
      "../migrations-v6/0004_chat_workstream_mapping.sql",
      import.meta.url,
    ),
  ),
  "utf8",
);
const executionFoundationSchema = readFileSync(
  fileURLToPath(
    new URL("../migrations-v6/0005_execution_foundation.sql", import.meta.url),
  ),
  "utf8",
);
const projectSettingsSchema = readFileSync(
  fileURLToPath(
    new URL("../migrations-v6/0007_project_settings.sql", import.meta.url),
  ),
  "utf8",
);
const grantPolicySchema = readFileSync(
  fileURLToPath(
    new URL(
      "../migrations-v6/0010_workspace_project_grant_policy.sql",
      import.meta.url,
    ),
  ),
  "utf8",
);
const invitationsSchema = readFileSync(
  fileURLToPath(
    new URL("../migrations-v6/0011_project_invitations.sql", import.meta.url),
  ),
  "utf8",
);
const repositoryRemovalSchema = readFileSync(
  fileURLToPath(
    new URL(
      "../migrations-v6/0012_remove_project_repository.sql",
      import.meta.url,
    ),
  ),
  "utf8",
);
const configuredWorkerSchema = readFileSync(
  fileURLToPath(
    new URL("../migrations-v6/0013_configured_workers.sql", import.meta.url),
  ),
  "utf8",
);
const configuredWorkerRuntimeSchema = readFileSync(
  fileURLToPath(
    new URL(
      "../migrations-v6/0014_configured_worker_runtime_state.sql",
      import.meta.url,
    ),
  ),
  "utf8",
);
const configuredWorkerAssignmentsSchema = readFileSync(
  fileURLToPath(
    new URL(
      "../migrations-v6/0015_configured_worker_assignments.sql",
      import.meta.url,
    ),
  ),
  "utf8",
);
const workerFirstExecutionPolicySchema = readFileSync(
  fileURLToPath(
    new URL(
      "../migrations-v6/0016_worker_first_execution_policy.sql",
      import.meta.url,
    ),
  ),
  "utf8",
);
const configuredWorkerObservabilitySchema = readFileSync(
  fileURLToPath(
    new URL(
      "../migrations-v6/0017_configured_worker_observability.sql",
      import.meta.url,
    ),
  ),
  "utf8",
);
const legacyAccountConversionSchema = readFileSync(
  fileURLToPath(
    new URL(
      "../migrations-v6/0018_migrate_legacy_ai_accounts.sql",
      import.meta.url,
    ),
  ),
  "utf8",
);
const workerAssignmentRequesterSchema = readFileSync(
  fileURLToPath(
    new URL(
      "../migrations-v6/0019_worker_assignment_requester.sql",
      import.meta.url,
    ),
  ),
  "utf8",
);
const workspaceRuntimeFactsSchema = readFileSync(
  fileURLToPath(
    new URL(
      "../migrations-v6/0020_workspace_runtime_facts.sql",
      import.meta.url,
    ),
  ),
  "utf8",
);
const workspaceWorkerInventorySchema = readFileSync(
  fileURLToPath(
    new URL(
      "../migrations-v6/0021_workspace_worker_inventory.sql",
      import.meta.url,
    ),
  ),
  "utf8",
);
const adapterReleaseSchema = readFileSync(
  fileURLToPath(
    new URL("../migrations-v6/0022_v7_adapter_releases.sql", import.meta.url),
  ),
  "utf8",
);
const workspaceRuntimeCredentialSchema = readFileSync(
  fileURLToPath(
    new URL(
      "../migrations-v6/0023_workspace_runtime_credentials.sql",
      import.meta.url,
    ),
  ),
  "utf8",
);
const workerSchedulingSchema = readFileSync(
  fileURLToPath(
    new URL("../migrations-v6/0024_v7_worker_scheduling.sql", import.meta.url),
  ),
  "utf8",
);

function apply(sql: string): string {
  return execFileSync("sqlite3", ["-json", ":memory:"], {
    input: `${schema}\n${integrationSchema}\n${observabilitySchema}\n${chatMigrationSchema}\n${executionFoundationSchema}\n${projectSettingsSchema}\n${grantPolicySchema}\n${invitationsSchema}\n${repositoryRemovalSchema}\n${configuredWorkerSchema}\n${configuredWorkerRuntimeSchema}\n${configuredWorkerAssignmentsSchema}\n${workerFirstExecutionPolicySchema}\n${configuredWorkerObservabilitySchema}\n${legacyAccountConversionSchema}\n${workerAssignmentRequesterSchema}\n${workspaceRuntimeFactsSchema}\n${workspaceWorkerInventorySchema}\n${adapterReleaseSchema}\n${workspaceRuntimeCredentialSchema}\n${workerSchedulingSchema}\n${sql}`,
    encoding: "utf8",
  });
}

const fixture = `
INSERT INTO users VALUES ('u1', 'owner@example.test', 'Owner', 'active', '2026-01-01', '2026-01-01');
INSERT INTO projects (id, owner_user_id, name, description, created_at, updated_at)
  VALUES ('p1', 'u1', 'Project', NULL, '2026-01-01', '2026-01-01');
INSERT INTO project_memberships VALUES ('pm1', 'p1', 'u1', 'owner', '2026-01-01', '2026-01-01');
INSERT INTO execution_workspaces VALUES ('ws1', 'u1', 'Workspace', 'online', '2026-01-01', '2026-01-01');
INSERT INTO workspace_runtime_identities
  (id, workspace_id, credential_key_ref, created_at, revoked_at, credential_token_hash)
  VALUES ('runtime1', 'ws1', 'key-ref', '2026-01-01', NULL, 'runtime-token-hash');
INSERT INTO workers VALUES ('worker1', 'Worker', 'active', '2026-01-01', '2026-01-01');
INSERT INTO configured_workers (id, owner_user_id, name, worker_type_id, default_model, concurrency_limit, created_at, updated_at)
  VALUES ('configured-worker1', 'u1', 'Worker Personal', 'worker1', 'model-1', 2, '2026-01-01', '2026-01-01');
INSERT INTO worker_workspace_bindings (worker_id, workspace_id, desired_version_policy, local_readiness, package_status, credential_status, permissions_status, updated_at)
  VALUES ('configured-worker1', 'ws1', 'stable', 'ready', 'ready', 'ready', 'ready', '2026-01-01');
INSERT INTO workspace_worker_credentials (id, worker_id, workspace_id, owner_user_id, auth_type, sharing_policy, local_secret_ref, state, created_at, updated_at)
  VALUES ('credential1', 'configured-worker1', 'ws1', 'u1', 'oauth', 'private_only', 'workspace-secret/credential1', 'ready', '2026-01-01', '2026-01-01');
INSERT INTO workstreams VALUES ('stream1', 'p1', 'Stream', 'active', '{}', 'u1', '2026-01-01', '2026-01-01');
INSERT INTO workstream_execution_policies (workstream_id, mode, primary_workspace_id, require_checkout, max_concurrent_work_requests)
  VALUES ('stream1', 'stateful', 'ws1', 1, 1);
INSERT INTO workflow_definitions VALUES ('wf1', 'p1', 'Workflow', '', NULL, 'u1', '2026-01-01', '2026-01-01');
INSERT INTO workflow_versions VALUES ('wfv1', 'wf1', 1, 'u1', '2026-01-01');
INSERT INTO workflow_steps VALUES ('step1', 'wfv1', 'Implementation', 'implementation', '[]', 'stateful_workstream', 0, '[]', 'none', 1000, '{}');
INSERT INTO workstream_checkouts VALUES ('checkout1', 'stream1', 'ws1', 'repo1', 'abc', 'stream/one', 'ready', '2026-01-01', '2026-01-01');
INSERT INTO work_requests VALUES ('request1', 'stream1', 'u1', 'stateful', 'wf1', 'wfv1', '{}', 'queued', 'ws1', 'checkout1', '{}', '2026-01-01', '2026-01-01');
INSERT INTO workstream_execution_leases VALUES ('lease1', 'stream1', 'checkout1', 'request1', 'ws1', 1, 'active', '2026-01-01', '2026-01-02', NULL);
INSERT INTO workstream_checkpoints VALUES ('checkpoint1', 'stream1', 'checkout1', 1, 'abc', 'initial', 'request1', '2026-01-01');
INSERT INTO runs (id, project_id, workstream_id, work_request_id, workflow_version_id, checkout_id, execution_lease_id, status, created_at, updated_at)
  VALUES ('run1', 'p1', 'stream1', 'request1', 'wfv1', 'checkout1', 'lease1', 'running', '2026-01-01', '2026-01-01');
`;

describe("v6 D1 schema", () => {
  it("applies cleanly with foreign keys enabled", () => {
    const result = JSON.parse(
      apply(`${fixture}\nSELECT name FROM sqlite_master WHERE type = 'table';`),
    );
    expect(result).toEqual(
      expect.arrayContaining([
        { name: "workstreams" },
        { name: "work_requests" },
        { name: "runs" },
        { name: "workstream_integrations" },
        { name: "workstream_audit_log" },
        { name: "chat_workstream_migrations" },
        { name: "configured_workers" },
        { name: "worker_workspace_bindings" },
        { name: "workspace_worker_credentials" },
        { name: "configured_worker_installations" },
        { name: "configured_worker_audit_log" },
        { name: "configured_worker_observability_metrics" },
        { name: "workspace_runtime_facts" },
        { name: "workspace_worker_inventory" },
        { name: "v7_worker_scheduling" },
        { name: "v7_worker_scheduling_audit" },
        { name: "v7_adapter_releases" },
      ]),
    );
  });

  it("keeps local Worker inventory limited to safe synchronized fields", () => {
    const columns = JSON.parse(
      apply("PRAGMA table_info(workspace_worker_inventory);"),
    ).map((column: { name: string }) => column.name);
    expect(columns).toEqual(
      expect.arrayContaining([
        "worker_id",
        "workspace_id",
        "owner_user_id",
        "worker_type_id",
        "status",
        "credential_status",
        "revision",
        "removed_by_snapshot",
      ]),
    );
    expect(columns).not.toEqual(
      expect.arrayContaining([
        "api_key",
        "secret",
        "credential_ref",
        "local_path",
        "working_directory",
      ]),
    );
  });

  it("stores only a runtime credential hash for paired Workspaces", () => {
    const columns = JSON.parse(
      apply("PRAGMA table_info(workspace_runtime_identities);"),
    ).map((column: { name: string }) => column.name);
    expect(columns).toContain("credential_token_hash");
    expect(columns).not.toContain("credential_token");
    expect(columns).not.toContain("auth_token");
  });

  it("enforces one active checkout and one active lease", () => {
    expect(() =>
      apply(
        `${fixture}\nINSERT INTO workstream_checkouts VALUES ('checkout2', 'stream1', 'ws1', 'repo1', 'def', 'stream/two', 'ready', '2026-01-01', '2026-01-01');`,
      ),
    ).toThrow();
    expect(() =>
      apply(
        `${fixture}\nINSERT INTO workstream_execution_leases VALUES ('lease2', 'stream1', 'checkout1', 'request1', 'ws1', 2, 'active', '2026-01-01', '2026-01-02', NULL);`,
      ),
    ).toThrow();
  });

  it("includes the complete Workspace Project Grant policy contract", () => {
    const result = JSON.parse(
      apply("PRAGMA table_info(workspace_project_grants);"),
    ) as Array<{ name: string }>;
    expect(result.map((column) => column.name)).toEqual(
      expect.arrayContaining([
        "allowed_worker_capabilities_json",
        "network_policy_json",
        "concurrency_json",
        "requires_step_up",
      ]),
    );
  });

  it("does not retain a Project repository column", () => {
    const result = JSON.parse(apply("PRAGMA table_info(projects);")) as Array<{
      name: string;
    }>;
    expect(result.map((column) => column.name)).not.toContain("repository_id");
  });

  it("persists configured Workers independently from the Worker Type catalog", () => {
    const result = JSON.parse(
      apply(`${fixture}
        SELECT cw.worker_type_id, b.workspace_id, b.local_readiness, c.state
        FROM configured_workers cw
        JOIN worker_workspace_bindings b ON b.worker_id = cw.id
        JOIN workspace_worker_credentials c ON c.worker_id = cw.id AND c.workspace_id = b.workspace_id;`),
    );
    expect(result).toEqual([
      {
        worker_type_id: "worker1",
        workspace_id: "ws1",
        local_readiness: "ready",
        state: "ready",
      },
    ]);
  });

  it("persists configured Worker audit action constraints", () => {
    expect(() =>
      apply(`${fixture}
      INSERT INTO configured_worker_audit_log
        (id, configured_worker_id, workspace_id, actor_type, actor_id, action, target_id, created_at)
      VALUES ('audit1', 'configured-worker1', 'ws1', 'system', 'system', 'worker.credential.ready', 'configured-worker1:ws1', '2026-01-01');`),
    ).not.toThrow();
    expect(() =>
      apply(`${fixture}
      INSERT INTO configured_worker_audit_log
        (id, configured_worker_id, workspace_id, actor_type, actor_id, action, target_id, created_at)
      VALUES ('audit1', 'configured-worker1', 'ws1', 'system', 'system', 'unsupported.action', 'configured-worker1:ws1', '2026-01-01');`),
    ).toThrow();
  });

  it("enforces configured Worker ownership, binding uniqueness, and readiness indexes", () => {
    expect(() =>
      apply(`${fixture}
        INSERT INTO configured_workers (id, owner_user_id, name, worker_type_id, concurrency_limit, created_at, updated_at)
        VALUES ('configured-worker2', 'u1', 'Worker Personal', 'worker1', 1, '2026-01-01', '2026-01-01');`),
    ).toThrow();
    expect(() =>
      apply(`${fixture}
        INSERT INTO worker_workspace_bindings (worker_id, workspace_id, desired_version_policy, updated_at)
        VALUES ('configured-worker1', 'ws1', 'latest', '2026-01-01');`),
    ).toThrow();
    const indexes = JSON.parse(
      apply(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_v6_%configured_workers%' OR name LIKE 'idx_v6_worker_bindings_active_eligibility';",
      ),
    );
    expect(indexes).toEqual(
      expect.arrayContaining([
        { name: "idx_v6_configured_workers_worker_type" },
        { name: "idx_v6_configured_workers_active_eligibility" },
        { name: "idx_v6_worker_bindings_active_eligibility" },
      ]),
    );
  });

  it("enforces checkpoint parents and foreign keys", () => {
    expect(() =>
      apply(
        `${fixture}\nINSERT INTO workstream_checkpoints VALUES ('checkpoint2', 'stream1', 'missing-checkout', 2, 'def', 'bad', 'request1', '2026-01-01');`,
      ),
    ).toThrow();
    expect(() =>
      apply(
        `${fixture}\nINSERT INTO workstream_checkpoints VALUES ('checkpoint2', 'missing-stream', 'checkout1', 2, 'def', 'bad', 'request1', '2026-01-01');`,
      ),
    ).toThrow();
  });
});
