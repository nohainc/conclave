import { expect, it, vi } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { handleCreateSpace } from "../src/routes/spaces.js";
import { identityService } from "../src/auth/identity-service.js";
import { handleWorkflowWorkspace } from "../src/routes/workflow-workspace.js";
import { loadSpaceWorkflowConfigurations } from "../src/routes/space-workflow-configurations.js";
import type { SecurityEnv } from "../src/routes/http-security.js";
it("requires ownership and confirmation, scopes Workspace selection, resets workflows atomically, and preserves independent Spaces", async () => {
  const { sqlite, db } = sqliteD1();
  const identity = vi
    .spyOn(identityService, "resolve")
    .mockImplementation(async (request) => {
      const user = request.headers.get("authorization");
      return user
        ? { userId: user, email: `${user}@test`, name: user, sessionId: user }
        : null;
    });
  try {
    sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('owner','o@test','Owner','now','now'),('member','m@test','Member','now','now');
 INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES('a','owner','First','now','now'),('b','owner','Second','now','now'),('foreign','member','Foreign','now','now');
 INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('s','owner','Space','now','now'),('independent','owner','Independent','now','now');
 INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('o','s','owner','owner','now','now'),('m','s','member','collaborator','now','now');`);
    const env = { CONCLAVE_DB: db, BETTER_AUTH_SECRET: "test" } as SecurityEnv;
    const handle = (body?: object, spaceId?: string, user = "owner") =>
      handleWorkflowWorkspace(
        new Request("https://test/api/user/workflow-workspace", {
          method: body ? "PUT" : "GET",
          headers: { authorization: user },
          ...(body ? { body: JSON.stringify(body) } : {}),
        }),
        env,
        spaceId,
      );
    await expect(handle({ workspaceId: "a" })).rejects.toMatchObject({
      status: 409,
    });
    await expect(
      handle({ workspaceId: "foreign", confirmReset: true }),
    ).rejects.toMatchObject({ status: 403 });
    await handle({ workspaceId: "a", confirmReset: true });
    expect(
      sqlite
        .prepare(
          "SELECT workspace_id FROM workspace_space_grants WHERE space_id='s'",
        )
        .get(),
    ).toEqual({ workspace_id: "a" });
    await expect(
      handle({ workspaceId: "a", confirmReset: true }, undefined, "member"),
    ).rejects.toMatchObject({ status: 403 });
    const created = await handleCreateSpace(
      new Request("https://test/api/spaces", {
        method: "POST",
        headers: { authorization: "owner" },
        body: JSON.stringify({ name: "New Space" }),
      }),
      env,
    );
    expect(created.status).toBe(201);
    const createdSpace = (await created.json()) as { space: { id: string } };
    expect(
      sqlite
        .prepare(
          "SELECT workspace_id FROM workspace_space_grants WHERE space_id=?",
        )
        .get(createdSpace.space.id),
    ).toEqual({ workspace_id: "a" });
    const config = JSON.stringify({
      schemaVersion: 1,
      workflowId: "chat",
      enabled: false,
      defaults: { worker: "first", model: "first-model", effort: "high" },
      stepOverrides: { chat: { effort: "high" } },
    });
    sqlite
      .prepare(
        "INSERT INTO user_workflow_configurations VALUES('owner','chat',1,?,'now')",
      )
      .run(config);
    expect(
      (await loadSpaceWorkflowConfigurations(env, "s")).configurations[0]
        .enabled,
    ).toBe(false);
    await expect(
      handle({ workspaceId: "b", confirmReset: true }, "s", "member"),
    ).rejects.toMatchObject({ status: 403 });
    await handle({ workspaceId: "b", confirmReset: true }, "s");
    expect(await (await handle(undefined, "s", "member")).json()).toMatchObject(
      {
        workspaceId: "b",
        inherited: false,
        workspaces: [{ id: "b", name: "Second" }],
      },
    );
    expect(
      (await loadSpaceWorkflowConfigurations(env, "s")).configurations,
    ).toEqual([]);
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS n FROM user_workflow_configurations")
        .get(),
    ).toEqual({ n: 1 });
    expect(
      sqlite
        .prepare(
          "SELECT workspace_id,status FROM workspace_space_grants WHERE space_id='s' AND workspace_id='b'",
        )
        .get(),
    ).toEqual({ workspace_id: "b", status: "active" });
    sqlite.exec(
      "INSERT INTO space_workflow_settings VALUES('independent','b','now')",
    );
    sqlite
      .prepare(
        "INSERT INTO space_workflow_configurations VALUES('independent','chat',1,?,'now')",
      )
      .run(config);
    await handle({ workspaceId: "b", confirmReset: true });
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS n FROM user_workflow_configurations")
        .get(),
    ).toEqual({ n: 0 });
    expect(
      sqlite
        .prepare(
          "SELECT COUNT(*) AS n FROM space_workflow_configurations WHERE space_id='independent'",
        )
        .get(),
    ).toEqual({ n: 1 });
    sqlite.exec(
      "UPDATE workspace_space_grants SET status='suspended' WHERE space_id='s' AND workspace_id='a'",
    );
    await expect(
      handle({ workspaceId: "a", confirmReset: true }, "s"),
    ).rejects.toMatchObject({ status: 409 });
    expect((await loadSpaceWorkflowConfigurations(env, "s")).workspaceId).toBe(
      "b",
    );
    await handle({ inherit: true, confirmReset: true }, "s");
    expect(await (await handle(undefined, "s")).json()).toMatchObject({
      workspaceId: "b",
      inherited: true,
    });
  } finally {
    identity.mockRestore();
    sqlite.close();
  }
});
