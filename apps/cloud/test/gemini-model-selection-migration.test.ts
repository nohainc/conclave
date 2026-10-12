import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const migrationText = (name: string): string =>
  readFileSync(
    fileURLToPath(new URL(`../migrations-v8/${name}`, import.meta.url)),
    "utf8",
  );

describe("Gemini combined model starter", () => {
  it("repairs the full-access mapping for already-migrated databases", () => {
    const db = new DatabaseSync(":memory:");
    db.exec(migrationText("0001_conclave_v8.sql"));
    db.exec(migrationText("0041_full_local_access_profile_mappings.sql"));

    const row = db
      .prepare(
        "SELECT profile_json FROM tool_profile_starter_templates WHERE profile_definition_id = ?",
      )
      .get("gemini-antigravity") as { profile_json: string };
    const profile = JSON.parse(row.profile_json) as any;
    expect(profile.sandbox.mappings.full_access).toEqual([
      "--dangerously-skip-permissions",
    ]);

    db
      .prepare(
        "UPDATE tool_profile_starter_templates SET profile_json = json_set(profile_json, '$.sandbox.mappings.full_access', json_array(?)) WHERE profile_definition_id = ?",
      )
      .run("--custom-approved-flag", "gemini-antigravity");
    db.exec(migrationText("0041_full_local_access_profile_mappings.sql"));
    const customized = db
      .prepare(
        "SELECT profile_json FROM tool_profile_starter_templates WHERE profile_definition_id = ?",
      )
      .get("gemini-antigravity") as { profile_json: string };
    expect(
      JSON.parse(customized.profile_json).sandbox.mappings.full_access,
    ).toEqual(["--custom-approved-flag"]);
  });

  it("publishes logical families and removes the separate effort argument", () => {
    const db = new DatabaseSync(":memory:");
    db.exec(migrationText("0001_conclave_v8.sql"));
    db.exec(migrationText("0029_worker_model_discovery.sql"));
    db.exec(migrationText("0030_gemini_model_discovery_starter.sql"));
    db.exec(migrationText("0034_runtime_model_catalog_starters.sql"));
    db.exec(migrationText("0038_gemini_combined_model_selection.sql"));
    db.exec(migrationText("0041_full_local_access_profile_mappings.sql"));

    const row = db
      .prepare(
        "SELECT profile_json FROM tool_profile_starter_templates WHERE profile_definition_id = ?",
      )
      .get("gemini-antigravity") as { profile_json: string };
    const profile = JSON.parse(row.profile_json) as any;
    expect(profile.model.selectionMode).toBe("combined");
    expect(profile.model.selectionMapping.models).toHaveLength(4);
    expect(profile.model.selectionMapping.models[0].variants).toHaveLength(3);
    expect(
      profile.model.selectionMapping.models.flatMap((model: any) =>
        model.variants.map((variant: any) => variant.providerVersion),
      ).filter((range: unknown) => range !== undefined),
    ).toEqual([]);
    expect(profile.providerTool.supportedVersions).toEqual([
      { min: "1.2.16", maxExclusive: "1.2.17" },
      { min: "1.3.3", maxExclusive: "1.3.4" },
    ]);
    expect(profile.model.executionOptions).toBeUndefined();
    expect(profile.sandbox.mappings.full_access).toEqual([
      "--dangerously-skip-permissions",
    ]);
    expect(
      JSON.stringify(profile.execution.arguments),
    ).not.toContain("reasoningEffort");
  });
});
