import { describe, expect, it } from "vitest";
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  assignmentContextMatches,
  isHostAuthorizationActive,
  isCurrentSocketSession,
  isWorkspaceAuthorized,
} from "../src/host-gateway.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const migrationPath = path.resolve(
  __dirname,
  "../migrations-v4/0001_conclave_v4.sql",
);

function createDb() {
  const db = new DatabaseSync(":memory:");
  db.exec("PRAGMA foreign_keys = ON;");
  db.exec(fs.readFileSync(migrationPath, "utf8"));
  return db;
}

function seedWorkspace(db: DatabaseSync, id: string, userId: string) {
  db.prepare(
    "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, 'now', 'now')",
  ).run(userId, `${userId}@example.com`, userId);
  db.prepare(
    "INSERT INTO workspaces (id, name, slug, created_at, updated_at) VALUES (?, ?, ?, 'now', 'now')",
  ).run(id, id, id);
  db.prepare(
    "INSERT INTO workspace_memberships (id, workspace_id, user_id, role, created_at, updated_at) VALUES (?, ?, ?, 'owner', 'now', 'now')",
  ).run(`${id}-membership`, id, userId);
}

describe("V4 Host connectivity", () => {
  it("keeps one physical Host session authorized for multiple Workspaces", () => {
    const bindings = new Set(["workspace-a", "workspace-b"]);
    expect(isWorkspaceAuthorized(bindings, "workspace-a")).toBe(true);
    expect(isWorkspaceAuthorized(bindings, "workspace-b")).toBe(true);
    expect(isWorkspaceAuthorized(bindings, "workspace-c")).toBe(false);
  });

  it("supports one Host bound to two Workspaces with tenant-scoped lookup", () => {
    const db = createDb();
    seedWorkspace(db, "workspace-a", "user-a");
    seedWorkspace(db, "workspace-b", "user-b");
    db.prepare(
      "INSERT INTO hosts (id, name, hostname, status, version, enrolled_at, created_at, updated_at) VALUES ('host-1', 'Host', 'local', 'enrolled', '4.0.0', 'now', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO host_workspace_bindings (id, host_id, workspace_id, granted_by_user_id, created_at, updated_at) VALUES ('binding-a', 'host-1', 'workspace-a', 'user-a', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO host_workspace_bindings (id, host_id, workspace_id, granted_by_user_id, created_at, updated_at) VALUES ('binding-b', 'host-1', 'workspace-b', 'user-b', 'now', 'now')",
    ).run();

    const visibleToA = db
      .prepare(
        "SELECT h.id FROM hosts h JOIN host_workspace_bindings b ON b.host_id = h.id WHERE b.workspace_id = ? AND b.status = 'active'",
      )
      .all("workspace-a") as { id: string }[];
    const visibleToMissingWorkspace = db
      .prepare(
        "SELECT h.id FROM hosts h JOIN host_workspace_bindings b ON b.host_id = h.id WHERE b.workspace_id = ? AND b.status = 'active'",
      )
      .all("workspace-missing") as { id: string }[];

    expect(visibleToA).toEqual([{ id: "host-1" }]);
    expect(visibleToMissingWorkspace).toEqual([]);
  });

  it("removes a user's access immediately without removing the Host binding", () => {
    const db = createDb();
    seedWorkspace(db, "workspace-a", "user-a");
    db.prepare(
      "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES ('user-b', 'user-b@example.com', 'User B', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO workspace_memberships (id, workspace_id, user_id, role, created_at, updated_at) VALUES ('membership-b', 'workspace-a', 'user-b', 'member', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO hosts (id, name, hostname, status, version, enrolled_at, created_at, updated_at) VALUES ('host-1', 'Host', 'local', 'online', '4.0.0', 'now', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO host_workspace_bindings (id, host_id, workspace_id, granted_by_user_id, created_at, updated_at) VALUES ('binding-a', 'host-1', 'workspace-a', 'user-a', 'now', 'now')",
    ).run();

    const accessQuery = `SELECT h.id FROM hosts h
      JOIN host_workspace_bindings b ON b.host_id = h.id AND b.status = 'active'
      JOIN workspace_memberships m ON m.workspace_id = b.workspace_id
        AND m.user_id = ? AND m.status = 'active'
      WHERE h.id = ? AND h.revoked_at IS NULL`;
    const canUseBeforeRemoval = db.prepare(accessQuery).all("user-b", "host-1");
    db.prepare(
      "UPDATE workspace_memberships SET status = 'removed' WHERE user_id = 'user-b' AND workspace_id = 'workspace-a'",
    ).run();
    const canUseAfterRemoval = db.prepare(accessQuery).all("user-b", "host-1");

    expect(canUseBeforeRemoval).toHaveLength(1);
    expect(canUseAfterRemoval).toHaveLength(0);
    expect(
      db.prepare("SELECT status FROM hosts WHERE id = 'host-1'").get(),
    ).toEqual({ status: "online" });
    expect(
      db
        .prepare(
          "SELECT status FROM host_workspace_bindings WHERE id = 'binding-a'",
        )
        .get(),
    ).toEqual({ status: "active" });
  });

  it("revokes a Host credential without deleting its binding history", () => {
    const db = createDb();
    seedWorkspace(db, "workspace-a", "user-a");
    db.prepare(
      "INSERT INTO hosts (id, name, hostname, status, version, enrolled_at, created_at, updated_at) VALUES ('host-1', 'Host', 'local', 'online', '4.0.0', 'now', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO host_workspace_bindings (id, host_id, workspace_id, granted_by_user_id, created_at, updated_at) VALUES ('binding-a', 'host-1', 'workspace-a', 'user-a', 'now', 'now')",
    ).run();
    db.prepare(
      "UPDATE hosts SET status = 'revoked', revoked_at = 'later' WHERE id = 'host-1' AND EXISTS (SELECT 1 FROM host_workspace_bindings WHERE host_id = 'host-1' AND workspace_id = 'workspace-a' AND status = 'active')",
    ).run();

    expect(
      (
        db
          .prepare("SELECT status, revoked_at FROM hosts WHERE id = 'host-1'")
          .get() as { status: string; revoked_at: string }
      ).status,
    ).toBe("revoked");
    expect(
      (
        db
          .prepare(
            "SELECT COUNT(*) AS count FROM host_workspace_bindings WHERE host_id = 'host-1'",
          )
          .get() as { count: number }
      ).count,
    ).toBe(1);
  });

  it("rejects an already-open Host after revocation or binding removal", async () => {
    const db = {
      prepare(query: string) {
        return {
          bind() {
            return {
              first: async () => {
                if (query.includes("FROM hosts")) {
                  return { status: "revoked", revokedAt: "later" };
                }
                return { active: 1 };
              },
            };
          },
        };
      },
    } as never;
    await expect(
      isHostAuthorizationActive(db, "host-1", "workspace-a"),
    ).resolves.toBe(false);
  });

  it("keeps human sessions independent from Host machine credentials", () => {
    const db = createDb();
    seedWorkspace(db, "workspace-a", "user-a");
    db.prepare(
      "INSERT INTO hosts (id, name, hostname, status, version, capabilities_json, auth_token_hash, enrolled_at, created_at, updated_at) VALUES ('host-1', 'Host', 'local', 'online', '4.0.0', '{}', 'machine-hash', 'now', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO auth_sessions (id, user_id, token, expires_at, created_at, updated_at) VALUES ('session-1', 'user-a', 'human-session', 'later', 'now', 'now')",
    ).run();

    db.prepare("DELETE FROM auth_sessions WHERE id = 'session-1'").run();

    expect(
      db
        .prepare(
          "SELECT auth_token_hash, status FROM hosts WHERE id = 'host-1'",
        )
        .get(),
    ).toEqual({ auth_token_hash: "machine-hash", status: "online" });
  });

  it("enrollment predicates enforce one-time expiry and revocation", () => {
    const db = createDb();
    seedWorkspace(db, "workspace-a", "user-a");
    const query = `SELECT id FROM host_enrollments
      WHERE token_hash = ? AND revoked_at IS NULL AND used_at IS NULL AND expires_at > ?`;
    db.prepare(
      "INSERT INTO host_enrollments (id, workspace_id, token_hash, created_by_user_id, expires_at, created_at) VALUES ('enrollment-1', 'workspace-a', 'hash-1', 'user-a', '2026-09-23T13:00:00.000Z', '2026-09-23T12:00:00.000Z')",
    ).run();

    expect(
      db.prepare(query).all("hash-1", "2026-09-23T12:30:00.000Z"),
    ).toHaveLength(1);
    db.prepare(
      "UPDATE host_enrollments SET used_at = 'later' WHERE id = 'enrollment-1'",
    ).run();
    expect(
      db.prepare(query).all("hash-1", "2026-09-23T12:30:00.000Z"),
    ).toHaveLength(0);
    db.prepare(
      "UPDATE host_enrollments SET used_at = NULL, revoked_at = 'later' WHERE id = 'enrollment-1'",
    ).run();
    expect(
      db.prepare(query).all("hash-1", "2026-09-23T12:30:00.000Z"),
    ).toHaveLength(0);
    db.prepare(
      "UPDATE host_enrollments SET revoked_at = NULL, expires_at = '2026-09-23T12:30:00.000Z' WHERE id = 'enrollment-1'",
    ).run();
    expect(
      db.prepare(query).all("hash-1", "2026-09-23T12:30:00.000Z"),
    ).toHaveLength(0);
  });

  it("treats reconnect as a new live session and ignores stale socket close", () => {
    const currentSocket = {} as WebSocket;
    const staleSocket = {} as WebSocket;
    expect(
      isCurrentSocketSession(currentSocket, "new", currentSocket, "new"),
    ).toBe(true);
    expect(
      isCurrentSocketSession(currentSocket, "new", staleSocket, "old"),
    ).toBe(false);
  });

  it("requires Host-scoped assignment correlation", () => {
    const row = {
      id: "assignment-1",
      workspace_id: "workspace-a",
      host_id: "host-1",
      worker_id: "worker-1",
      run_id: "run-1",
      task_id: "task-1",
      attempt_id: "attempt-1",
      idempotency_key: "idem-1",
    };
    expect(
      assignmentContextMatches(
        {
          workspaceId: "workspace-a",
          hostId: "host-1",
          workerId: "worker-1",
          runId: "run-1",
          taskId: "task-1",
          attemptId: "attempt-1",
          assignmentId: "assignment-1",
          idempotencyKey: "idem-1",
        },
        row,
      ),
    ).toBe(true);
    expect(
      assignmentContextMatches(
        {
          workspaceId: "workspace-b",
          hostId: "host-1",
          workerId: "worker-1",
          runId: "run-1",
          taskId: "task-1",
          attemptId: "attempt-1",
          assignmentId: "assignment-1",
          idempotencyKey: "idem-1",
        },
        row,
      ),
    ).toBe(false);
  });
});
