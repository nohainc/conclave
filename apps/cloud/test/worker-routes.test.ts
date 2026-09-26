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
});
