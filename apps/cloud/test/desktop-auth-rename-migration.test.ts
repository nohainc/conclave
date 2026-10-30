import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { expect, it } from "vitest";

const baseline = readFileSync(
  new URL("../migrations-v8/0001_syntila_v8.sql", import.meta.url),
  "utf8",
);
const migration = readFileSync(
  new URL(
    "../migrations-v8/0093_syntila_desktop_auth_audiences.sql",
    import.meta.url,
  ),
  "utf8",
);

for (const legacy of [true, false]) {
  it(`preserves desktop authentication records on ${legacy ? "legacy" : "current"} schemas`, () => {
    const db = new DatabaseSync(":memory:");
    try {
      db.exec(
        legacy
          ? baseline
              .replaceAll(
                "syntila.desktop.management",
                "conclave.desktop.management",
              )
              .replaceAll(
                "syntila.profile-lab.management",
                "conclave.profile-lab.management",
              )
          : baseline,
      );
      const prefix = legacy ? "conclave" : "syntila";
      db.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('u','u@example.test','User','now','now');
        INSERT INTO desktop_auth_intents(id,poll_token_hash,client_name,audience,created_at,expires_at,approved_user_id) VALUES('i','hash','client','${prefix}.desktop.management','now','later','u');
        INSERT INTO desktop_human_sessions(id,user_id,token_hash,audience,created_at,last_used_at,expires_at) VALUES('s','u','secret-hash','${prefix}.profile-lab.management','now','now','later');`);
      db.exec("BEGIN");
      db.exec(migration);
      db.exec("COMMIT");
      expect(
        db
          .prepare(
            "SELECT audience, approved_user_id FROM desktop_auth_intents",
          )
          .get(),
      ).toMatchObject({
        audience: "syntila.desktop.management",
        approved_user_id: "u",
      });
      expect(
        db
          .prepare("SELECT audience, token_hash FROM desktop_human_sessions")
          .get(),
      ).toMatchObject({
        audience: "syntila.profile-lab.management",
        token_hash: "secret-hash",
      });
      expect(db.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
    } finally {
      db.close();
    }
  });
}
