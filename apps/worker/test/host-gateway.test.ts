import { describe, expect, it } from "vitest";
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  assignmentContextMatches,
  isCurrentSocketSession,
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
