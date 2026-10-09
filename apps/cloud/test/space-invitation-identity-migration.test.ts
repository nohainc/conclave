import { readFileSync } from "node:fs";
import { expect, it } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
it("backfills accepted identity and retains pending email invitations without duplicate recipient IDs", () => {
  const { sqlite } = sqliteD1();
  try {
    sqlite.exec(`DROP INDEX idx_space_invitations_pending_user; DROP INDEX idx_space_invitations_invitee; ALTER TABLE space_invitations DROP COLUMN invitee_user_id;
 INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('a','a@test','A','now','now'),('b','b@test','B','now','now');
 INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('A','a','Space','now','now');
 INSERT INTO space_invitations(id,space_id,email,role,token_hash,invited_by_user_id,status,accepted_by_user_id,expires_at,created_at,updated_at) VALUES('accepted','A','old@test','viewer','h1','a','accepted','b','2099','now','now'),('pending','A','unknown@test','viewer','h2','a','pending',NULL,'2099','now','now');`);
    sqlite.exec(
      readFileSync(
        new URL(
          "../migrations-v8/0024_space_invitation_identity.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    expect(
      sqlite
        .prepare("SELECT id,invitee_user_id FROM space_invitations ORDER BY id")
        .all(),
    ).toEqual([
      { id: "accepted", invitee_user_id: "b" },
      { id: "pending", invitee_user_id: null },
    ]);
    sqlite.exec(
      "UPDATE space_invitations SET invitee_user_id='b' WHERE id='pending'",
    );
    expect(() =>
      sqlite.exec(
        "INSERT INTO space_invitations(id,space_id,email,role,token_hash,invited_by_user_id,status,invitee_user_id,expires_at,created_at,updated_at) VALUES('duplicate','A','new@test','viewer','h3','a','pending','b','2099','now','now')",
      ),
    ).toThrow();
    expect(sqlite.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
  } finally {
    sqlite.close();
  }
});
