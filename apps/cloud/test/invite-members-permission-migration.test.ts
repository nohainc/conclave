import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { sqliteD1 } from "./helpers/sqlite-d1.js";

describe("invite-members permission cleanup migration", () => {
  let store: ReturnType<typeof sqliteD1>;

  beforeEach(() => {
    store = sqliteD1();
    store.sqlite
      .prepare(
        "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('owner','owner@test','Owner','now','now')",
      )
      .run();
    store.sqlite
      .prepare(
        "INSERT INTO spaces(id,owner_user_id,name,settings_json,created_at,updated_at) VALUES('legacy','owner','Legacy',?,'now','now')",
      )
      .run(
        JSON.stringify({
          memberPermissions: {
            member: { chat: true, inviteMembers: true, work: false },
          },
          invitationPermissions: {
            invitation: { chat: false, inviteMembers: true, work: true },
          },
        }),
      );
  });

  afterEach(() => store.sqlite.close());

  it("removes only the obsolete invitation right from persisted snapshots", () => {
    store.sqlite.exec(
      readFileSync(
        new URL(
          "../migrations-v8/0025_remove_invite_members_permission.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    const row = store.sqlite
      .prepare("SELECT settings_json FROM spaces WHERE id='legacy'")
      .get() as { settings_json: string };
    expect(JSON.parse(row.settings_json)).toEqual({
      memberPermissions: { member: { chat: true, work: false } },
      invitationPermissions: { invitation: { chat: false, work: true } },
    });
  });
});
