import { describe, expect, it, vi } from "vitest";
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

  it("routes native Worker catalog and artifact paths by platform", async () => {
    const handlers = {
      handleListWorkerReleases: vi.fn(async () => new Response("catalog")),
      handleDownloadWorkerRelease: vi.fn(async () => new Response("artifact")),
      handleRevokeWorkerRelease: vi.fn(async () => new Response("revoked")),
      handlePublishWorkerRelease: vi.fn(async () => new Response("published")),
    } as unknown as WorkerRouteHandlers;

    const catalog = await routeWorkerRequest(
      request("/api/worker-releases?platform=linux-arm64"),
      {} as Parameters<typeof routeWorkerRequest>[1],
      undefined,
      handlers,
      dependencies,
    );
    const download = await routeWorkerRequest(
      request("/api/worker-releases/chatgpt/1.2.3/linux-arm64/download"),
      {} as Parameters<typeof routeWorkerRequest>[1],
      undefined,
      handlers,
      dependencies,
    );
    const revoke = await routeWorkerRequest(
      request("/api/worker-releases/chatgpt/1.2.3/linux-arm64/revoke", "POST"),
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
    const legacy = await routeWorkerRequest(
      request("/api/v7/adapters"),
      {} as Parameters<typeof routeWorkerRequest>[1],
      undefined,
      {} as WorkerRouteHandlers,
      dependencies,
    );

    expect(catalog.status).toBe(200);
    expect(download.status).toBe(200);
    expect(revoke.status).toBe(200);
    expect(publish.status).toBe(200);
    expect(legacy.status).toBe(404);
    expect(handlers.handleListWorkerReleases).toHaveBeenCalledOnce();
    expect(handlers.handleDownloadWorkerRelease).toHaveBeenCalledWith(
      expect.any(Request),
      expect.anything(),
      "chatgpt",
      "1.2.3",
      "linux-arm64",
      undefined,
    );
    expect(handlers.handleRevokeWorkerRelease).toHaveBeenCalledWith(
      expect.any(Request),
      expect.anything(),
      "chatgpt",
      "1.2.3",
      "linux-arm64",
      undefined,
    );
    expect(handlers.handlePublishWorkerRelease).toHaveBeenCalledOnce();
  });
});
