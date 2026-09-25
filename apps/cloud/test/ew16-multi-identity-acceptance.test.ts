import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { selectProjectExecutionTarget } from "../src/v5-scheduler.js";

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

function apply(sql: string): Array<Record<string, unknown>> {
  return JSON.parse(
    execFileSync("sqlite3", ["-json", ":memory:"], {
      input: `${schema}\n${sql}`,
      encoding: "utf8",
    }),
  ) as Array<Record<string, unknown>>;
}

function candidate(
  configuredWorkerId: string,
  workerTypeId: string,
  workspaceId: string,
  capabilities: string[],
  provider: string,
  allowedWorkerIds = "[]",
) {
  return {
    grant_id: `grant-${workspaceId}`,
    project_id: "project-1",
    workspace_id: workspaceId,
    grant_status: "active",
    scope: "project_repository",
    repository_mappings_json: "[]",
    path_mappings_json: "[]",
    allowed_worker_ids_json: allowedWorkerIds,
    allowed_worker_capabilities_json: JSON.stringify(capabilities),
    allowed_permissions_json: JSON.stringify(["repository:read"]),
    network_policy_json: JSON.stringify({ mode: "deny_all" }),
    concurrency_json: JSON.stringify({ maxConcurrentAssignments: 2 }),
    budget_json: JSON.stringify({ maxCostMicros: 1000 }),
    requires_step_up: 0,
    expires_at: null,
    workspace_name: workspaceId,
    owner_user_id: "owner-1",
    workspace_status: "online",
    runtime_identity_id: `runtime-${workspaceId}`,
    configured_worker_id: configuredWorkerId,
    worker_type_id: workerTypeId,
    publisher: workerTypeId,
    worker_version: "1.0.0",
    capabilities_json: JSON.stringify(capabilities),
    permissions_json: JSON.stringify(["repository:read"]),
    package_status: "ready",
    desired_enabled: 1,
    version_policy: "stable",
    credential_id: `credential-${configuredWorkerId}-${workspaceId}`,
    credential_status: "ready",
    credential_owner_user_id: "owner-1",
    auth_type: "oauth",
    provider_metadata_json: JSON.stringify({ provider }),
    configured_concurrency_limit: 2,
    active_assignments: 0,
    allowed_configured_worker_ids_json: "[]",
    allowed_worker_type_ids_json: "[]",
    allowed_providers_json: "[]",
    allowed_models_json: "[]",
  };
}

function schedulerDb(rows: Record<string, unknown>[]) {
  return {
    prepare(query: string) {
      return {
        bind() {
          return this;
        },
        async first<T>() {
          return query.includes("project_memberships")
            ? ({ role: "owner" } as T)
            : null;
        },
        async all<T>() {
          return { results: rows as T[] };
        },
      };
    },
  } as never;
}

