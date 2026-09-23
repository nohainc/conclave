import { describe, expect, it } from "vitest";
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const migrations = path.resolve(here, "../migrations-v4");

function createDb() {
  const db = new DatabaseSync(":memory:");
  db.exec("PRAGMA foreign_keys = ON;");
  db.exec(
    fs.readFileSync(path.join(migrations, "0001_conclave_v4.sql"), "utf8"),
  );
  db.exec(
    fs.readFileSync(
      path.join(migrations, "0002_host_desired_state.sql"),
      "utf8",
    ),
  );
  return db;
}

function seed(db: DatabaseSync) {
  db.exec(`
    INSERT INTO users (id, email, display_name, created_at, updated_at)
      VALUES ('user-1', 'user@example.com', 'User', 'now', 'now');
    INSERT INTO workspaces (id, name, slug, created_at, updated_at)
      VALUES ('workspace-1', 'Workspace', 'workspace-1', 'now', 'now');
    INSERT INTO workspace_memberships
      (id, workspace_id, user_id, role, created_at, updated_at)
      VALUES ('membership-1', 'workspace-1', 'user-1', 'owner', 'now', 'now');
    INSERT INTO hosts
      (id, name, hostname, status, version, enrolled_at, created_at, updated_at)
      VALUES ('host-1', 'Host', 'local', 'online', '4.0.0', 'now', 'now', 'now');
    INSERT INTO host_workspace_bindings
      (id, host_id, workspace_id, granted_by_user_id, created_at, updated_at)
      VALUES ('binding-1', 'host-1', 'workspace-1', 'user-1', 'now', 'now');
    INSERT INTO workers
      (id, display_name, publisher, status, created_at, updated_at)
      VALUES ('codex', 'Codex', 'Conclave', 'active', 'now', 'now');
    INSERT INTO worker_versions
      (id, worker_id, version, protocol_version, min_host_version,
       supported_os_json, supported_arch_json, entrypoint, package_digest,
       package_r2_key, signature, created_at)
      VALUES ('codex-v1', 'codex', '1.0.0', '4.0', '0.1.0',
       '["macos"]', '["arm64"]', 'package.bin', 'sha256:one',
       'workers/codex/1.0.0', 'sig-one', 'now');
  `);
}

describe("V4 Host desired state", () => {
  it("stores an idempotent desired Worker set and removes stale entries", () => {
    const db = createDb();
    seed(db);
    db.prepare(
      `INSERT INTO host_desired_states
       (host_id, release_channel, revision, updated_at)
       VALUES ('host-1', 'stable', 1, 'now')`,
    ).run();
    db.prepare(
      `INSERT INTO host_desired_workers
       (host_id, worker_id, required_version, created_at, updated_at)
       VALUES ('host-1', 'codex', '1.0.0', 'now', 'now')`,
    ).run();

    db.prepare(
      `INSERT INTO host_desired_states
       (host_id, release_channel, revision, updated_at)
       VALUES ('host-1', 'stable', 2, 'later')
       ON CONFLICT(host_id) DO UPDATE SET revision = excluded.revision`,
    ).run();
    db.prepare("DELETE FROM host_desired_workers WHERE host_id = ?").run(
      "host-1",
    );

    expect(
      db
        .prepare("SELECT revision FROM host_desired_states WHERE host_id = ?")
        .get("host-1"),
    ).toEqual({ revision: 2 });
    expect(
      db
        .prepare(
          "SELECT COUNT(*) AS count FROM host_desired_workers WHERE host_id = ?",
        )
        .get("host-1"),
    ).toEqual({ count: 0 });
  });

  it("rejects desired versions that are revoked or not in the Worker catalog", () => {
    const db = createDb();
    seed(db);
    db.prepare("UPDATE worker_versions SET is_revoked = 1 WHERE id = ?").run(
      "codex-v1",
    );
    expect(() =>
      db
        .prepare(
          `INSERT INTO host_desired_workers
         (host_id, worker_id, required_version, created_at, updated_at)
         VALUES ('host-1', 'codex', '1.0.0', 'now', 'now')`,
        )
        .run(),
    ).not.toThrow();

    const available = db
      .prepare(
        `SELECT dw.worker_id FROM host_desired_workers dw
         JOIN worker_versions wv
           ON wv.worker_id = dw.worker_id AND wv.version = dw.required_version
         JOIN workers w ON w.id = dw.worker_id
         WHERE dw.host_id = ? AND w.status = 'active' AND wv.is_revoked = 0`,
      )
      .all("host-1");
    expect(available).toEqual([]);
  });

  it("keeps desired state tenant-scoped through the Host binding", () => {
    const db = createDb();
    seed(db);
    expect(
      db
        .prepare(
          `SELECT h.id FROM hosts h
           JOIN host_workspace_bindings b ON b.host_id = h.id
           WHERE h.id = ? AND b.workspace_id = ? AND b.status = 'active'`,
        )
        .all("host-1", "other-workspace"),
    ).toEqual([]);
  });
});
