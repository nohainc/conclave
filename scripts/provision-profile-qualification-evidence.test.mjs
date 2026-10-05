import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { expect, it } from "vitest";
import { qualificationProvisioningSql } from "./provision-profile-qualification-evidence.mjs";

it("adopts qualification schema repeatedly without altering existing baseline records", () => {
  const db = new DatabaseSync(":memory:");
  try {
    const baseline = readFileSync(
      new URL(
        "../apps/cloud/migrations-v8/0001_conclave_v8.sql",
        import.meta.url,
      ),
      "utf8",
    );
    db.exec(baseline);
    const before = db.prepare("SELECT * FROM tool_profile_releases").all();
    const sql = qualificationProvisioningSql(baseline);
    db.exec(sql);
    db.exec(sql);
    expect(db.prepare("SELECT * FROM tool_profile_releases").all()).toEqual(
      before,
    );
    expect(
      db
        .prepare(
          "SELECT COUNT(*) AS n FROM sqlite_master WHERE name LIKE 'tool_profile_local_qualification_%'",
        )
        .get().n,
    ).toBe(3);
    expect(sql).not.toMatch(/DROP|DELETE FROM|UPDATE tool_profile_releases/);
  } finally {
    db.close();
  }
});
