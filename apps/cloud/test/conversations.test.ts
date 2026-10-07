import { readFileSync } from "node:fs";
import { expect, it, vi } from "vitest";
import { CONVERSATION_WORKFLOWS } from "@conclave/core";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import type { SecurityEnv } from "../src/routes/handlers.js";
const { authorize } = vi.hoisted(() => ({
  authorize: vi.fn(async () => ({})),
}));
vi.mock("../src/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeWorkstreamAccess: authorize,
}));
import {
  conversationId,
  conversationSubmissionStatements,
  handleListConversations,
} from "../src/routes/conversations.js";

it("isolates workflow scopes, preserves context revision, and gates Conversation reads", async () => {
  const { sqlite, db } = sqliteD1();
  sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('U','u@test','U','now','now');
    INSERT INTO projects(id,owner_user_id,name,created_at,updated_at) VALUES('P','U','P','now','now');
    INSERT INTO workstreams(id,project_id,name,status,lead_user_id,created_at,updated_at) VALUES('W','P','W','active','U','now','now');`);
  // The ordered feature migration works against an existing v8 schema.
  sqlite.exec(`INSERT INTO work_requests
    (id,workstream_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,snapshot_json,status,created_at,updated_at)
    VALUES ('historical','W','U','stateful','direct',1,'{"name":"Direct"}','{"originalRequest":"Keep history"}','completed','old','old')`);
  sqlite.exec(
    "DROP TABLE conversation_work_requests; DROP TABLE conversations;",
  );
  const rollout = readFileSync(
    new URL(
      "../migrations-v8/0010_conversation_workflows.sql",
      import.meta.url,
    ),
    "utf8",
  );
  sqlite.exec(rollout);
  expect(
    sqlite
      .prepare(
        "SELECT workflow_snapshot_json, snapshot_json FROM work_requests WHERE id = 'historical'",
      )
      .get(),
  ).toEqual({
    workflow_snapshot_json: '{"name":"Direct"}',
    snapshot_json: '{"originalRequest":"Keep history"}',
  });
  expect(
    sqlite
      .prepare("SELECT count(*) AS n FROM conversation_work_requests")
      .get(),
  ).toEqual({ n: 0 });
  const insertRequest = (id: string) =>
    db
      .prepare(
        `INSERT INTO work_requests
    (id,workstream_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,created_at,updated_at)
    VALUES (?1,'W','U','stateful','direct',2,'{}','queued','now','now')`,
      )
      .bind(id);
  await db.batch([
    insertRequest("R1"),
    ...conversationSubmissionStatements(
      db as unknown as D1Database,
      "W",
      CONVERSATION_WORKFLOWS.work!,
      "R1",
      "now",
    ),
  ]);
  const id = conversationId("W", "work");
  expect(conversationId("W", "chat")).not.toBe(id);
  const request = new Request(
    "https://cloud.test/api/workstreams/W/conversations",
  );
  const env = { CONCLAVE_DB: db } as unknown as SecurityEnv;
  const response = await handleListConversations(request, env, "W");
  expect(await response.json()).toEqual({
    conversations: [
      {
        id,
        workstreamId: "W",
        workflowId: "work",
        workflowVersion: 1,
        conversationRevision: 1,
        contextRevision: 1,
        createdAt: "now",
        updatedAt: "now",
      },
    ],
  });
  expect(authorize).toHaveBeenLastCalledWith(
    request,
    env,
    "W",
    "view",
    undefined,
  );
  // Receipt/request failure rolls back both the counter and association.
  await expect(
    db.batch([
      ...conversationSubmissionStatements(
        db as unknown as D1Database,
        "W",
        CONVERSATION_WORKFLOWS.work!,
        "missing-request",
        "later",
      ),
    ]),
  ).rejects.toThrow();
  expect(
    sqlite.prepare("SELECT conversation_revision FROM conversations").get(),
  ).toEqual({ conversation_revision: 1 });
  expect(
    sqlite
      .prepare("SELECT count(*) AS n FROM conversation_work_requests")
      .get(),
  ).toEqual({ n: 1 });
  authorize.mockRejectedValueOnce(new Error("access denied"));
  expect(() =>
    sqlite.exec("UPDATE conversations SET workflow_id = 'chat'"),
  ).toThrow(/immutable/);
  expect(() =>
    sqlite.exec("UPDATE conversations SET conversation_revision = 0"),
  ).toThrow(/cannot decrease/);
  expect(() =>
    sqlite.exec("UPDATE conversations SET context_revision = 2"),
  ).toThrow();
  expect(() =>
    sqlite.exec(
      "UPDATE conversation_work_requests SET conversation_revision = 2",
    ),
  ).toThrow(/immutable/);
  await expect(handleListConversations(request, env, "W")).rejects.toThrow(
    "access denied",
  );
  sqlite.close();
});
