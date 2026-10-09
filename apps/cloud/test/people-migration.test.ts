import { readFileSync } from "node:fs";
import { expect, it } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
it("backfills accepted co-members once, retains relationships, and consolidates duplicate pending invitations", () => {
  const { sqlite } = sqliteD1();
  try {
    sqlite.exec(`DROP TRIGGER establish_people_on_membership; DROP TABLE people_relationships; DROP INDEX idx_space_invitations_pending_email;
 INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('a','a@test','A','now','now'),('b','b@test','B','now','now'),('c','c@test','C','now','now');
 INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('A','a','A','now','now'),('B','a','B','now','now');
 INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('a1','A','a','owner','2026-01-01','now'),('b1','A','b','viewer','2026-01-02','now'),('a2','B','a','owner','2026-02-01','now'),('b2','B','b','viewer','2026-02-02','now');
 INSERT INTO space_invitations(id,space_id,email,role,token_hash,invited_by_user_id,expires_at,created_at,updated_at) VALUES('i1','A','c@test','viewer','h1','a','2099-01-01','2026-01-01','now'),('i2','A','C@test','viewer','h2','a','2099-01-01','2026-01-02','now');`);
    sqlite.exec(
      readFileSync(
        new URL(
          "../migrations-v8/0023_people_relationships.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    expect(sqlite.prepare("SELECT * FROM people_relationships").all()).toEqual([
      { user_low_id: "a", user_high_id: "b", established_at: "2026-01-02" },
    ]);
    expect(
      sqlite
        .prepare("SELECT id,status FROM space_invitations ORDER BY id")
        .all(),
    ).toEqual([
      { id: "i1", status: "pending" },
      { id: "i2", status: "revoked" },
    ]);
    sqlite.exec(
      "INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('c1','A','c','viewer','2026-03-01','now')",
    );
    expect(
      sqlite.prepare("SELECT COUNT(*) n FROM people_relationships").get(),
    ).toEqual({ n: 3 });
    sqlite.exec("DELETE FROM space_memberships");
    expect(
      sqlite.prepare("SELECT COUNT(*) n FROM people_relationships").get(),
    ).toEqual({ n: 3 });
    expect(sqlite.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
  } finally {
    sqlite.close();
  }
});
