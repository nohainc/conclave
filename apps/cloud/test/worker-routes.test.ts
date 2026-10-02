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

  it("serves the logical Worker inventory at its current product route", async () => {
    const handler = vi.fn(
      async () => new Response("inventory", { status: 200 }),
    );
    const response = await routeWorkerRequest(
      request("/api/workers?workspaceId=workspace-1"),
      {} as Parameters<typeof routeWorkerRequest>[1],
      undefined,
      {
        handleListWorkspaceWorkerInventory: handler,
      } as unknown as WorkerRouteHandlers,
      dependencies,
    );
    expect(response.status).toBe(200);
    expect(handler).toHaveBeenCalledOnce();
  });

  it("serves Workspace releases only at the versionless release routes", async () => {
    const routes = [
      [
        "GET",
        "/api/workspace-releases/latest",
        "handleGetLatestWorkspaceRelease",
      ],
      [
        "POST",
        "/api/workspace-releases/publish",
        "handlePublishWorkspaceRelease",
      ],
      ["GET", "/api/workspace-releases/1.2.3", "handleGetWorkspaceRelease"],
      [
        "GET",
        "/api/workspace-releases/1.2.3/download",
        "handleDownloadWorkspaceRelease",
      ],
      [
        "POST",
        "/api/workspace-releases/1.2.3/revoke",
        "handleRevokeWorkspaceRelease",
      ],
    ] as const;

    for (const [method, path, handlerName] of routes) {
      const handler = vi.fn(
        async () => new Response("release", { status: 200 }),
      );
      const response = await routeWorkerRequest(
        request(path, method),
        {} as Parameters<typeof routeWorkerRequest>[1],
        undefined,
        { [handlerName]: handler } as unknown as WorkerRouteHandlers,
        dependencies,
      );
      expect(response.status, `${method} ${path}`).toBe(200);
      expect(handler).toHaveBeenCalledOnce();
    }
  });

  it("serves shared release trust", async () => {
    const handlers = {
      handleGetReleaseTrustState: vi.fn(async () => new Response("trust")),
    } as unknown as WorkerRouteHandlers;

    const trust = await routeWorkerRequest(
      request("/api/release-trust"),
      {} as Parameters<typeof routeWorkerRequest>[1],
      undefined,
      handlers,
      dependencies,
    );
    expect(trust.status).toBe(200);
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
