import { describe, expect, it, vi } from "vitest";
import { handleListWorkspaces } from "../src/routes/workspaces-management.js";
import type { SecurityEnv } from "../src/routes/handlers.js";
import { sqliteD1 } from "./helpers/sqlite-d1.js";

function fixture() {
  const { sqlite, db } = sqliteD1();
  sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES
    ('owner','owner@test','Owner','now','now'), ('other','other@test','Other','now','now');
    INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES
    ('mine','owner','Mine','now','now'), ('empty','owner','Empty','now','now'),
    ('private','other','Private','now','now');`);
  const env = {
    CONCLAVE_ENVIRONMENT: "development",
    CONCLAVE_DB: db,
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
  function project(id: string, archived = false) {
    sqlite
      .prepare(
        "INSERT INTO projects(id,owner_user_id,name,settings_json,created_at,updated_at) VALUES (?,'other',?,?, 'now','now')",
      )
      .run(id, id, JSON.stringify({ archived }));
  }
  function grant(
    id: string,
    projectId: string,
    status = "active",
    expiry: string | null = null,
    workspace = "mine",
  ) {
    sqlite
      .prepare(
        "INSERT INTO workspace_project_grants(id,project_id,workspace_id,granted_by_user_id,status,expires_at,created_at,updated_at) VALUES (?,?,?,?,?,?,'now','now')",
      )
      .run(
        id,
        projectId,
        workspace,
        workspace === "private" ? "other" : "owner",
        status,
        expiry,
      );
  }
  const list = async () => {
    const response = await handleListWorkspaces(
      new Request("https://cloud.test/api/workspaces"),
      env,
    );
    return (await response.json()) as {
      workspaces: { id: string; activeProjectGrantCount: number }[];
    };
  };
  return { sqlite, db, project, grant, list };
}

describe("Workspace aggregate Project grant counts", () => {
  it("counts distinct active, unexpired grants to unarchived Projects, only for owned Workspaces", async () => {
    const f = fixture();
    try {
      for (const id of [
        "active",
        "suspended",
        "revoked",
        "expired",
        "timed-out",
        "future",
        "private",
      ])
        f.project(id);
      f.project("archived", true);
      f.grant("g1", "active");
      f.grant("duplicate", "active");
      f.grant("g2", "suspended", "suspended");
      f.grant("g3", "revoked", "revoked");
      f.grant("g4", "expired", "expired");
      f.grant("g5", "timed-out", "active", "2000-01-01T00:00:00.000Z");
      f.grant("g6", "future", "active", "2999-01-01T00:00:00.000Z");
      f.grant("g7", "archived");
      f.grant("g8", "private", "active", null, "private");
      const { workspaces } = await f.list();
      expect(workspaces.map((w) => w.id).sort()).toEqual(["empty", "mine"]);
      expect(
        workspaces.find((w) => w.id === "mine")?.activeProjectGrantCount,
      ).toBe(2);
      expect(
        workspaces.find((w) => w.id === "empty")?.activeProjectGrantCount,
      ).toBe(0);
    } finally {
      f.sqlite.close();
    }
  });
  it("returns counts for 30 Projects with one aggregate database read and no per-Project reads", async () => {
    const f = fixture();
    try {
      for (let i = 0; i < 30; i++) {
        f.project(`p${i}`);
        f.grant(`g${i}`, `p${i}`);
      }
      const reads = vi.spyOn(f.db, "prepare");
      const { workspaces } = await f.list();
      expect(
        workspaces.find((w) => w.id === "mine")?.activeProjectGrantCount,
      ).toBe(30);
      expect(reads.mock.calls).toHaveLength(1);
      expect(reads.mock.calls[0]?.[0]).toContain(
        "COUNT(DISTINCT g.project_id)",
      );
    } finally {
      f.sqlite.close();
    }
  });
});