describe("EW-16 multi-identity acceptance", () => {
  it("supports independent identities, Workspace-local auth, subset policy, and usage dimensions", async () => {
    const result = apply(`
      INSERT INTO users VALUES ('owner-1', 'owner@example.test', 'Owner', 'active', 'now', 'now');
      INSERT INTO execution_workspaces VALUES ('workspace-a', 'owner-1', 'Mac', 'online', 'now', 'now');
      INSERT INTO execution_workspaces VALUES ('workspace-b', 'owner-1', 'Linux', 'online', 'now', 'now');
      INSERT INTO workspace_runtime_identities VALUES ('runtime-workspace-a', 'workspace-a', 'ref-a', 'now', NULL);
      INSERT INTO workspace_runtime_identities VALUES ('runtime-workspace-b', 'workspace-b', 'ref-b', 'now', NULL);
      INSERT INTO workers VALUES ('worker-codex', 'Codex', 'active', 'now', 'now');
      INSERT INTO workers VALUES ('worker-claude', 'Claude', 'active', 'now', 'now');
      INSERT INTO worker_versions (id, worker_id, version, capabilities_json, permissions_json, package_digest, created_at)
        VALUES ('version-codex', 'worker-codex', '1.0.0', '["repository"]', '["repository:read"]', 'digest-codex', 'now');
      INSERT INTO worker_versions (id, worker_id, version, capabilities_json, permissions_json, package_digest, created_at)
        VALUES ('version-claude', 'worker-claude', '1.0.0', '["review"]', '["repository:read"]', 'digest-claude', 'now');
      INSERT INTO configured_workers (id, owner_user_id, name, worker_type_id, default_model, concurrency_limit, created_at, updated_at)
        VALUES ('configured-personal', 'owner-1', 'Codex Personal', 'worker-codex', 'codex-fast', 2, 'now', 'now');
      INSERT INTO configured_workers (id, owner_user_id, name, worker_type_id, default_model, concurrency_limit, created_at, updated_at)
        VALUES ('configured-company', 'owner-1', 'Codex Company', 'worker-codex', 'codex-quality', 2, 'now', 'now');
      INSERT INTO configured_workers (id, owner_user_id, name, worker_type_id, default_model, concurrency_limit, created_at, updated_at)
        VALUES ('configured-backup', 'owner-1', 'Codex Backup', 'worker-codex', 'codex-fast', 1, 'now', 'now');
      INSERT INTO configured_workers (id, owner_user_id, name, worker_type_id, default_model, concurrency_limit, created_at, updated_at)
        VALUES ('configured-review', 'owner-1', 'Claude Review', 'worker-claude', 'claude-sonnet', 1, 'now', 'now');
      INSERT INTO worker_workspace_bindings (worker_id, workspace_id, desired_version_policy, local_readiness, package_status, credential_status, permissions_status, last_seen, updated_at)
        VALUES ('configured-personal', 'workspace-a', 'stable', 'ready', 'ready', 'ready', 'ready', 'now', 'now');
      INSERT INTO worker_workspace_bindings (worker_id, workspace_id, desired_version_policy, local_readiness, package_status, credential_status, permissions_status, last_seen, updated_at)
        VALUES ('configured-personal', 'workspace-b', 'stable', 'setup_required', 'ready', 'setup_required', 'ready', 'now', 'now');
      INSERT INTO worker_workspace_bindings (worker_id, workspace_id, desired_version_policy, local_readiness, package_status, credential_status, permissions_status, last_seen, updated_at)
        VALUES ('configured-company', 'workspace-a', 'stable', 'ready', 'ready', 'ready', 'ready', 'now', 'now');
      INSERT INTO worker_workspace_bindings (worker_id, workspace_id, desired_version_policy, local_readiness, package_status, credential_status, permissions_status, last_seen, updated_at)
        VALUES ('configured-company', 'workspace-b', 'stable', 'ready', 'ready', 'ready', 'ready', 'now', 'now');
      INSERT INTO worker_workspace_bindings (worker_id, workspace_id, desired_version_policy, local_readiness, package_status, credential_status, permissions_status, last_seen, updated_at)
        VALUES ('configured-backup', 'workspace-b', 'stable', 'ready', 'ready', 'ready', 'ready', 'now', 'now');
      INSERT INTO worker_workspace_bindings (worker_id, workspace_id, desired_version_policy, local_readiness, package_status, credential_status, permissions_status, last_seen, updated_at)
        VALUES ('configured-review', 'workspace-a', 'stable', 'ready', 'ready', 'ready', 'ready', 'now', 'now');
      INSERT INTO workspace_worker_credentials (id, worker_id, workspace_id, owner_user_id, auth_type, sharing_policy, provider_metadata_json, local_secret_ref, state, created_at, updated_at)
        VALUES ('credential-personal-a', 'configured-personal', 'workspace-a', 'owner-1', 'oauth', 'private_only', '{"provider":"openai"}', 'local://personal-a', 'ready', 'now', 'now');
      INSERT INTO workspace_worker_credentials (id, worker_id, workspace_id, owner_user_id, auth_type, sharing_policy, provider_metadata_json, local_secret_ref, state, created_at, updated_at)
        VALUES ('credential-personal-b', 'configured-personal', 'workspace-b', 'owner-1', 'oauth', 'private_only', '{"provider":"openai"}', 'local://personal-b', 'setup_required', 'now', 'now');
      INSERT INTO workspace_worker_credentials (id, worker_id, workspace_id, owner_user_id, auth_type, sharing_policy, provider_metadata_json, local_secret_ref, state, created_at, updated_at)
        VALUES ('credential-company-a', 'configured-company', 'workspace-a', 'owner-1', 'oauth', 'explicit_project', '{"provider":"openai"}', 'local://company-a', 'ready', 'now', 'now');
      INSERT INTO workspace_worker_credentials (id, worker_id, workspace_id, owner_user_id, auth_type, sharing_policy, provider_metadata_json, local_secret_ref, state, created_at, updated_at)
        VALUES ('credential-company-b', 'configured-company', 'workspace-b', 'owner-1', 'oauth', 'explicit_project', '{"provider":"openai"}', 'local://company-b', 'ready', 'now', 'now');
      INSERT INTO workspace_worker_credentials (id, worker_id, workspace_id, owner_user_id, auth_type, sharing_policy, provider_metadata_json, local_secret_ref, state, created_at, updated_at)
        VALUES ('credential-review-a', 'configured-review', 'workspace-a', 'owner-1', 'oauth', 'explicit_project', '{"provider":"anthropic"}', 'local://review-a', 'ready', 'now', 'now');
      INSERT INTO projects (id, owner_user_id, name, description, created_at, updated_at)
        VALUES ('project-1', 'owner-1', 'Multi identity project', NULL, 'now', 'now');
      INSERT INTO project_memberships VALUES ('membership-1', 'project-1', 'owner-1', 'owner', 'now', 'now');
      INSERT INTO workspace_project_grants (id, project_id, workspace_id, granted_by_user_id, scope, allowed_worker_ids_json, created_at, updated_at)
        VALUES ('grant-a', 'project-1', 'workspace-a', 'owner-1', 'project_repository', '["configured-company","configured-review"]', 'now', 'now');
      INSERT INTO workspace_project_grants (id, project_id, workspace_id, granted_by_user_id, scope, allowed_worker_ids_json, created_at, updated_at)
        VALUES ('grant-b', 'project-1', 'workspace-b', 'owner-1', 'project_repository', '["configured-backup"]', 'now', 'now');
      INSERT INTO usage (id, project_id, requester_user_id, execution_workspace_id, configured_worker_id, worker_type_id, credential_owner_user_id, provider, input_tokens, output_tokens, duration_ms, recorded_at)
        VALUES ('usage-personal', 'project-1', 'owner-1', 'workspace-a', 'configured-personal', 'worker-codex', 'owner-1', 'openai', 10, 20, 100, 'now');
      INSERT INTO usage (id, project_id, requester_user_id, execution_workspace_id, configured_worker_id, worker_type_id, credential_owner_user_id, provider, input_tokens, output_tokens, duration_ms, recorded_at)
        VALUES ('usage-company', 'project-1', 'owner-1', 'workspace-b', 'configured-company', 'worker-codex', 'owner-1', 'openai', 30, 40, 200, 'now');
      INSERT INTO usage (id, project_id, requester_user_id, execution_workspace_id, configured_worker_id, worker_type_id, credential_owner_user_id, provider, input_tokens, output_tokens, duration_ms, recorded_at)
        VALUES ('usage-review', 'project-1', 'owner-1', 'workspace-a', 'configured-review', 'worker-claude', 'owner-1', 'anthropic', 50, 60, 300, 'now');
      SELECT
        (SELECT COUNT(*) FROM configured_workers) AS configured_worker_count,
        (SELECT COUNT(*) FROM worker_workspace_bindings) AS binding_count,
        (SELECT COUNT(*) FROM workspace_worker_credentials WHERE state = 'ready') AS ready_credential_count,
        (SELECT COUNT(*) FROM usage WHERE configured_worker_id IS NOT NULL) AS attributed_usage_count,
        (SELECT COUNT(DISTINCT configured_worker_id) FROM usage) AS distinct_usage_identity_count;
    `);

    expect(result).toEqual([
      {
        configured_worker_count: 4,
        binding_count: 6,
        ready_credential_count: 4,
        attributed_usage_count: 3,
        distinct_usage_identity_count: 3,
      },
    ]);

    const company = await selectProjectExecutionTarget(
      schedulerDb([
        candidate(
          "configured-company",
          "worker-codex",
          "workspace-a",
          ["repository"],
          "openai",
          '["configured-company"]',
        ),
        candidate(
          "configured-backup",
          "worker-codex",
          "workspace-b",
          ["repository"],
          "openai",
          '["configured-backup"]',
        ),
      ]),
      {
        projectId: "project-1",
        requesterUserId: "owner-1",
        role: "implementer",
        capabilities: ["repository"],
        configuredWorkerId: "configured-company",
      },
    );
    expect(company).toMatchObject({
      configuredWorkerId: "configured-company",
      workerTypeId: "worker-codex",
    });

    const review = await selectProjectExecutionTarget(
      schedulerDb([
        candidate(
          "configured-review",
          "worker-claude",
          "workspace-a",
          ["review"],
          "anthropic",
        ),
        candidate(
          "configured-company",
          "worker-codex",
          "workspace-a",
          ["repository"],
          "openai",
        ),
      ]),
      {
        projectId: "project-1",
        requesterUserId: "owner-1",
        role: "reviewer",
        capabilities: ["review"],
      },
    );
    expect(review).toMatchObject({
      configuredWorkerId: "configured-review",
      workerTypeId: "worker-claude",
    });
  });
});
