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
    path_mappings_json: JSON.stringify([
      { projectPath: "/repo", workspacePath: "/work/repo" },
    ]),
    allowed_worker_ids_json: "[]",
    allowed_worker_capabilities_json: JSON.stringify(["repository"]),
    allowed_permissions_json: JSON.stringify([
      "repository:read",
      "repository:write",
    ]),
    network_policy_json: JSON.stringify({ mode: "deny_all", allowedHosts: [] }),
    concurrency_json: JSON.stringify({ maxConcurrentAssignments: 2 }),
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
    credential_sharing_policy: "explicit_project",
    provider_metadata_json: JSON.stringify({
      provider: "provider-a",
    }),
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

  it("selects a configured Worker without requiring an Account candidate", async () => {
    const target = await selectProjectExecutionTarget(
      db([
        candidate({
          configured_worker_id: "configured-codex",
          worker_type_id: "worker-type-codex",
          package_status: "ready",
          credential_status: "ready",
          credential_id: "credential-workspace-a",
          credential_owner_user_id: "user-contributor",
          configured_concurrency_limit: 2,
          account_id: null,
          account_status: null,
        }),
      ]),
      {
        projectId: "project-a",
        requesterUserId: "user-requester",
        role: "implementer",
        capabilities: ["repository"],
        configuredWorkerId: "configured-codex",
      },
    );
    expect(target).toMatchObject({
      configuredWorkerId: "configured-codex",
      workerTypeId: "worker-type-codex",
      credentialId: "credential-workspace-a",
      credentialOwnerUserId: "user-contributor",
    });
    expect(target?.selectionExplanation.filters).toContain("credential_ready");
  });

  it("rejects unavailable capacity, grant capability mismatch, and missing Account", async () => {
    await expect(
      selectProjectExecutionTarget(db([candidate({ active_assignments: 2 })]), {
        projectId: "project-a",
        requesterUserId: "user-requester",
        role: "implementer",
        capabilities: ["repository"],
      }),
    ).resolves.toBeNull();
    await expect(
      selectProjectExecutionTarget(
        db([
          candidate({
            allowed_worker_capabilities_json: JSON.stringify(["shell"]),
          }),
        ]),
        {
          projectId: "project-a",
          requesterUserId: "user-requester",
          role: "implementer",
          capabilities: ["repository"],
        },
      ),
    ).resolves.toBeNull();
    await expect(
      selectProjectExecutionTarget(db([]), {
        projectId: "project-a",
        requesterUserId: "user-requester",
        role: "implementer",
        capabilities: ["repository"],
      }),
    ).resolves.toBeNull();
  });

  it("honors explicit Workspace selection and automatic selection", async () => {
    const rows = [
      candidate({
        grant_id: "grant-b",
        workspace_id: "workspace-b",
        runtime_identity_id: "runtime-b",
        active_assignments: 1,
      }),
      candidate({
        grant_id: "grant-a",
        workspace_id: "workspace-a",
        runtime_identity_id: "runtime-a",
        active_assignments: 0,
      }),
    ];
    await expect(
      selectProjectExecutionTarget(db(rows), {
        projectId: "project-a",
        requesterUserId: "user-requester",
        role: "implementer",
        capabilities: ["repository"],
        workspaceId: "workspace-b",
      }),
    ).resolves.toMatchObject({ workspaceId: "workspace-b" });
    await expect(
      selectProjectExecutionTarget(db(rows), {
        projectId: "project-a",
        requesterUserId: "user-requester",
        role: "implementer",
        capabilities: ["repository"],
      }),
    ).resolves.toMatchObject({ workspaceId: "workspace-a" });
  });

  it("rejects Project viewers before considering execution capacity", async () => {
    await expect(
      selectProjectExecutionTarget(db([candidate()], "viewer"), {
        projectId: "project-a",
        requesterUserId: "user-viewer",
        role: "reviewer",
        capabilities: [],
      }),
    ).resolves.toBeNull();
  });

  it("rejects private credentials for another requester", async () => {
    await expect(
      selectProjectExecutionTarget(
        db([
          candidate({
            credential_sharing_policy: "private_only",
            credential_owner_user_id: "user-owner",
          }),
        ]),
        {
          projectId: "project-a",
          requesterUserId: "user-requester",
          role: "implementer",
          capabilities: ["repository"],
        },
      ),
    ).resolves.toBeNull();
    await expect(
      selectProjectExecutionTarget(
        db([
          candidate({
            credential_sharing_policy: "private_only",
            credential_owner_user_id: "user-requester",
          }),
        ]),
        {
          projectId: "project-a",
          requesterUserId: "user-requester",
          role: "implementer",
          capabilities: ["repository"],
        },
      ),
    ).resolves.toMatchObject({ configuredWorkerId: "worker-a" });
  });

  it("rejects revoked grants, credentials, stale packages, and permission escalation", async () => {
    for (const overrides of [
      { grant_status: "revoked" },
      { credential_status: "revoked" },
      { package_status: "failed" },
      { permissions_json: JSON.stringify(["shell:execute"]) },
    ]) {
      await expect(
        selectProjectExecutionTarget(db([candidate(overrides)]), {
          projectId: "project-a",
          requesterUserId: "user-requester",
          role: "implementer",
          capabilities: ["repository"],
        }),
      ).resolves.toBeNull();
    }
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
    const primary = candidate({
      workspace_id: "workspace-primary",
      grant_id: "grant-primary",
    });
    const auxiliary = candidate({
      workspace_id: "workspace-auxiliary",
      grant_id: "grant-auxiliary",
    });
    await expect(
      selectProjectExecutionTarget(
        db([auxiliary, primary], "collaborator", lease),
        {
          projectId: "project-a",
          requesterUserId: "user-requester",
          role: "implementer",
          capabilities: ["repository"],
          executionClass: "stateful_workstream",
          workstreamId: "workstream-1",
          workRequestId: "work-request-1",
        },
      ),
    ).resolves.toMatchObject({
      workspaceId: "workspace-primary",
      checkoutId: "checkout-1",
      leaseId: "lease-1",
      fencingToken: 9,
      expectedRevision: "revision-1",
      executionClass: "stateful_workstream",
    });
    await expect(
      selectProjectExecutionTarget(db([primary], "collaborator", lease), {
        projectId: "project-a",
        requesterUserId: "user-requester",
        role: "implementer",
        capabilities: ["repository"],
        executionClass: "stateful_workstream",
        workstreamId: "workstream-1",
        workRequestId: "work-request-1",
        workspaceId: "workspace-auxiliary",
      }),
    ).resolves.toBeNull();
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
    await expect(
      selectProjectExecutionTarget(db([], "collaborator", lease), {
        projectId: "project-a",
        requesterUserId: "user-requester",
        role: "implementer",
        capabilities: ["repository"],
        executionClass: "stateful_workstream",
        workstreamId: "workstream-1",
        workRequestId: "work-request-1",
      }),
    ).resolves.toBeNull();
    await expect(
      selectProjectExecutionTarget(
        db(
          [
            candidate({
              workspace_id: "workspace-primary",
              workspace_status: "offline",
            }),
          ],
          "collaborator",
          lease,
        ),
        {
          projectId: "project-a",
          requesterUserId: "user-requester",
          role: "implementer",
          capabilities: ["repository"],
          executionClass: "stateful_workstream",
          workstreamId: "workstream-1",
          workRequestId: "work-request-1",
        },
      ),
    ).resolves.toBeNull();
    await expect(
      selectProjectExecutionTarget(
        db(
          [
            candidate({
              workspace_id: "workspace-primary",
              account_status: "revoked",
            }),
          ],
          "collaborator",
          lease,
        ),
        {
          projectId: "project-a",
          requesterUserId: "user-requester",
          role: "implementer",
          capabilities: ["repository"],
          executionClass: "stateful_workstream",
          workstreamId: "workstream-1",
          workRequestId: "work-request-1",
        },
      ),
    ).resolves.toBeNull();
  });

  it("rechecks revoked Workspace and Account grants before dispatch", async () => {
    await expect(
      selectProjectExecutionTarget(
        db([candidate({ grant_status: "revoked" })]),
        {
          projectId: "project-a",
          requesterUserId: "user-requester",
          role: "implementer",
          capabilities: ["repository"],
        },
      ),
    ).resolves.toBeNull();
    await expect(
      selectProjectExecutionTarget(
        db([
          candidate({
            account_grant_id: "account-grant-1",
            account_status: "revoked",
          }),
        ]),
        {
          projectId: "project-a",
          requesterUserId: "user-requester",
          role: "implementer",
          capabilities: ["repository"],
        },
      ),
    ).resolves.toBeNull();
  });

  it("applies Workspace capacity after the Workstream lease boundary", async () => {
    const lease = {
      workstreamId: "workstream-1",
      workRequestId: "work-request-1",
      workspaceId: "workspace-primary",
      checkoutId: "checkout-1",
      leaseId: "lease-1",
      fencingToken: 2,
      expectedRevision: "revision-1",
    };
    await expect(
      selectProjectExecutionTarget(
        db(
          [
            candidate({
              workspace_id: "workspace-primary",
              active_assignments: 2,
            }),
          ],
          "collaborator",
          lease,
        ),
        {
          projectId: "project-a",
          requesterUserId: "user-requester",
          role: "implementer",
          capabilities: ["repository"],
          executionClass: "stateful_workstream",
          workstreamId: "workstream-1",
          workRequestId: "work-request-1",
        },
      ),
    ).resolves.toBeNull();
  });

  it("selects a V7 Workspace-owned configured Worker from inventory", async () => {
    const v7Candidate = {
      grant_id: "grant-v7",
      project_id: "project-v7",
      workspace_id: "workspace-v7",
      grant_status: "active",
      scope: "project_repository",
      repository_mappings_json: "[]",
      path_mappings_json: JSON.stringify([
        { projectPath: "/repo", workspacePath: "/work/repo" },
      ]),
      allowed_worker_ids_json: "[]",
      allowed_worker_capabilities_json: JSON.stringify(["code", "shell"]),
      allowed_permissions_json: JSON.stringify([
        "repository:read",
        "repository:write",
      ]),
      network_policy_json: JSON.stringify({
        mode: "deny_all",
        allowedHosts: [],
      }),
      concurrency_json: JSON.stringify({ maxConcurrentAssignments: 4 }),
      requires_step_up: 0,
      expires_at: null,
      workspace_name: "MacBook Pro",
      owner_user_id: "user-developer",
      workspace_status: "online",
      runtime_identity_id: "runtime-v7",
      configured_worker_id: "worker-antigravity-1",
      worker_type_id: "antigravity",
      publisher: "antigravity",
      worker_version: "1.0.0",
      capabilities_json: JSON.stringify(["code", "shell"]),
      permissions_json: JSON.stringify(["repository:read", "repository:write"]),
      package_status: "ready",
      desired_enabled: 1,
      version_policy: "latest",
      credential_id: null,
      credential_status: "ready",
      credential_sharing_policy: "explicit_project",
      credential_owner_user_id: "user-developer",
      auth_type: "browser_auth",
      provider_metadata_json: JSON.stringify({
        provider: "antigravity",
      }),
      configured_concurrency_limit: 2,
      active_assignments: 0,
    };

    const target = await selectProjectExecutionTarget(
      db([v7Candidate], "collaborator"),
      {
        projectId: "project-v7",
        requesterUserId: "user-requester",
        role: "implementer",
        capabilities: ["code"],
      },
    );

    expect(target).toMatchObject({
      projectId: "project-v7",
      workspaceId: "workspace-v7",
      configuredWorkerId: "worker-antigravity-1",
      workerTypeId: "antigravity",
      effectivePermissions: ["repository:read", "repository:write"],
    });
  });

  it("narrows candidate Workers based on Workstream execution policy", async () => {
    const v7Worker = {
      grant_id: "grant-v7",
      project_id: "project-v7",
      workspace_id: "workspace-v7",
      grant_status: "active",
      scope: "project_repository",
      repository_mappings_json: "[]",
      path_mappings_json: "[]",
      allowed_worker_ids_json: "[]",
      allowed_worker_capabilities_json: JSON.stringify(["code"]),
      allowed_permissions_json: JSON.stringify([
        "repository:read",
        "repository:write",
      ]),
      network_policy_json: JSON.stringify({ mode: "deny_all" }),
      concurrency_json: JSON.stringify({ maxConcurrentAssignments: 2 }),
      requires_step_up: 0,
      expires_at: null,
      workspace_name: "MacBook Pro",
      owner_user_id: "user-developer",
      workspace_status: "online",
      runtime_identity_id: "runtime-v7",
      configured_worker_id: "worker-openai-1",
      worker_type_id: "openai-api",
      publisher: "openai-api",
      worker_version: "1.0.0",
      capabilities_json: JSON.stringify(["code"]),
      permissions_json: JSON.stringify(["repository:read"]),
      package_status: "ready",
      desired_enabled: 1,
      version_policy: "latest",
      credential_id: null,
      credential_status: "ready",
      credential_sharing_policy: "explicit_project",
      credential_owner_user_id: "user-developer",
      auth_type: "api_key",
      provider_metadata_json: JSON.stringify({
        provider: "openai-api",
        models: ["gpt-5.5"],
      }),
      configured_concurrency_limit: 1,
      active_assignments: 0,
    };

    // 1. Rejected if allowed_configured_worker_ids_json excludes this worker
    await expect(
      selectProjectExecutionTarget(
        db(
          [
            {
              ...v7Worker,
              allowed_configured_worker_ids_json: JSON.stringify([
                "other-worker",
              ]),
            },
          ],
          "collaborator",
        ),
        {
          projectId: "project-v7",
          requesterUserId: "user-requester",
          role: "implementer",
          capabilities: ["code"],
        },
      ),
    ).resolves.toBeNull();

    // 2. Rejected if allowed_worker_type_ids_json excludes this worker type
    await expect(
      selectProjectExecutionTarget(
        db(
          [
            {
              ...v7Worker,
              allowed_worker_type_ids_json: JSON.stringify(["anthropic-api"]),
            },
          ],
          "collaborator",
        ),
        {
          projectId: "project-v7",
          requesterUserId: "user-requester",
          role: "implementer",
          capabilities: ["code"],
        },
      ),
    ).resolves.toBeNull();

    // 3. Rejected if allowed_models_json excludes requested model
    await expect(
      selectProjectExecutionTarget(
        db(
          [{ ...v7Worker, allowed_models_json: JSON.stringify(["gpt-4o"]) }],
          "collaborator",
        ),
        {
          projectId: "project-v7",
          requesterUserId: "user-requester",
          role: "implementer",
          capabilities: ["code"],
          model: "gpt-5.5",
        },
      ),
    ).resolves.toBeNull();

    // 4. Allowed when matching policy
    await expect(
      selectProjectExecutionTarget(
        db(
          [
            {
              ...v7Worker,
              allowed_configured_worker_ids_json: JSON.stringify([
                "worker-openai-1",
              ]),
              allowed_worker_type_ids_json: JSON.stringify(["openai-api"]),
              allowed_models_json: JSON.stringify(["gpt-5.5"]),
            },
          ],
          "collaborator",
        ),
        {
          projectId: "project-v7",
          requesterUserId: "user-requester",
          role: "implementer",
          capabilities: ["code"],
          model: "gpt-5.5",
        },
      ),
    ).resolves.toMatchObject({
      configuredWorkerId: "worker-openai-1",
      workerTypeId: "openai-api",
      model: "gpt-5.5",
      effectivePermissions: ["repository:read"],
    });
  });

  it("enforces local permission ceilings and prevents Cloud permission broadening", async () => {
    const v7Worker = {
      grant_id: "grant-v7",
      project_id: "project-v7",
      workspace_id: "workspace-v7",
      grant_status: "active",
      scope: "project_repository",
      repository_mappings_json: "[]",
      path_mappings_json: "[]",
      allowed_worker_ids_json: "[]",
      allowed_worker_capabilities_json: JSON.stringify(["code"]),
      // Cloud grant allows shell:execute and network:use
      allowed_permissions_json: JSON.stringify([
        "repository:read",
        "repository:write",
        "shell:execute",
        "network:use",
      ]),
      network_policy_json: JSON.stringify({ mode: "allow_all" }),
      concurrency_json: JSON.stringify({ maxConcurrentAssignments: 2 }),
      requires_step_up: 0,
      expires_at: null,
      workspace_name: "MacBook Pro",
      owner_user_id: "user-developer",
      workspace_status: "online",
      runtime_identity_id: "runtime-v7",
      configured_worker_id: "worker-sandboxed",
      worker_type_id: "codex",
      publisher: "codex",
      worker_version: "1.0.0",
      capabilities_json: JSON.stringify(["code"]),
      // Local worker manifest / local permissions ONLY permit repository:read
      permissions_json: JSON.stringify(["repository:read"]),
      package_status: "ready",
      desired_enabled: 1,
      version_policy: "latest",
      credential_id: null,
      credential_status: "ready",
      credential_sharing_policy: "explicit_project",
      credential_owner_user_id: "user-developer",
      auth_type: "api_key",
      provider_metadata_json: JSON.stringify({ provider: "codex" }),
      configured_concurrency_limit: 1,
      active_assignments: 0,
    };

    // Owner requester has owner permissions in Cloud, but effective permissions are strictly bounded by local permissions
    const target = await selectProjectExecutionTarget(db([v7Worker], "owner"), {
      projectId: "project-v7",
      requesterUserId: "user-developer",
      role: "owner",
      capabilities: ["code"],
    });

    expect(target).not.toBeNull();
    expect(target?.effectivePermissions).toEqual(["repository:read"]);
    expect(target?.effectivePermissions).not.toContain("shell:execute");
    expect(target?.effectivePermissions).not.toContain("network:use");
  });
});
