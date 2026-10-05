import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { expect, it } from "vitest";
import { starterTemplateProvisioningSql } from "./provision-profile-starter-templates.mjs";

it("provisions only the missing baseline starter table and preserves Drafts and existing templates", () => {
  const db = new DatabaseSync(":memory:");
  try {
    db.exec(`CREATE TABLE tool_profile_definitions (profile_definition_id TEXT PRIMARY KEY);
      INSERT INTO tool_profile_definitions VALUES ('chatgpt-codex'), ('gemini-antigravity');
      CREATE TABLE tool_profile_releases (profile_definition_id TEXT PRIMARY KEY, payload_json TEXT);
      INSERT INTO tool_profile_releases VALUES ('chatgpt-codex', 'saved-draft');`);
    const sql = starterTemplateProvisioningSql(
      readFileSync(
        new URL(
          "../apps/cloud/migrations-v8/0001_conclave_v8.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    db.exec(sql);
    expect(
      db
        .prepare("SELECT COUNT(*) AS count FROM tool_profile_starter_templates")
        .get().count,
    ).toBe(2);
    db.exec(
      "UPDATE tool_profile_starter_templates SET updated_at = 'operator-change'",
    );
    db.exec(sql);
    expect(
      db
        .prepare(
          "SELECT DISTINCT updated_at FROM tool_profile_starter_templates",
        )
        .all(),
    ).toEqual([{ updated_at: "operator-change" }]);
    expect(
      db.prepare("SELECT payload_json FROM tool_profile_releases").get()
        .payload_json,
    ).toBe("saved-draft");
  } finally {
    db.close();
  }
});
