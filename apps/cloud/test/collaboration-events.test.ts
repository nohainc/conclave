import { describe, expect, it } from "vitest";
import { pruneExpiredRealtimeEvents } from "../src/realtime-retention.js";
import { CloudEventPublisher } from "../src/event-publisher.js";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { publishCollaborationEvent } from "../src/collaboration-events.js";
import {
  authorizeRealtimeScope,
  eventMatchesScope,
} from "../src/realtime-gateway.js";
import { parseRealtimeEvent } from "@conclave/protocol";
import {
  handleCreateProject,
  handleUpdateProject,
  handleDeleteProject,
  handleCreateWorkstream,
  handleUpdateWorkstream,
  handleDeleteWorkstream,
  handleCreateDiscussionMessage,
  handleEditDiscussionMessage,
  handleGetDiscussionMessage,
  handleCreateWorkspaceProjectGrant,
  handleUpdateWorkspaceProjectGrant,
  handleRevokeWorkspaceProjectGrant,
} from "../src/routes/handlers.js";
import type { SecurityEnv } from "../src/routes/handlers.js";

function fixture() {
  const { sqlite, db } = sqliteD1();
  sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES
    ('owner','owner@test','Owner','now','now'), ('member','member@test','Member','now','now'), ('outsider','outsider@test','Outsider','now','now');`);
  const deliveries: { user: string; event: Record<string, unknown> }[] = [];
  const env = {
    CONCLAVE_ENVIRONMENT: "development",
    CONCLAVE_DB: db,
    CONCLAVE_REALTIME_GATEWAY: {
      getByName(user: string) {
        return {
          async fetch(request: Request) {
            deliveries.push({
              user,
              event: (await request.json()) as Record<string, unknown>,
            });
            return new Response("{}");
          },
        };
      },
    },
    TEST_AUTHENTICATION: async () => ({
      userId: "owner",
      user: {
        id: "owner",
        email: "owner@test",
        displayName: "Owner",
        status: "active",
      },
      workspaceId: "",
      projectRoles: {},
      sessionId: "session",
      clientType: "web",
    }),
  } as unknown as SecurityEnv;
  const request = (body: unknown = {}, method = "POST") =>
    new Request("https://cloud.test/api/resource", {
      method,
      body: JSON.stringify(body),
    });
  const events = () =>
    sqlite
      .prepare("SELECT * FROM realtime_events ORDER BY sequence")
      .all() as Record<string, unknown>[];
  return { sqlite, db, env, deliveries, request, events };
}

describe("collaboration durable signals", () => {
  it("delivers a durable recipient signal without granting Project membership", async () => {
    const f = fixture();
    try {
      const response = await handleCreateProject(
        f.request({ name: "Private project" }),
        f.env,
      );
      const { project } = (await response.json()) as {
        project: { id: string };
      };
      f.deliveries.length = 0;
      await publishCollaborationEvent(
        f.env,
        "project.updated",
        project.id,
        "invitation",
        { additionalRecipientUserIds: ["outsider", "outsider"] },
      );
      const recipient = f.deliveries.filter(
        (item) => item.user === "user:outsider",
      );
      expect(recipient).toHaveLength(1);
      expect(recipient[0]!.event).toMatchObject({
        stream: { kind: "user", id: "outsider" },
        payload: { entityId: "invitation" },
      });
      expect(
        (
          await authorizeRealtimeScope(
            f.db as unknown as D1Database,
            "outsider",
            { kind: "project", projectId: project.id },
          )
        ).allowed,
      ).toBe(false);
      expect(
        (
          await authorizeRealtimeScope(
            f.db as unknown as D1Database,
            "outsider",
            { kind: "user" },
          )
        ).allowed,
      ).toBe(true);
      expect(
        eventMatchesScope(parseRealtimeEvent(recipient[0]!.event), {
          kind: "user",
        }),
      ).toBe(true);
      expect(
        f
          .events()
          .filter(
            (event) =>
              event.stream_kind === "user" && event.stream_id === "outsider",
          ),
      ).toHaveLength(1);
      expect(
        f.sqlite
          .prepare(
            "SELECT count(*) AS n FROM project_memberships WHERE user_id='outsider'",
          )
          .get(),
      ).toEqual({ n: 0 });
    } finally {
      f.sqlite.close();
    }
  });
  it("publishes all collaboration CRUD signals with real authorization and no execution Workspace", async () => {
    const f = fixture();
    try {
      const created = await handleCreateProject(
        f.request({ name: "Project" }),
        f.env,
      );
      const { project } = (await created.json()) as { project: { id: string } };
      const p = project.id;
      f.sqlite
        .prepare(
          "INSERT INTO project_memberships VALUES('member-p', ?, 'member', 'collaborator', 'now', 'now')",
        )
        .run(p);
      await handleUpdateProject(
        f.request({ name: "Renamed" }, "PATCH"),
        f.env,
        p,
      );
      await handleUpdateProject(
        f.request({ archived: true }, "PATCH"),
        f.env,
        p,
      );
      const streamResponse = await handleCreateWorkstream(
        f.request({ name: "Stream" }),
        f.env,
        p,
      );
      const { workstream } = (await streamResponse.json()) as {
        workstream: { id: string };
      };
      const w = workstream.id;
      await handleUpdateWorkstream(
        f.request({ name: "New Stream" }, "PATCH"),
        f.env,
        w,
      );
      const discussionResponse = await handleCreateDiscussionMessage(
        f.request({ body: "Private text never broadcast" }),
        f.env,
        w,
      );
      const { message } = (await discussionResponse.json()) as {
        message: { id: string };
      };
      await handleEditDiscussionMessage(
        f.request({ body: "Edited text" }, "PATCH"),
        f.env,
        message.id,
      );
      const detail = await handleGetDiscussionMessage(
        new Request("https://cloud.test/api/discussion-messages/" + message.id),
        f.env,
        message.id,
      );
      expect(await detail.json()).toMatchObject({
        message: {
          id: message.id,
          body: "Edited text",
          workstreamId: w,
          references: [],
        },
      });
      await handleDeleteWorkstream(f.request({}, "DELETE"), f.env, w);
      await handleDeleteProject(f.request({}, "DELETE"), f.env, p);
      const events = f.events();
      expect(events.map((row) => row.event_type)).toEqual([
        "project.created",
        "project.updated",
        "project.archived",
        "workstream.created",
        "workstream.updated",
        "discussion.created",
        "discussion.updated",
        "workstream.deleted",
        "project.deleted",
      ]);
      expect(events.map((row) => row.sequence)).toEqual([
        1, 2, 3, 4, 5, 6, 7, 8, 9,
      ]);
      for (const row of events) {
        expect(row.stream_kind).toBe("project");
        expect(row.stream_id).toBe(p);
        expect(row.workspace_id).toBeNull();
        expect(Object.keys(JSON.parse(String(row.payload_json)))).toEqual(
          expect.arrayContaining(["entityId"]),
        );
        expect(row.payload_json).not.toContain("text");
      }
      expect(
        f.sqlite
          .prepare("SELECT COUNT(*) AS n FROM execution_workspaces")
          .get()!.n,
      ).toBe(0);
      expect(
        f.deliveries
          .filter((item) => item.event.type === "project.deleted")
          .map((item) => item.user)
          .sort(),
      ).toEqual(["user:member", "user:owner"]);
      expect(f.deliveries.some((item) => item.user === "user:outsider")).toBe(
        false,
      );
      expect(
        f.sqlite.prepare("SELECT COUNT(*) AS n FROM project_memberships").get()!
          .n,
      ).toBe(0);
    } finally {
      f.sqlite.close();
    }
  });
  it("signals grant creation, editing and revocation on the Project stream", async () => {
    const f = fixture();
    try {
      const response = await handleCreateProject(
        f.request({ name: "P" }),
        f.env,
      );
      const { project } = (await response.json()) as {
        project: { id: string };
      };
      f.sqlite.exec(
        "INSERT INTO execution_workspaces VALUES('ws','owner','Workspace','online','now','now')",
      );
      const granted = await handleCreateWorkspaceProjectGrant(
        f.request({ allowedPermissions: ["repository:read"] }),
        f.env,
        "ws",
        project.id,
      );
      const { grant } = (await granted.json()) as { grant: { id: string } };
      await handleUpdateWorkspaceProjectGrant(
        f.request({ status: "suspended" }, "PATCH"),
        f.env,
        grant.id,
      );
      await handleRevokeWorkspaceProjectGrant(
        f.request({}, "DELETE"),
        f.env,
        grant.id,
      );
      const grants = f
        .events()
        .filter(
          (row) =>
            row.event_type === "project_workspace_grant.updated" &&
            row.stream_kind === "project",
        );
      expect(grants).toHaveLength(3);
      expect(
        grants.every(
          (row) =>
            row.stream_kind === "project" &&
            row.workspace_id === null &&
            row.stream_id === project.id,
        ),
      ).toBe(true);
    } finally {
      f.sqlite.close();
    }
  });
  it("isolates same-named execution, Project and user streams and idempotency keys", async () => {
    const f = fixture();
    try {
      const publisher = new CloudEventPublisher({ CONCLAVE_DB: f.db });
      const input = {
        type: "project.updated",
        projectId: "same",
        payload: { entityId: "same" },
        idempotencyKey: "same-key",
      };
      const p = await publisher.publish({
        ...input,
        stream: { kind: "project", id: "same" },
      });
      const u = await publisher.publish({
        ...input,
        stream: { kind: "user", id: "same" },
      });
      const e = await publisher.publish({
        type: "work_request.created",
        workspaceId: "same",
        payload: { entityId: "r" },
        idempotencyKey: "same-key",
      });
      const duplicate = await publisher.publish({
        ...input,
        stream: { kind: "project", id: "same" },
      });
      expect([
        p.event.sequence,
        u.event.sequence,
        e.event.sequence,
        duplicate.event.sequence,
      ]).toEqual([1, 1, 1, 1]);
      expect(duplicate.persisted).toBe(false);
      expect(e.event.version).toBe("1.0");
      expect(e.event.stream).toBeUndefined();
      const next = await publisher.publish({
        ...input,
        idempotencyKey: "next",
        stream: { kind: "project", id: "same" },
      });
      expect(next.event.sequence).toBe(2);
    } finally {
      f.sqlite.close();
    }
  });
  it("retains Project sequence counters after expired events are pruned", async () => {
    const f = fixture();
    try {
      const publisher = new CloudEventPublisher({ CONCLAVE_DB: f.db });
      const input = {
        type: "project.updated",
        projectId: "p",
        stream: { kind: "project", id: "p" } as const,
        payload: { entityId: "p" },
      };
      await publisher.publish({
        ...input,
        occurredAt: "2025-01-01T00:00:00.000Z",
      });
      expect(
        await pruneExpiredRealtimeEvents(
          f.db,
          new Date("2026-10-06T00:00:00.000Z"),
        ),
      ).toBe(1);
      expect((await publisher.publish(input)).event.sequence).toBe(2);
    } finally {
      f.sqlite.close();
    }
  });
  it("denies message reads/edits without Workstream access or authorship and emits no signal", async () => {
    const f = fixture();
    try {
      const { project } = (await (
        await handleCreateProject(f.request({ name: "P" }), f.env)
      ).json()) as { project: { id: string } };
      const { workstream } = (await (
        await handleCreateWorkstream(
          f.request({ name: "W" }),
          f.env,
          project.id,
        )
      ).json()) as { workstream: { id: string } };
      const { message } = (await (
        await handleCreateDiscussionMessage(
          f.request({ body: "Private" }),
          f.env,
          workstream.id,
        )
      ).json()) as { message: { id: string } };
      const count = f.events().length;
      Object.assign(f.env, {
        TEST_AUTHENTICATION: async () => ({ userId: "outsider" }),
      });
      await expect(
        handleGetDiscussionMessage(
          new Request(
            "https://cloud.test/api/discussion-messages/" + message.id,
          ),
          f.env,
          message.id,
        ),
      ).rejects.toMatchObject({ status: 403 });
      f.sqlite
        .prepare(
          "INSERT INTO project_memberships VALUES('member-p',?,'member','collaborator','now','now')",
        )
        .run(project.id);
      Object.assign(f.env, {
        TEST_AUTHENTICATION: async () => ({ userId: "member" }),
      });
      await expect(
        handleEditDiscussionMessage(
          f.request({ body: "Overwrite" }, "PATCH"),
          f.env,
          message.id,
        ),
      ).rejects.toMatchObject({ status: 403 });
      expect(f.events()).toHaveLength(count);
      expect(
        f.sqlite
          .prepare("SELECT body FROM discussion_messages WHERE id = ?")
          .get(message.id)!.body,
      ).toBe("Private");
    } finally {
      f.sqlite.close();
    }
  });
  it("rolls back a domain write and sequence together when event persistence fails", async () => {
    const f = fixture();
    try {
      f.sqlite.exec(
        "CREATE TRIGGER fail_realtime BEFORE INSERT ON realtime_events BEGIN SELECT RAISE(ABORT, 'test failure'); END;",
      );
      await expect(
        handleCreateProject(f.request({ name: "P" }), f.env),
      ).rejects.toThrow("test failure");
      expect(
        f.sqlite.prepare("SELECT COUNT(*) AS n FROM projects").get()!.n,
      ).toBe(0);
      expect(
        f.sqlite
          .prepare("SELECT COUNT(*) AS n FROM realtime_event_cursors")
          .get()!.n,
      ).toBe(0);
      expect(f.deliveries).toHaveLength(0);
    } finally {
      f.sqlite.close();
    }
  });
});
