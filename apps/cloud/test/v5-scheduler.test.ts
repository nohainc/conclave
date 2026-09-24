import { describe, expect, it } from "vitest";
import { selectProjectExecutionTarget } from "../src/v5-scheduler.js";

function candidate(overrides: Record<string, unknown> = {}) {
  return {
    grant_id: "grant-a",
    project_id: "project-a",
    workspace_id: "workspace-a",
    grant_status: "active",
    scope: "project_repository",
    repository_mappings_json: "[]",
    path_mappings_json: JSON.stringify([{ projectPath: "/repo", workspacePath: "/work/repo" }]),
    allowed_worker_ids_json: "[]",
    allowed_worker_capabilities_json: JSON.stringify(["repository"]),
    allowed_permissions_json: JSON.stringify(["repository:read", "repository:write"]),
    network_policy_json: JSON.stringify({ mode: "deny_all", allowedHosts: [] }),
    concurrency_json: JSON.stringify({ maxConcurrentAssignments: 2 }),
    budget_json: JSON.stringify({ maxCostMicros: 100 }),
    requires_step_up: 0,
    expires_at: null,
    workspace_name: "Contributor Workspace",
    owner_user_id: "user-contributor",
    workspace_status: "online",
    runtime_identity_id: "runtime-a",
    worker_id: "worker-a",
    publisher: "provider-a",
    worker_version: "1.0.0",
    capabilities_json: JSON.stringify(["repository"]),
    permissions_json: JSON.stringify(["repository:read", "repository:write"]),
    installation_status: "ready",
    desired_enabled: 1,
    version_policy: "latest",
    account_id: "account-a",
    account_status: "ready",
    account_owner_user_id: "user-contributor",
    auth_type: "oauth",
    account_workspace_id: "workspace-a",
    provider_metadata_json: JSON.stringify({ provider: "provider-a", estimatedCostMicros: 10 }),
    account_grant_id: null,
    active_assignments: 0,
    ...overrides,
  };
}

function db(rows: Record<string, unknown>[], role = "collaborator") {
  return {
    prepare(query: string) {
      return {
        bind() {
          return this;
        },
        async first<T>() {
          return query.includes("project_memberships") ? ({ role } as T) : null;
        },
        async all<T>() {
          return { results: rows as T[] };
        },
      };
    },
  } as never;
}

describe("V5 Project execution scheduler", () => {
  it("selects an online ready Worker from a contributor Workspace", async () => {
    const target = await selectProjectExecutionTarget(db([candidate()]), {
      projectId: "project-a",
      requesterUserId: "user-requester",
      role: "implementer",
      capabilities: ["repository"],
    });
    expect(target).toMatchObject({
      projectId: "project-a",
      workspaceId: "workspace-a",
      workerId: "worker-a",
      accountId: "account-a",
      effectivePermissions: ["repository:read", "repository:write"],
    });
    expect(target?.selectionExplanation.filters).toContain("grant_active");
  });

  it("rejects unavailable capacity, grant capability mismatch, and missing Account", async () => {
    await expect(selectProjectExecutionTarget(db([candidate({ active_assignments: 2 })]), {
      projectId: "project-a", requesterUserId: "user-requester", role: "implementer", capabilities: ["repository"],
    })).resolves.toBeNull();
    await expect(selectProjectExecutionTarget(db([candidate({ allowed_worker_capabilities_json: JSON.stringify(["shell"]) })]), {
      projectId: "project-a", requesterUserId: "user-requester", role: "implementer", capabilities: ["repository"],
    })).resolves.toBeNull();
    await expect(selectProjectExecutionTarget(db([]), {
      projectId: "project-a", requesterUserId: "user-requester", role: "implementer", capabilities: ["repository"],
    })).resolves.toBeNull();
  });

  it("honors explicit Workspace selection and automatic selection", async () => {
    const rows = [
      candidate({ grant_id: "grant-b", workspace_id: "workspace-b", runtime_identity_id: "runtime-b", active_assignments: 1 }),
      candidate({ grant_id: "grant-a", workspace_id: "workspace-a", runtime_identity_id: "runtime-a", active_assignments: 0 }),
    ];
    await expect(selectProjectExecutionTarget(db(rows), {
      projectId: "project-a", requesterUserId: "user-requester", role: "implementer", capabilities: ["repository"], workspaceId: "workspace-b",
    })).resolves.toMatchObject({ workspaceId: "workspace-b" });
    await expect(selectProjectExecutionTarget(db(rows), {
      projectId: "project-a", requesterUserId: "user-requester", role: "implementer", capabilities: ["repository"],
    })).resolves.toMatchObject({ workspaceId: "workspace-a" });
  });

  it("rejects Project viewers before considering execution capacity", async () => {
    await expect(selectProjectExecutionTarget(db([candidate()], "viewer"), {
      projectId: "project-a", requesterUserId: "user-viewer", role: "reviewer", capabilities: [],
    })).resolves.toBeNull();
  });
});
