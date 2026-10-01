import { describe, expect, it, vi } from "vitest";
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
    worker_type_id: "chatgpt",
    publisher: "chatgpt",
    engine_version: "1.0.0",
    profile_definition_id: "chatgpt-codex",
    profile_release_version: 3,
    provider_tool_name: "Codex CLI",
    provider_tool_version: "0.44.0",
    capabilities_json: JSON.stringify(["repository"]),
    local_permissions_json: JSON.stringify([
      "repository:read",
      "repository:write",
    ]),
    worker_allowed_models_json: "[]",
    worker_default_model: null,
    local_worker_activation_state: "enabled",
    local_worker_readiness_state: "ready",
    cloud_scheduling_state: "enabled",
    credential_status: "ready",
    provider: "chatgpt",
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
          if (query.includes("workstream_runtime_leases")) return lease as T;
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
  it("uses the AX Step binding for Worker and model", async () => {
    const configured = candidate({
      workstream_work_config_json: JSON.stringify({
        defaultWorkflowId: "full_cycle",
        bindings: {
          implement: {
            workerId: "worker-a",
            model: "gpt-5.6-codex",
          },
        },
      }),
    });
    const result = await selectProjectExecutionTarget(db([configured]), {
      projectId: "project-a",
      requesterUserId: "user-a",
      role: "Implementer",
      capabilities: ["repository"],
      workstreamId: "workstream-a",
      workBindingId: "implement" as const,
    });
    expect(result).toMatchObject({
      workerId: "worker-a",
      workerTypeId: "chatgpt",
      engineVersion: "1.0.0",
      profileDefinitionId: "chatgpt-codex",
      profileReleaseVersion: 3,
      providerToolName: "Codex CLI",
      providerToolVersion: "0.44.0",
      permissionSnapshot: {
        engineVersion: "1.0.0",
        profileDefinitionId: "chatgpt-codex",
        profileReleaseVersion: 3,
        model: "gpt-5.6-codex",
        providerToolName: "Codex CLI",
        providerToolVersion: "0.44.0",
      },
      model: "gpt-5.6-codex",
      selectionExplanation: {
        worker: {
          workBindingId: "implement",
          engineVersion: "1.0.0",
          profileDefinitionId: "chatgpt-codex",
          profileReleaseVersion: 3,
          providerToolName: "Codex CLI",
          providerToolVersion: "0.44.0",
          selection: "configured_preference",
        },
      },
    });

    const atLimit = await selectProjectExecutionTarget(
      db([candidate({ ...configured, active_assignments: 2 })]),
      {
        projectId: "project-a",
        requesterUserId: "user-a",
        role: "implementer",
        capabilities: ["repository"],
        workstreamId: "workstream-a",
        workBindingId: "implement",
      },
    );
    expect(atLimit).toBeNull();
  });

  it("requires AX to configure a Workstream Step before dispatch", async () => {
    const result = await selectProjectExecutionTarget(db([candidate()]), {
      projectId: "project-a",
      requesterUserId: "user-a",
      role: "reviewer",
      capabilities: ["repository"],
      workstreamId: "workstream-a",
      workBindingId: "verify",
    });
    expect(result).toBeNull();
  });

  it("treats Workstream Worker Type policy as product IDs", async () => {
    const configured = {
      ...candidate(),
      workstream_work_config_json: JSON.stringify({
        defaultWorkflowId: "full_cycle",
        bindings: { implement: { workerId: "worker-a" } },
      }),
    };
    const request = {
      projectId: "project-a",
      requesterUserId: "user-a",
      role: "implementer",
      capabilities: ["repository"],
      workstreamId: "workstream-a",
      workBindingId: "implement" as const,
    };
    const legacyPackageIdPolicy = await selectProjectExecutionTarget(
      db([{ ...configured, allowed_worker_type_ids_json: '["codex"]' }]),
      request,
    );
    expect(legacyPackageIdPolicy).toBeNull();

    const productIdPolicy = await selectProjectExecutionTarget(
      db([{ ...configured, allowed_worker_type_ids_json: '["chatgpt"]' }]),
      request,
    );
    expect(productIdPolicy?.workerTypeId).toBe("chatgpt");
  });

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
      worker_type_id: "gemini",
      publisher: "gemini",
      engine_version: "1.0.0",
      profile_definition_id: "gemini-antigravity",
      profile_release_version: 3,
      capabilities_json: JSON.stringify(["code", "shell"]),
      local_permissions_json: JSON.stringify([
        "repository:read",
        "repository:write",
      ]),
      local_worker_activation_state: "enabled",
      local_worker_readiness_state: "ready",
      cloud_scheduling_state: "enabled",
      credential_status: "ready",
      provider: "gemini",
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
      workerTypeId: "gemini",
      effectivePermissions: ["repository:read"],
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
      engine_version: "1.0.0",
      profile_definition_id: "chatgpt-codex",
      profile_release_version: 3,
      capabilities_json: JSON.stringify(["code"]),
      local_permissions_json: JSON.stringify(["repository:read"]),
      local_worker_activation_state: "enabled",
      local_worker_readiness_state: "ready",
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

  it("keeps Workspace local permission details outside Cloud scheduling", async () => {
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
      worker_type_id: "chatgpt",
      publisher: "chatgpt",
      engine_version: "1.0.0",
      profile_definition_id: "chatgpt-codex",
      profile_release_version: 3,
      capabilities_json: JSON.stringify(["code"]),
      // Local worker manifest / local permissions ONLY permit repository:read
      local_permissions_json: JSON.stringify(["repository:read"]),
      local_worker_activation_state: "enabled",
      local_worker_readiness_state: "ready",
      cloud_scheduling_state: "enabled",
      credential_status: "ready",
      provider: "chatgpt",
      local_concurrency_limit: 1,
      active_assignments: 0,
    };

    // Local permissions are checked by the Workspace and are not part of Cloud inventory.
    const target = await selectProjectExecutionTarget(db([v7Worker], "owner"), {
      projectId: "project-v7",
      requesterUserId: "user-developer",
      role: "owner",
      capabilities: ["code"],
    });

    expect(target).not.toBeNull();
    expect(target?.effectivePermissions).toEqual([
      "repository:read",
      "network:use",
    ]);
  });

  it("requires independent Cloud enablement and local readiness for V7 scheduling", async () => {
    const base = {
      ...candidate(),
      workspace_id: "workspace-v7",
      worker_id: "worker-v7",
      worker_type_id: "chatgpt",
      capabilities_json: '["repository"]',
      local_permissions_json: '["repository:read"]',
      credential_status: "ready",
      local_worker_activation_state: "enabled",
      local_worker_readiness_state: "ready",
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
            local_worker_activation_state: "disabled",
            local_worker_readiness_state: "ready",
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
            local_worker_activation_state: "enabled",
            local_worker_readiness_state: "setup_required",
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
          {
            ...base,
            cloud_scheduling_state: "enabled",
            profile_release_version: null,
          },
        ]),
        request,
      ),
    ).resolves.toBeNull();
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

  it("uses live Workspace Gateway state instead of the persisted online projection", async () => {
    const offlineProjection = {
      ...candidate(),
      workspace_id: "workspace-live",
      runtime_identity_id: "runtime-live",
      workspace_status: "offline",
      cloud_scheduling_state: "enabled",
      local_worker_activation_state: "enabled",
      local_worker_readiness_state: "ready",
      credential_status: "ready",
      active_assignments: 0,
    };
    const request = {
      projectId: "project-a",
      requesterUserId: "user-requester",
      role: "implementer",
      capabilities: ["repository"],
    };
    const liveCheck = vi.fn(async () => true);
    const target = await selectProjectExecutionTarget(
      db([offlineProjection]),
      request,
      new Date(),
      liveCheck,
    );

    expect(target?.workspaceId).toBe("workspace-live");
    expect(liveCheck).toHaveBeenCalledWith("workspace-live", "runtime-live");
    await expect(
      selectProjectExecutionTarget(
        db([{ ...offlineProjection, workspace_status: "online" }]),
        request,
        new Date(),
        async () => false,
      ),
    ).resolves.toBeNull();
  });

  it("selects V7 inventory without reading V6 Worker bindings", async () => {
    const v7Row = {
      ...candidate(),
      worker_id: "workspace-worker",
      worker_type_id: "chatgpt",
      local_worker_activation_state: "enabled",
      local_worker_readiness_state: "ready",
      cloud_scheduling_state: "enabled",
      local_concurrency_limit: 1,
      local_permissions_json: '["repository:read"]',
      provider: "chatgpt",
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
