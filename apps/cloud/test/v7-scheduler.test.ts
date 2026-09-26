import { describe, expect, it } from "vitest";
import { selectProjectExecutionTarget } from "../src/v7-scheduler.js";

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
    worker_type_id: "codex",
    publisher: "codex",
    worker_version: "1.0.0",
    capabilities_json: JSON.stringify(["repository"]),
    local_permissions_json: JSON.stringify([
      "repository:read",
      "repository:write",
    ]),
    worker_allowed_models_json: "[]",
    worker_default_model: null,
    local_worker_status: "ready",
    cloud_scheduling_state: "enabled",
    credential_status: "ready",
    provider: "codex",
    local_concurrency_limit: 2,
    active_assignments: 0,
    allowed_workspace_worker_ids_json: "[]",
    allowed_worker_type_ids_json: "[]",
    allowed_providers_json: "[]",
    allowed_models_json: "[]",
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

describe("V7 Project execution scheduler", () => {
  it("selects a V7 Workspace-owned Worker from inventory", async () => {
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
      worker_id: "worker-antigravity-1",
      worker_type_id: "antigravity",
      publisher: "antigravity",
      worker_version: "1.0.0",
      capabilities_json: JSON.stringify(["code", "shell"]),
      local_permissions_json: JSON.stringify([
        "repository:read",
        "repository:write",
      ]),
      local_worker_status: "ready",
      cloud_scheduling_state: "enabled",
      credential_status: "ready",
      provider: "antigravity",
      local_concurrency_limit: 2,
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
      workerId: "worker-antigravity-1",
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
      worker_id: "worker-openai-1",
      worker_type_id: "openai-api",
      publisher: "openai-api",
      worker_version: "1.0.0",
      capabilities_json: JSON.stringify(["code"]),
      local_permissions_json: JSON.stringify(["repository:read"]),
      local_worker_status: "ready",
      cloud_scheduling_state: "enabled",
      credential_status: "ready",
      provider: "openai-api",
      local_concurrency_limit: 1,
      active_assignments: 0,
    };

    // 1. Rejected if allowed_workspace_worker_ids_json excludes this worker
    await expect(
      selectProjectExecutionTarget(
        db(
          [
            {
              ...v7Worker,
              allowed_workspace_worker_ids_json: JSON.stringify([
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
              allowed_workspace_worker_ids_json: JSON.stringify([
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
      workerId: "worker-openai-1",
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
      worker_id: "worker-sandboxed",
      worker_type_id: "codex",
      publisher: "codex",
      worker_version: "1.0.0",
      capabilities_json: JSON.stringify(["code"]),
      // Local worker manifest / local permissions ONLY permit repository:read
      local_permissions_json: JSON.stringify(["repository:read"]),
      local_worker_status: "ready",
      cloud_scheduling_state: "enabled",
      credential_status: "ready",
      provider: "codex",
      local_concurrency_limit: 1,
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

  it("requires independent Cloud enablement and local readiness for V7 scheduling", async () => {
    const base = {
      ...candidate(),
      workspace_id: "workspace-v7",
      worker_id: "worker-v7",
      worker_type_id: "codex",
      capabilities_json: '["repository"]',
      local_permissions_json: '["repository:read"]',
      credential_status: "ready",
      local_worker_status: "ready",
      cloud_scheduling_state: "disabled",
      cloud_concurrency_limit: null,
      local_concurrency_limit: 2,
      active_assignments: 0,
    };
    const request = {
      projectId: "project-a",
      requesterUserId: "user-requester",
      role: "implementer",
      capabilities: ["repository"],
    };
    await expect(
      selectProjectExecutionTarget(db([base]), request),
    ).resolves.toBeNull();
    await expect(
      selectProjectExecutionTarget(
        db([{ ...base, cloud_scheduling_state: "draining" }]),
        request,
      ),
    ).resolves.toBeNull();
    await expect(
      selectProjectExecutionTarget(
        db([
          {
            ...base,
            cloud_scheduling_state: "enabled",
            local_worker_status: "disabled",
          },
        ]),
        request,
      ),
    ).resolves.toBeNull();
    await expect(
      selectProjectExecutionTarget(
        db([
          {
            ...base,
            cloud_scheduling_state: "enabled",
            local_worker_status: "needs_attention",
          },
        ]),
        request,
      ),
    ).resolves.toBeNull();
    await expect(
      selectProjectExecutionTarget(
        db([{ ...base, cloud_scheduling_state: "enabled" }]),
        request,
      ),
    ).resolves.toMatchObject({ workerId: "worker-v7" });
    await expect(
      selectProjectExecutionTarget(
        db([
          { ...base, cloud_scheduling_state: "enabled", active_assignments: 2 },
        ]),
        request,
      ),
    ).resolves.toBeNull();
    await expect(
      selectProjectExecutionTarget(
        db([
          {
            ...base,
            cloud_scheduling_state: "enabled",
            cloud_concurrency_limit: 1,
            active_assignments: 1,
          },
        ]),
        request,
      ),
    ).resolves.toBeNull();
  });

  it("selects V7 inventory without reading V6 Worker bindings", async () => {
    const v7Row = {
      ...candidate(),
      worker_id: "workspace-worker",
      worker_type_id: "codex",
      local_worker_status: "ready",
      cloud_scheduling_state: "enabled",
      local_concurrency_limit: 1,
      local_permissions_json: '["repository:read"]',
      provider: "codex",
      credential_status: "ready",
      active_assignments: 0,
    };
    let legacyBindingsRead = false;
    const v7OnlyDb = {
      prepare(query: string) {
        const statement = {
          bind() {
            return statement;
          },
          async first<T>() {
            if (query.includes("project_memberships"))
              return { role: "owner" } as T;
            if (query.includes("AS has_v7")) return { has_v7: 1 } as T;
            return null;
          },
          async all<T>() {
            if (query.includes("workspace_worker_inventory"))
              return { results: [v7Row] as T[] };
            if (query.includes("worker_workspace_bindings"))
              legacyBindingsRead = true;
            return { results: [] as T[] };
          },
        };
        return statement;
      },
    } as never;
    const target = await selectProjectExecutionTarget(v7OnlyDb, {
      projectId: "project-a",
      requesterUserId: "user-requester",
      role: "implementer",
      capabilities: ["repository"],
    });
    expect(target?.workerId).toBe("workspace-worker");
    expect(legacyBindingsRead).toBe(false);
  });
});
