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
      [
        "0007_chat_profile_starter_attestation.sql",
        "0008_codex_compatibility_approval_policy.sql",
        "0017_chatgpt_starter_model_catalog.sql",
      ]
        .map((name) =>
          readFileSync(
            new URL(`../apps/cloud/migrations-v8/${name}`, import.meta.url),
            "utf8",
          ),
        )
        .join("\n"),
    );
    db.exec(sql);
    const canonical = JSON.parse(
      readFileSync(
        new URL(
          "../packages/tool-profile/test/fixtures/chatgpt-codex.v1.json",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    const starter = JSON.parse(
      db
        .prepare(
          "SELECT profile_json FROM tool_profile_starter_templates WHERE profile_definition_id = ?",
        )
        .get("chatgpt-codex").profile_json,
    );
    expect(starter).toEqual(canonical);
    const manifestUrl = new URL(
      "../packages/tool-profile/test/fixtures/profiles/chatgpt-codex/manifest.json",
      import.meta.url,
    );
    const manifest = JSON.parse(readFileSync(manifestUrl, "utf8"));
    expect(
      JSON.parse(readFileSync(new URL(manifest.profile, manifestUrl), "utf8")),
    ).toEqual(canonical);
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

it("refreshes only the exact old starter catalog, preserving customized authoring and signed releases", () => {
  const db = new DatabaseSync(":memory:");
  try {
    const sql = readFileSync(
      new URL(
        "../apps/cloud/migrations-v8/0017_chatgpt_starter_model_catalog.sql",
        import.meta.url,
      ),
      "utf8",
    );
    const previous = sql
      .match(/AND profile_json = '(.+)';/)[1]
      .replaceAll("''", "'");
    db.exec(
      "CREATE TABLE tool_profile_starter_templates (profile_definition_id TEXT PRIMARY KEY, profile_json TEXT, updated_at TEXT); CREATE TABLE tool_profile_releases (payload_json TEXT); INSERT INTO tool_profile_releases VALUES ('immutable-signed-release');",
    );
    const insert = db.prepare(
      "INSERT INTO tool_profile_starter_templates VALUES (?, ?, ?)",
    );
    insert.run("chatgpt-codex", previous, "previous");
    db.exec(sql);
    const read = () =>
      db
        .prepare("SELECT profile_json FROM tool_profile_starter_templates")
        .get().profile_json;
    const models = JSON.parse(read()).model.catalog;
    expect(models).toHaveLength(8);
    expect(models.some((model) => model.id === "o3")).toBe(false);
    expect(
      models.find((model) => model.id === "gpt-6-luna")
        .supportedReasoningEfforts,
    ).not.toContain("ultra");
    db.prepare("UPDATE tool_profile_starter_templates SET profile_json=?").run(
      "custom-authoring-draft",
    );
    db.exec(sql);
    expect(read()).toBe("custom-authoring-draft");
    expect(
      db.prepare("SELECT payload_json FROM tool_profile_releases").get()
        .payload_json,
    ).toBe("immutable-signed-release");
  } finally {
    db.close();
  }
});
