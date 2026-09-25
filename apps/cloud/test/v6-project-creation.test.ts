import { describe, expect, it } from "vitest";
import {
  handleCreateProject,
  handleCreateWorkstream,
  handleGetProject,
  handleStudioSnapshot,
  handleUpdateProject,
} from "../src/routes/handlers.js";

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

  it("serves the compatibility snapshot from v6 Project membership", async () => {
    const db = {
      prepare() {
        return {
          bind() {
            return this;
          },
          async all() {
            return {
              results: [
                {
                  id: "project-1",
                  name: "Project without Workspace",
                  description: null,
                  repository: null,
                  lastActivity: "2026-09-24T00:00:00Z",
                },
              ],
            };
          },
        };
      },
    };
    const response = await handleStudioSnapshot(
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
          authorizedProjectIds: ["project-1"],
          projectRoles: { "project-1": "owner" },
          sessionId: "session-1",
          clientType: "web",
          organizationId: "",
          organizationRoles: ["viewer"],
          authorizationModel: "v5",
          ownedWorkspaceIds: [],
          ownedAccountIds: [],
        }),
      } as never,
      new Request("https://conclave.test/api/studio/snapshot"),
      null,
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      workspaceId: null,
      projects: [{ id: "project-1", name: "Project without Workspace" }],
      workers: [],
      hosts: [],
    });
  });

  it("serves all user projects when projectId is provided in snapshot query", async () => {
    const bindArgs: unknown[][] = [];
    const db = {
      prepare() {
        return {
          bind(...args: unknown[]) {
            bindArgs.push(args);
            return this;
          },
          async all() {
            return {
              results: [
                {
                  id: "project-1",
                  name: "Project 1",
                  description: null,
                  repository: null,
                  lastActivity: "2026-09-24T00:00:00Z",
                },
                {
                  id: "project-2",
                  name: "Project 2",
                  description: null,
                  repository: null,
                  lastActivity: "2026-09-24T00:00:00Z",
                },
              ],
            };
          },
        };
      },
    };
    const response = await handleStudioSnapshot(
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
          authorizedProjectIds: ["project-1", "project-2"],
          projectRoles: { "project-1": "owner", "project-2": "owner" },
          sessionId: "session-1",
          clientType: "web",
          organizationId: "",
          organizationRoles: ["viewer"],
          authorizationModel: "v5",
          ownedWorkspaceIds: [],
          ownedAccountIds: [],
        }),
      } as never,
      new Request("https://conclave.test/api/studio/snapshot?projectId=project-1"),
      "project-1",
    );

    expect(response.status).toBe(200);
    const body = (await response.json()) as { projects: { id: string }[] };
    expect(body.projects.length).toBe(2);
    expect(bindArgs[0]).toEqual(["user-1"]);
  });

  it("creates a persisted Workstream with a lead membership", async () => {
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
    const response = await handleCreateWorkstream(
      new Request("https://conclave.test/api/projects/project-1/workstreams", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: "Authentication work" }),
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
          authorizedProjectIds: ["project-1"],
          projectRoles: { "project-1": "owner" },
          sessionId: "session-1",
          clientType: "web",
          organizationId: "",
          organizationRoles: ["viewer"],
          authorizationModel: "v5",
          ownedWorkspaceIds: [],
          ownedAccountIds: [],
        }),
      } as never,
      "project-1",
    );

    expect(response.status).toBe(201);
    expect(await response.json()).toMatchObject({
      workstream: {
        projectId: "project-1",
        name: "Authentication work",
        status: "active",
        lead: "user-1",
      },
    });
    expect(prepared).toContainEqual(expect.stringContaining("INSERT INTO workstreams"));
    expect(prepared).toContainEqual(expect.stringContaining("INSERT INTO workstream_memberships"));
    expect(batchSize).toBe(2);
  });

  it("gets and updates a v6 project with custom settings", async () => {
    let updatedQuery = "";
    let updatedBindings: unknown[] = [];
    const db = {
      prepare(query: string) {
        if (query.includes("SELECT") && query.includes("FROM projects")) {
          return {
            bind() {
              return this;
            },
            async first() {
              return {
                id: "project-1",
                name: "Original Name",
                description: "Original Desc",
                repositoryId: null,
                settingsJson: JSON.stringify({ workstreamOrder: ["ws-1", "ws-2"] }),
                createdAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:00:00Z",
              };
            },
          };
        }
        if (query.includes("UPDATE projects")) {
          return {
            bind(...args: unknown[]) {
              updatedQuery = query;
              updatedBindings = args;
              return this;
            },
            async run() {
              return { success: true, meta: { changes: 1 } };
            },
          };
        }
        if (query.includes("project_memberships")) {
          return {
            bind() {
              return this;
            },
            async first() {
              return { role: "owner" };
            },
          };
        }
        return {
          bind() {
            return this;
          },
        };
      },
    };

    const auth = async () => ({
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
      authorizedProjectIds: ["project-1"],
      projectRoles: { "project-1": "owner" },
      sessionId: "session-1",
      clientType: "web",
      organizationId: "",
      organizationRoles: ["viewer"],
      authorizationModel: "v5" as const,
      ownedWorkspaceIds: [],
      ownedAccountIds: [],
    });

    const getRes = await handleGetProject(
      new Request("https://conclave.test/api/projects/project-1"),
      { CONCLAVE_ENVIRONMENT: "development", CONCLAVE_DB: db, TEST_AUTHENTICATION: auth } as never,
      "project-1",
    );
    expect(getRes.status).toBe(200);
    const getBody = (await getRes.json()) as { project: { name: string; settings: { workstreamOrder: string[] } } };
    expect(getBody.project.name).toBe("Original Name");
    expect(getBody.project.settings.workstreamOrder).toEqual(["ws-1", "ws-2"]);

    const updateRes = await handleUpdateProject(
      new Request("https://conclave.test/api/projects/project-1", {
        method: "PATCH",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          name: "Updated Name",
          settings: { workstreamOrder: ["ws-2", "ws-1"] },
        }),
      }),
      { CONCLAVE_ENVIRONMENT: "development", CONCLAVE_DB: db, TEST_AUTHENTICATION: auth } as never,
      "project-1",
    );
    expect(updateRes.status).toBe(200);
    const updateBody = (await updateRes.json()) as { project: { name: string; settings: { workstreamOrder: string[] } } };
    expect(updateBody.project.name).toBe("Updated Name");
    expect(updateBody.project.settings.workstreamOrder).toEqual(["ws-2", "ws-1"]);
    expect(updatedQuery).toContain("UPDATE projects SET name = ?1");
    expect(updatedBindings[0]).toBe("Updated Name");
  });
});

