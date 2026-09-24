import { describe, expect, it } from "vitest";
import {
  handleCreateProject,
  handleCreateWorkstream,
  handleStudioSnapshot,
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
});
