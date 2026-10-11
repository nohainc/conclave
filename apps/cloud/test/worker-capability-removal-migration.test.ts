import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const migrationText = (name: string): string =>
  readFileSync(
    fileURLToPath(new URL(`../migrations-v8/${name}`, import.meta.url)),
    "utf8",
  );

describe("Worker capability metadata removal", () => {
  it("clears legacy values and removes capability columns", () => {
    const db = new DatabaseSync(":memory:");
    db.exec(migrationText("0001_conclave_v8.sql"));
    db.exec(migrationText("0029_worker_model_discovery.sql"));
    db.exec(migrationText("0031_remove_worker_profile_capabilities.sql"));
    db.exec(migrationText("0032_drop_worker_capability_columns.sql"));
    db.exec(migrationText("0033_reset_legacy_tool_profile_releases.sql"));

    const columns = (table: string) =>
      (
        db.prepare(`PRAGMA table_info(${table})`).all() as { name: string }[]
      ).map((column) => column.name);
    expect(columns("worker_catalog")).not.toContain("capabilities_json");
    expect(columns("workspace_worker_inventory")).not.toContain(
      "capabilities_json",
    );
    expect(columns("workspace_space_grants")).not.toContain(
      "allowed_worker_capabilities_json",
    );
    const starter = db
      .prepare(
        "SELECT profile_json FROM tool_profile_starter_templates WHERE profile_definition_id = ?",
      )
      .get("chatgpt-codex") as { profile_json: string } | undefined;
    expect(starter).toBeDefined();
    expect(JSON.parse(starter!.profile_json)).not.toHaveProperty(
      "capabilities",
    );
  });

  it("resets legacy releases, pointers, evidence, and inventory claims", () => {
    const db = new DatabaseSync(":memory:");
    db.exec(migrationText("0001_conclave_v8.sql"));
    db.exec(migrationText("0029_worker_model_discovery.sql"));
    db.exec(migrationText("0031_remove_worker_profile_capabilities.sql"));
    db.exec(migrationText("0032_drop_worker_capability_columns.sql"));

    db.prepare(
      `INSERT INTO tool_profile_releases (
        profile_definition_id, release_version, worker_type_id,
        lifecycle_state, schema_version, engine_family,
        engine_compatibility_min, engine_compatibility_max_exclusive,
        payload_json, payload_digest, signature, signing_key_id, publisher,
        published_at, created_at, updated_at
      ) VALUES (?, ?, ?, 'stable', 1, 'cli', '1.0.0', '2.0.0', ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).run(
      "chatgpt-codex",
      1,
      "chatgpt",
      "{}",
      "a".repeat(64),
      "signature",
      "key",
      "conclave",
      "2026-10-01T00:00:00Z",
      "2026-10-01T00:00:00Z",
      "2026-10-01T00:00:00Z",
    );
    db.prepare(
      `INSERT INTO tool_profile_channel_pointers (
        profile_definition_id, channel, release_version, updated_at
      ) VALUES ('chatgpt-codex', 'stable', 1, '2026-10-01T00:00:00Z')`,
    ).run();
    db.prepare(
      `INSERT INTO tool_profile_acceptance_evidence (
        id, profile_definition_id, release_version, payload_digest,
        engine_version, provider_tool_version, evidence_json, accepted_at,
        submitted_at
      ) VALUES ('evidence-1', 'chatgpt-codex', 1, ?, '1.0.0', '0.1.0', '{}', ?, ?)`,
    ).run("a".repeat(64), "2026-10-01T00:00:00Z", "2026-10-01T00:00:00Z");

    db.exec(migrationText("0033_reset_legacy_tool_profile_releases.sql"));

    expect(
      db.prepare("SELECT COUNT(*) AS count FROM tool_profile_releases").get(),
    ).toEqual({ count: 0 });
    expect(
      db
        .prepare("SELECT COUNT(*) AS count FROM tool_profile_channel_pointers")
        .get(),
    ).toEqual({ count: 0 });
    expect(
      db
        .prepare(
          "SELECT COUNT(*) AS count FROM tool_profile_acceptance_evidence",
        )
        .get(),
    ).toEqual({ count: 0 });
    expect(
      db
        .prepare("SELECT COUNT(*) AS count FROM tool_profile_release_audit")
        .get(),
    ).toEqual({ count: 0 });

    const triggerNames = db
      .prepare("SELECT name FROM sqlite_master WHERE type = 'trigger'")
      .all() as { name: string }[];
    expect(triggerNames.map(({ name }) => name)).toContain(
      "tool_profile_published_release_no_delete",
    );
  });
});
