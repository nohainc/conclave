import { describe, expect, it, vi } from "vitest";
import { BUILTIN_WORKFLOW_CATALOG } from "@conclave/core";
import {
  routeWorkerRequest,
  type WorkerRouteDependencies,
  type WorkerRouteHandlers,
} from "../src/routes/router.js";

class TestRouteError extends Error {
  constructor(...args: unknown[]) {
    super(String(args[0] ?? ""));
  }
}

const dependencies: WorkerRouteDependencies = {
  json: (data, init) =>
    new Response(JSON.stringify(data), {
      ...init,
      headers: { "content-type": "application/json", ...init?.headers },
    }),
  requireSameOriginForCookieMutation: () => undefined,
  testAuthenticationEnabled: () => false,
  runProjectId: async () => undefined,
  authorizeRequest: async () => undefined,
  resolveWorkflowInstanceId: async () => "workflow",
  errorMessage: (error) => String(error),
  HttpError: TestRouteError,
};

function request(path: string, method = "GET"): Request {
  return new Request(`https://conclave.test${path}`, { method });
}

describe("Worker API routes", () => {
  it("serves the shared core Workflow catalog to AX", async () => {
    const response = await routeWorkerRequest(
      request("/api/workflows/catalog"),
      {} as Parameters<typeof routeWorkerRequest>[1],
      undefined,
      {} as WorkerRouteHandlers,
      dependencies,
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({
      workflows: Object.values(BUILTIN_WORKFLOW_CATALOG),
    });
  });

  it("removes Workspace-scoped Architecture v2 Worker endpoints", async () => {
    const handlers = {} as WorkerRouteHandlers;
    for (const [path, method] of [
      ["/api/workspaces/workspace-1/workers", "GET"],
      ["/api/v2/workspaces/workspace-1/workers", "GET"],
      ["/api/workspaces/workspace-1/workers/codex", "GET"],
      ["/api/v2/workspaces/workspace-1/workers/codex", "PUT"],
    ] as const) {
      const response = await routeWorkerRequest(
        request(path, method),
        {} as Parameters<typeof routeWorkerRequest>[1],
        undefined,
        handlers,
        dependencies,
      );
      expect(response.status, `${method} ${path}`).toBe(404);
    }
  });

  it("keeps V7 inventory and scheduling control routes", async () => {
    const calls: unknown[][] = [];
    const handlers = {
      handleListWorkspaceWorkerInventory: vi.fn(async (...args: unknown[]) => {
        calls.push(args);
        return new Response("inventory", { status: 200 });
      }),
      handleV7WorkerScheduling: vi.fn(async (...args: unknown[]) => {
        calls.push(args);
        return new Response("scheduling", { status: 200 });
      }),
    } as unknown as WorkerRouteHandlers;

    for (const [path, method] of [
      ["/api/v7/workers", "GET"],
      ["/api/v7/workers/worker-1/scheduling", "GET"],
      ["/api/v7/workers/worker-1/scheduling/disable", "POST"],
    ] as const) {
      const response = await routeWorkerRequest(
        request(path, method),
        {} as Parameters<typeof routeWorkerRequest>[1],
        undefined,
        handlers,
        dependencies,
      );
      expect(response.status, `${method} ${path}`).toBe(200);
    }

    expect(handlers.handleListWorkspaceWorkerInventory).toHaveBeenCalledOnce();
    expect(handlers.handleV7WorkerScheduling).toHaveBeenCalledTimes(2);
    expect(calls).toHaveLength(3);
  });

  it("retires native Worker package routes and serves shared release trust", async () => {
    const handlers = {
      handleGetReleaseTrustState: vi.fn(async () => new Response("trust")),
    } as unknown as WorkerRouteHandlers;

    const catalog = await routeWorkerRequest(
      request("/api/worker-releases?platform=linux-arm64"),
      {} as Parameters<typeof routeWorkerRequest>[1],
      undefined,
      handlers,
      dependencies,
    );
    const trust = await routeWorkerRequest(
      request("/api/release-trust"),
      {} as Parameters<typeof routeWorkerRequest>[1],
      undefined,
      handlers,
      dependencies,
    );
    const publish = await routeWorkerRequest(
      request("/api/worker-releases/publish", "POST"),
      {} as Parameters<typeof routeWorkerRequest>[1],
      undefined,
      handlers,
      dependencies,
    );
    const legacyTrust = await routeWorkerRequest(
      request("/api/worker-releases/trust"),
      {} as Parameters<typeof routeWorkerRequest>[1],
      undefined,
      handlers,
      dependencies,
    );
    const legacy = await routeWorkerRequest(
      request("/api/v7/adapters"),
      {} as Parameters<typeof routeWorkerRequest>[1],
      undefined,
      {} as WorkerRouteHandlers,
      dependencies,
    );

    expect(catalog.status).toBe(410);
    expect(publish.status).toBe(410);
    expect(legacyTrust.status).toBe(410);
    expect(trust.status).toBe(200);
    expect(legacy.status).toBe(404);
    expect(handlers.handleGetReleaseTrustState).toHaveBeenCalledOnce();
  });

  it("routes v8 Tool Profile resolution and admin lifecycle operations", async () => {
    const handlers = {
      handleResolveToolProfileChannels: vi.fn(
        async () => new Response("resolved"),
      ),
      handleSetWorkspaceToolProfileChannel: vi.fn(
        async () => new Response("channel"),
      ),
      handleCreateToolProfileDefinition: vi.fn(
        async () => new Response("definition"),
      ),
      handleCreateApprovedLogicalWorker: vi.fn(
        async () => new Response("worker"),
      ),
      handleCreateDraftToolProfileRelease: vi.fn(
        async () => new Response("draft"),
      ),
      handlePublishDraftToolProfileRelease: vi.fn(
        async () => new Response("published"),
      ),
      handlePromoteToolProfileRelease: vi.fn(
        async () => new Response("promoted"),
      ),
      handleChangeToolProfileReleaseLifecycle: vi.fn(
        async () => new Response("revoked"),
      ),
      handleListToolProfileReleaseAudit: vi.fn(
        async () => new Response("audit"),
      ),
    } as unknown as WorkerRouteHandlers;
    const routes = [
      [
        "/api/tool-profiles?workerTypeId=chatgpt&workspaceRuntimeId=runtime-1",
        "GET",
      ],
      ["/api/tool-profiles?workspaceRuntimeId=runtime-1", "GET"],
      ["/api/workspaces/workspace-1/tool-profile-channel", "PATCH"],
      ["/api/admin/tool-profiles/definitions", "POST"],
      ["/api/admin/workers/catalog", "POST"],
      ["/api/admin/tool-profiles/chatgpt-codex/releases", "POST"],
      ["/api/admin/tool-profiles/chatgpt-codex/releases/2/publish", "POST"],
      ["/api/admin/tool-profiles/chatgpt-codex/releases/2/promote", "POST"],
      ["/api/admin/tool-profiles/chatgpt-codex/releases/1/revoke", "POST"],
      ["/api/admin/tool-profiles/chatgpt-codex/releases/1/audit", "GET"],
    ] as const;
    for (const [path, method] of routes) {
      const response = await routeWorkerRequest(
        request(path, method),
        {} as Parameters<typeof routeWorkerRequest>[1],
        undefined,
        handlers,
        dependencies,
      );
      expect(response.status, `${method} ${path}`).toBe(200);
    }
    expect(handlers.handleResolveToolProfileChannels).toHaveBeenCalledTimes(2);
    expect(
      handlers.handleSetWorkspaceToolProfileChannel,
    ).toHaveBeenCalledOnce();
    expect(handlers.handleCreateToolProfileDefinition).toHaveBeenCalledOnce();
    expect(handlers.handleCreateApprovedLogicalWorker).toHaveBeenCalledOnce();
    expect(handlers.handleCreateDraftToolProfileRelease).toHaveBeenCalledOnce();
    expect(
      handlers.handlePublishDraftToolProfileRelease,
    ).toHaveBeenCalledOnce();
    expect(handlers.handlePromoteToolProfileRelease).toHaveBeenCalledOnce();
    expect(
      handlers.handleChangeToolProfileReleaseLifecycle,
    ).toHaveBeenCalledWith(
      expect.any(Request),
      expect.anything(),
      "chatgpt-codex",
      "1",
      "revoke",
      undefined,
    );
    expect(handlers.handleListToolProfileReleaseAudit).toHaveBeenCalledOnce();
  });
});
