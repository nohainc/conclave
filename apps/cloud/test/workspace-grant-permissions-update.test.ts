import { describe, expect, it, vi } from "vitest";

const state = vi.hoisted(() => ({ status: "active", owner: true }));
vi.mock("../src/routes/handlers.js", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../src/routes/handlers.js")>()),
  securityContext: async () => ({ userId: "owner-1" }),
  loadWorkspaceProjectGrant: async () => ({
    id: "grant-1",
    workspace_id: "workspace-1",
    status: state.status,
    allowed_permissions_json: "[]",
    expires_at: null,
  }),
  recordAudit: async () => {},
}));
vi.mock("@conclave/security", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@conclave/security")>()),
  authorizeWorkspaceOwner: async () => {
    if (!state.owner)
      throw Object.assign(new Error("Owner required"), { status: 403 });
  },
}));
import { handleUpdateWorkspaceProjectGrant } from "../src/routes/workspaces-grants.js";

describe("Workspace grant access editing", () => {
  async function update(permissions: unknown) {
    const writes: unknown[][] = [];
    const env = {
      CONCLAVE_DB: {
        prepare: () => ({
          bind(...values: unknown[]) {
            writes.push(values);
            return this;
          },
          run: async () => ({ meta: { changes: 1 } }),
        }),
      },
    } as never;
    const result = handleUpdateWorkspaceProjectGrant(
      new Request("https://cloud.test/api/workspace-project-grants/grant-1", {
        method: "PATCH",
        body: JSON.stringify({ allowedPermissions: permissions }),
      }),
      env,
      "grant-1",
    );
    return { result, writes };
  }
  it("stores explicitly confirmed Direct permissions", async () => {
    state.status = "active";
    state.owner = true;
    const { result, writes } = await update([
      "repository:read",
      "repository:write",
    ]);
    expect((await result).status).toBe(200);
    expect(writes[0]?.[5]).toBe('["repository:read","repository:write"]');
  });
  it("rejects invalid permissions without a write", async () => {
    state.status = "active";
    state.owner = true;
    const { result, writes } = await update(["full_access"]);
    await expect(result).rejects.toMatchObject({ status: 400 });
    expect(writes).toEqual([]);
  });
  it("requires Workspace ownership", async () => {
    state.status = "active";
    state.owner = false;
    const { result, writes } = await update(["repository:write"]);
    await expect(result).rejects.toMatchObject({ status: 403 });
    expect(writes).toEqual([]);
    state.owner = true;
  });
  it("cannot widen a revoked grant", async () => {
    state.status = "revoked";
    state.owner = true;
    const { result, writes } = await update([
      "repository:read",
      "repository:write",
    ]);
    await expect(result).rejects.toMatchObject({ status: 409 });
    expect(writes).toEqual([]);
    state.status = "active";
  });
});
