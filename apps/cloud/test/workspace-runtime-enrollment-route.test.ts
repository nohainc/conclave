import { describe, expect, it, vi } from "vitest";
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
