import { describe, expect, it, vi } from "vitest";
import {
  handleListWorkspaceWorkerCatalog,
  handleListWorkspaceWorkerInventory,
  handleListWorkerCatalog,
} from "../src/routes/profiles.js";

describe("Workspace Worker inventory catalog metadata", () => {
  it("returns Cloud metadata separately from local readiness", async () => {
    const row = {
      worker_id: "workspace-worker-dynamic",
      workspace_id: "workspace-1",
      workspace_name: "Vitalii’s MacBook Pro",
      worker_type_id: "dynamic-test-worker",
      activation_state: "enabled",
      readiness_state: "setup_required",
      readiness_issue_code: "provider_tool_missing",
      capabilities_json: '["text"]',
      local_concurrency_limit: 1,
      engine_version: null,
      profile_definition_id: null,
      profile_release_version: null,
      provider_tool_name: null,
      provider_tool_version: null,
      last_seen_at: "2026-10-02T00:00:00.000Z",
      catalog_display_name: "Dynamic Test Worker",
      catalog_description: "Catalog-created acceptance Worker.",
      catalog_lifecycle_state: "active",
      catalog_visibility_state: "visible",
    };
    const statement = {
      bind: vi.fn(function (this: unknown) {
        return this;
      }),
      all: vi.fn(async () => ({ results: [row] })),
    };
    const env = {
      CONCLAVE_ENVIRONMENT: "development",
      CONCLAVE_DB: { prepare: vi.fn(() => statement) },
      TEST_AUTHENTICATION: async () => ({ userId: "user-1" }),
    } as unknown as Env;

    const response = await handleListWorkspaceWorkerInventory(
      new Request("https://conclave.test/api/workers"),
      env,
    );
    const body = (await response.json()) as {
      workers: Array<{
        status?: string;
        readinessState: string;
        workspaceName: string;
        displayName: string;
        description: string;
        catalogLifecycleState: string;
        catalogVisibilityState: string;
      }>;
    };

    expect(response.status).toBe(200);
    expect(body.workers[0]).toMatchObject({
      workerTypeId: "dynamic-test-worker",
      workspaceName: "Vitalii’s MacBook Pro",
      displayName: "Dynamic Test Worker",
      description: "Catalog-created acceptance Worker.",
      readinessState: "setup_required",
      catalogLifecycleState: "active",
      catalogVisibilityState: "visible",
    });
    expect(body.workers[0]).not.toHaveProperty("descriptor");

    row.catalog_lifecycle_state = "retired";
    const retiredResponse = await handleListWorkspaceWorkerInventory(
      new Request("https://conclave.test/api/workers"),
      env,
    );
    const retiredBody = (await retiredResponse.json()) as {
      workers: Array<{ catalogLifecycleState: string }>;
    };
    expect(retiredBody.workers[0]?.catalogLifecycleState).toBe("retired");
  });

  it("discovers a newly approved Cloud Worker from the selected catalog channel", async () => {
    const queries: string[] = [];
    let catalogBoundChannel: string | undefined;
    const db = {
      prepare: vi.fn((sql: string) => {
        queries.push(sql);
        return {
          bind: vi.fn((...values: unknown[]) => {
            if (sql.includes("FROM worker_catalog worker")) {
              catalogBoundChannel = String(values[0]);
            }
            return {
              first: async () =>
                sql.includes("workspace_runtime_identities")
                  ? { workspaceId: "workspace-1" }
                  : { channel: "beta" },
              all: async () => ({
                results: [
                  {
                    worker_type_id: "dynamic-test-worker",
                    display_name: "Dynamic Test Worker",
                    description: "Catalog-created acceptance Worker.",
                    engine_family: "cli",
                    visibility_state: "visible",
                    release_stage: "beta",
                    capabilities_json: '["text","workstream_read"]',
                    sort_order: 30,
                    profile_definition_id: "dynamic-test-cli",
                    provider_tool_name: "Fixture CLI",
                  },
                ],
              }),
            };
          }),
        };
      }),
    };
    const env = {
      CONCLAVE_DB: db,
    } as unknown as Env;

    const response = await handleListWorkspaceWorkerCatalog(
      new Request(
        "https://conclave.test/api/workspace-runtime/workers/catalog?workspaceRuntimeId=runtime-1",
        {
          headers: { authorization: "Bearer runtime-secret" },
        },
      ),
      env,
    );
    const body = (await response.json()) as {
      channel: string;
      workers: Array<Record<string, unknown>>;
    };

    expect(response.status).toBe(200);
    expect(body.channel).toBe("beta");
    expect(catalogBoundChannel).toBe("beta");
    expect(body.workers).toContainEqual(
      expect.objectContaining({
        workerTypeId: "dynamic-test-worker",
        displayName: "Dynamic Test Worker",
        profileDefinitionId: "dynamic-test-cli",
        providerToolName: "Fixture CLI",
      }),
    );
    const catalogQuery = queries.find((sql) =>
      sql.includes("FROM worker_catalog worker"),
    );
    expect(catalogQuery).toContain("definition.lifecycle_state = 'active'");
    expect(catalogQuery).toContain("worker.visibility_state = 'visible'");
    expect(catalogQuery).toContain("worker.release_stage IN ('beta','stable')");
    expect(body.workers[0]).not.toHaveProperty("profile");
  });

  it("serves the stable Worker catalog through the authenticated human API", async () => {
    const queries: string[] = [];
    let catalogBoundChannel: string | undefined;
    const db = {
      prepare: vi.fn((sql: string) => {
        queries.push(sql);
        return {
          bind: vi.fn((...values: unknown[]) => {
            catalogBoundChannel = String(values[0]);
            return {
              all: async () => ({
                results: [
                  {
                    worker_type_id: "dynamic-test-worker",
                    display_name: "Dynamic Test Worker",
                    description: "Catalog-created acceptance Worker.",
                    engine_family: "cli",
                    visibility_state: "visible",
                    release_stage: "stable",
                    capabilities_json: '["text"]',
                    sort_order: 30,
                    profile_definition_id: "dynamic-test-cli",
                    provider_tool_name: "Fixture CLI",
                  },
                ],
              }),
            };
          }),
        };
      }),
    };
    const env = {
      CONCLAVE_ENVIRONMENT: "development",
      CONCLAVE_DB: db,
      TEST_AUTHENTICATION: async () => ({ userId: "user-1" }),
    } as unknown as Env;

    const response = await handleListWorkerCatalog(
      new Request("https://conclave.test/api/workers/catalog"),
      env,
    );
    const body = (await response.json()) as {
      workers: Array<Record<string, unknown>>;
    };

    expect(response.status).toBe(200);
    expect(catalogBoundChannel).toBe("stable");
    expect(body.workers).toContainEqual(
      expect.objectContaining({
        workerTypeId: "dynamic-test-worker",
        displayName: "Dynamic Test Worker",
        profileDefinitionId: "dynamic-test-cli",
        providerToolName: "Fixture CLI",
      }),
    );
    expect(body.workers[0]).not.toHaveProperty("profile");
    expect(queries[0]).toContain("FROM worker_catalog worker");
  });
});
