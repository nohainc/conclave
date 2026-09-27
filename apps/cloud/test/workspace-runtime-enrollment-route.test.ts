import { describe, expect, it, vi } from "vitest";
import { routeHandlers } from "../src/index.js";
import {
  routeWorkerRequest,
  type WorkerRouteDependencies,
} from "../src/routes/router.js";

function dependencies(
  requireSameOriginForCookieMutation: (request: Request) => void,
): WorkerRouteDependencies {
  return {
    json: (data: unknown, init?: ResponseInit) => Response.json(data, init),
    requireSameOriginForCookieMutation,
    testAuthenticationEnabled: () => false,
    runProjectId: async () => undefined,
    authorizeRequest: async () => undefined,
    resolveWorkflowInstanceId: async () => "workflow-test",
    errorMessage: (error: unknown) => String(error),
    HttpError: Error,
  } as unknown as WorkerRouteDependencies;
}

describe("Workspace desktop enrollment route", () => {
  it("registers the production claim and unpair handlers", () => {
    expect(typeof routeHandlers.handleRedeemWorkspaceEnrollment).toBe(
      "function",
    );
    expect(typeof routeHandlers.handleUnpairWorkspaceRuntime).toBe("function");
  });

  it("redeems a one-time Workspace code without cookie same-origin auth", async () => {
    const sameOrigin = vi.fn();
    const redeem = vi.fn(async () =>
      Response.json({ workspaceRuntimeId: "runtime-1" }, { status: 201 }),
    );

    const response = await routeWorkerRequest(
      new Request("https://app.conclaveax.com/api/workspace-runtime/enroll", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ token: "one-time-code" }),
      }),
      {} as Env,
      undefined,
      { handleRedeemWorkspaceEnrollment: redeem },
      dependencies(sameOrigin),
    );

    expect(response.status).toBe(201);
    expect(redeem).toHaveBeenCalledOnce();
    expect(sameOrigin).not.toHaveBeenCalled();
  });

  it("revokes a paired runtime using bearer auth without cookie CSRF", async () => {
    const sameOrigin = vi.fn();
    const unpair = vi.fn(async () =>
      Response.json({ unpaired: true }, { status: 200 }),
    );

    const response = await routeWorkerRequest(
      new Request("https://app.conclaveax.com/api/workspace-runtime/unpair", {
        method: "POST",
        headers: { authorization: "Bearer runtime-token" },
      }),
      {} as Env,
      undefined,
      { handleUnpairWorkspaceRuntime: unpair },
      dependencies(sameOrigin),
    );

    expect(response.status).toBe(200);
    expect(unpair).toHaveBeenCalledOnce();
    expect(sameOrigin).not.toHaveBeenCalled();
  });

  it("routes ownership checks and release with desktop bearer authentication", async () => {
    const sameOrigin = vi.fn();
    const ownership = vi.fn(async () => Response.json({ ownerUserId: "user-a" }));
    const release = vi.fn(async () => Response.json({ released: true }));
    const checkResponse = await routeWorkerRequest(
      new Request("https://app.conclaveax.com/api/workspace-runtime/ownership", {
        method: "POST",
        headers: { authorization: "Bearer desktop-human-token", "content-type": "application/json" },
        body: "{}",
      }),
      {} as Env,
      undefined,
      { handleCheckWorkspaceOwnership: ownership },
      dependencies(sameOrigin),
    );
    const releaseResponse = await routeWorkerRequest(
      new Request("https://app.conclaveax.com/api/workspace-runtime/release", {
        method: "POST",
        headers: { authorization: "Bearer fresh-desktop-human-token", "content-type": "application/json" },
        body: "{}",
      }),
      {} as Env,
      undefined,
      { handleReleaseDesktopWorkspace: release },
      dependencies(sameOrigin),
    );

    expect(checkResponse.status).toBe(200);
    expect(releaseResponse.status).toBe(200);
    expect(ownership).toHaveBeenCalledOnce();
    expect(release).toHaveBeenCalledOnce();
    expect(sameOrigin).not.toHaveBeenCalled();
  });

  it("routes explicit desktop-human disconnect without cookie CSRF", async () => {
    const sameOrigin = vi.fn();
    const disconnect = vi.fn(async () => Response.json({ disconnected: true }));
    const response = await routeWorkerRequest(
      new Request("https://app.conclaveax.com/api/workspace-runtime/disconnect", {
        method: "POST",
        headers: { authorization: "Bearer desktop-human-token", "content-type": "application/json" },
        body: "{}",
      }),
      {} as Env,
      undefined,
      { handleDisconnectDesktopWorkspace: disconnect },
      dependencies(sameOrigin),
    );
    expect(response.status).toBe(200);
    expect(disconnect).toHaveBeenCalledOnce();
    expect(sameOrigin).not.toHaveBeenCalled();
  });

  it("keeps same-origin enforcement for normal mutation routes", async () => {
    const sameOrigin = vi.fn();
    const createWorkspace = vi.fn(async () =>
      Response.json({ id: "workspace-1" }, { status: 201 }),
    );

    const response = await routeWorkerRequest(
      new Request("https://app.conclaveax.com/api/workspaces", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{}",
      }),
      {} as Env,
      undefined,
      { handleCreateWorkspace: createWorkspace },
      dependencies(sameOrigin),
    );

    expect(response.status).toBe(201);
    expect(createWorkspace).toHaveBeenCalledOnce();
    expect(sameOrigin).toHaveBeenCalledOnce();
  });
});
