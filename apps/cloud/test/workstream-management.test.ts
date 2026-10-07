import { expect, it } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import {
  handleCreateWorkstream,
  handleUpdateWorkstream,
  handleDeleteWorkstream,
  handleListProjectWorkstreams,
  handleUpdateProject,
  type SecurityEnv,
} from "../src/routes/handlers.js";

it("owners manage all Workstreams while collaborators manage only their assigned Workstreams", async () => {
  const { sqlite, db } = sqliteD1();
  const roles = {
    owner: "owner",
    lead: "collaborator",
    other: "collaborator",
    viewer: "viewer",
  };
  for (const id of Object.keys(roles)) {
    sqlite
      .prepare(
        "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES(?,?,?,'now','now')",
      )
      .run(id, `${id}@test`, id);
  }
  sqlite.exec(
    "INSERT INTO projects(id,owner_user_id,name,created_at,updated_at) VALUES('P','owner','Project','now','now')",
  );
  for (const [id, role] of Object.entries(roles))
    sqlite
      .prepare(
        "INSERT INTO project_memberships(id,project_id,user_id,role,created_at,updated_at) VALUES(?,'P',?,?,'now','now')",
      )
      .run(`m-${id}`, id, role);
  const env = {
    CONCLAVE_ENVIRONMENT: "development",
    CONCLAVE_DB: db,
    TEST_AUTHENTICATION: async (request: Request) => {
      const userId = request.headers.get("test-user")!;
      return {
        userId,
        user: {
          id: userId,
          email: `${userId}@test`,
          displayName: userId,
          status: "active",
        },
        workspaceId: "",
        projectRoles: { P: roles[userId as keyof typeof roles] },
        sessionId: "test",
        clientType: "web",
      };
    },
  } as unknown as SecurityEnv;
  const request = (user: string, body: unknown = {}, method = "PATCH") =>
    new Request("https://test/api", {
      method,
      headers: { "test-user": user },
      body: JSON.stringify(body),
    });
  try {
    const created = await handleCreateWorkstream(
      request("lead", { name: "Lead's stream" }, "POST"),
      env,
      "P",
    );
    const { workstream } = (await created.json()) as {
      workstream: { id: string; canConfigureWork: boolean };
    };
    expect(workstream.canConfigureWork).toBe(true);
    expect(
      sqlite
        .prepare("SELECT lead_user_id FROM workstreams WHERE id=?")
        .get(workstream.id),
    ).toEqual({ lead_user_id: "lead" });
    for (const user of ["other", "viewer"]) {
      await expect(
        handleUpdateWorkstream(
          request(user, { name: "Forbidden" }),
          env,
          workstream.id,
        ),
      ).rejects.toMatchObject({ status: 403 });
      await expect(
        handleUpdateWorkstream(
          request(user, { status: "archived" }),
          env,
          workstream.id,
        ),
      ).rejects.toMatchObject({ status: 403 });
      await expect(
        handleDeleteWorkstream(request(user, {}, "DELETE"), env, workstream.id),
      ).rejects.toMatchObject({ status: 403 });
    }
    await handleUpdateWorkstream(
      request("lead", { name: "Renamed", status: "archived" }),
      env,
      workstream.id,
    );
    await handleUpdateWorkstream(
      request("owner", { status: "active" }),
      env,
      workstream.id,
    );
    const list = await handleListProjectWorkstreams(
      new Request("https://test/api", { headers: { "test-user": "other" } }),
      env,
      "P",
    );
    expect(await list.json()).toMatchObject({
      workstreams: [{ canConfigureWork: false }],
    });
    await expect(
      handleCreateWorkstream(
        request("viewer", { name: "Forbidden" }, "POST"),
        env,
        "P",
      ),
    ).rejects.toMatchObject({ status: 403 });
    await expect(
      handleUpdateProject(
        request("other", { settings: { workstreamOrder: [workstream.id] } }),
        env,
        "P",
      ),
    ).rejects.toMatchObject({ status: 403 });
    await handleUpdateProject(
      request("owner", { settings: { workstreamOrder: [workstream.id] } }),
      env,
      "P",
    );
    await handleDeleteWorkstream(
      request("lead", {}, "DELETE"),
      env,
      workstream.id,
    );
    const second = await handleCreateWorkstream(
      request("other", { name: "Other's stream" }, "POST"),
      env,
      "P",
    );
    const result = (await second.json()) as { workstream: { id: string } };
    await handleDeleteWorkstream(
      request("owner", {}, "DELETE"),
      env,
      result.workstream.id,
    );
  } finally {
    sqlite.close();
  }
});
