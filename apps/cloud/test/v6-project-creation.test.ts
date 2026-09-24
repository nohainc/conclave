import { describe, expect, it } from "vitest";
import { handleCreateProject } from "../src/routes/handlers.js";

describe("v6 Project creation", () => {
  it("creates a Project without requiring an execution Workspace", async () => {
    const prepared: string[] = [];
    let batchSize = 0;
    const db = {
      prepare(query: string) {
        prepared.push(query);
        return {
          bind() {
            return this;
          },
        };
      },
      async batch(statements: readonly unknown[]) {
        batchSize = statements.length;
        return [];
      },
    };

    const response = await handleCreateProject(
      new Request("https://conclave.test/api/projects", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: "Unattached Project" }),
      }),
      {
        CONCLAVE_ENVIRONMENT: "development",
        CONCLAVE_DB: db,
        TEST_AUTHENTICATION: async () => ({
          userId: "user-1",
          user: {
            id: "user-1",
            email: "owner@example.test",
            displayName: "Owner",
            status: "active",
          },
          workspaceId: "",
          workspaceRole: "viewer",
          roles: ["viewer"],
          authorizedProjectIds: [],
          projectRoles: {},
          sessionId: "session-1",
          clientType: "web",
          organizationId: "",
          organizationRoles: ["viewer"],
          authorizationModel: "v5",
          ownedWorkspaceIds: [],
          ownedAccountIds: [],
        }),
      } as never,
    );

    expect(response.status).toBe(201);
    expect(await response.json()).toMatchObject({
      project: { name: "Unattached Project" },
    });
    expect(prepared).toContainEqual(
      expect.stringContaining("INSERT INTO projects (id, owner_user_id"),
    );
    expect(prepared).toContainEqual(
      expect.stringContaining("INSERT INTO project_memberships"),
    );
    expect(batchSize).toBe(2);
  });
});
