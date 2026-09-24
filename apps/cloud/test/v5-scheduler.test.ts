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

function db(
  rows: Record<string, unknown>[],
  role = "collaborator",
  lease: Record<string, unknown> | null = null,
) {
  return {
    prepare(query: string) {
      return {
        bind() {
          return this;
        },
        async first<T>() {
          if (query.includes("workstream_execution_leases")) return lease as T;
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

  it("keeps stateless research eligible for an auxiliary Workspace and binds its revision", async () => {
    const target = await selectProjectExecutionTarget(db([candidate()]), {
      projectId: "project-a",
      requesterUserId: "user-requester",
      role: "researcher",
      capabilities: ["repository"],
      executionClass: "stateless_read",
      expectedRevision: "checkpoint-42",
    });
    expect(target).toMatchObject({
      workspaceId: "workspace-a",
      executionClass: "stateless_read",
      expectedRevision: "checkpoint-42",
    });
    expect(target?.permissionSnapshot).toMatchObject({
      checkpointRevision: "checkpoint-42",
    });
  });

  it("forces stateful work through the Primary Workspace active lease", async () => {
    const lease = {
      workstreamId: "workstream-1",
      workRequestId: "work-request-1",
      workspaceId: "workspace-primary",
      checkoutId: "checkout-1",
      leaseId: "lease-1",
      fencingToken: 9,
      expectedRevision: "revision-1",
    };
    const primary = candidate({ workspace_id: "workspace-primary", grant_id: "grant-primary" });
    const auxiliary = candidate({ workspace_id: "workspace-auxiliary", grant_id: "grant-auxiliary" });
    await expect(selectProjectExecutionTarget(db([auxiliary, primary], "collaborator", lease), {
      projectId: "project-a",
      requesterUserId: "user-requester",
      role: "implementer",
      capabilities: ["repository"],
      executionClass: "stateful_workstream",
      workstreamId: "workstream-1",
      workRequestId: "work-request-1",
    })).resolves.toMatchObject({
      workspaceId: "workspace-primary",
      checkoutId: "checkout-1",
      leaseId: "lease-1",
      fencingToken: 9,
      expectedRevision: "revision-1",
      executionClass: "stateful_workstream",
    });
    await expect(selectProjectExecutionTarget(db([primary], "collaborator", lease), {
      projectId: "project-a", requesterUserId: "user-requester", role: "implementer",
      capabilities: ["repository"], executionClass: "stateful_workstream",
      workstreamId: "workstream-1", workRequestId: "work-request-1",
      workspaceId: "workspace-auxiliary",
    })).resolves.toBeNull();
  });

  it("denies stateful work when the Primary Workspace is offline or its Account is unavailable", async () => {
    const lease = {
      workstreamId: "workstream-1",
      workRequestId: "work-request-1",
      workspaceId: "workspace-primary",
      checkoutId: "checkout-1",
      leaseId: "lease-1",
      fencingToken: 1,
      expectedRevision: "revision-1",
    };
    await expect(selectProjectExecutionTarget(db([], "collaborator", lease), {
      projectId: "project-a", requesterUserId: "user-requester", role: "implementer",
      capabilities: ["repository"], executionClass: "stateful_workstream",
      workstreamId: "workstream-1", workRequestId: "work-request-1",
    })).resolves.toBeNull();
    await expect(selectProjectExecutionTarget(db([candidate({ workspace_id: "workspace-primary", workspace_status: "offline" })], "collaborator", lease), {
      projectId: "project-a", requesterUserId: "user-requester", role: "implementer",
      capabilities: ["repository"], executionClass: "stateful_workstream",
      workstreamId: "workstream-1", workRequestId: "work-request-1",
    })).resolves.toBeNull();
    await expect(selectProjectExecutionTarget(db([candidate({ workspace_id: "workspace-primary", account_status: "revoked" })], "collaborator", lease), {
      projectId: "project-a", requesterUserId: "user-requester", role: "implementer",
      capabilities: ["repository"], executionClass: "stateful_workstream",
      workstreamId: "workstream-1", workRequestId: "work-request-1",
    })).resolves.toBeNull();
  });

  it("rechecks revoked Workspace and Account grants before dispatch", async () => {
    await expect(selectProjectExecutionTarget(db([
      candidate({ grant_status: "revoked" }),
    ]), {
      projectId: "project-a", requesterUserId: "user-requester", role: "implementer",
      capabilities: ["repository"],
    })).resolves.toBeNull();
    await expect(selectProjectExecutionTarget(db([
      candidate({ account_grant_id: "account-grant-1", account_status: "revoked" }),
    ]), {
      projectId: "project-a", requesterUserId: "user-requester", role: "implementer",
      capabilities: ["repository"],
    })).resolves.toBeNull();
  });

  it("applies Workspace capacity after the Workstream lease boundary", async () => {
    const lease = {
      workstreamId: "workstream-1", workRequestId: "work-request-1",
      workspaceId: "workspace-primary", checkoutId: "checkout-1",
      leaseId: "lease-1", fencingToken: 2, expectedRevision: "revision-1",
    };
    await expect(selectProjectExecutionTarget(db([
      candidate({ workspace_id: "workspace-primary", active_assignments: 2 }),
    ], "collaborator", lease), {
      projectId: "project-a", requesterUserId: "user-requester", role: "implementer",
      capabilities: ["repository"], executionClass: "stateful_workstream",
      workstreamId: "workstream-1", workRequestId: "work-request-1",
    })).resolves.toBeNull();
  });
});
