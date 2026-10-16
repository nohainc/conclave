import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const migrationText = (name: string): string =>
  readFileSync(
    fileURLToPath(new URL(`../migrations-v8/${name}`, import.meta.url)),
    "utf8",
  );

describe("revoked ChatGPT/Gemini release cleanup migration", () => {
  it("removes only revoked ChatGPT and Gemini releases and their references", () => {
    const db = new DatabaseSync(":memory:");
    db.exec(migrationText("0001_conclave_v8.sql"));

    const now = "2026-10-11T00:00:00Z";
    for (const workerTypeId of ["chatgpt", "gemini", "other"]) {
      db.prepare(
        `INSERT OR IGNORE INTO worker_catalog (
           worker_type_id, display_name, created_at, updated_at
         ) VALUES (?, ?, ?, ?)`,
      ).run(workerTypeId, workerTypeId, now, now);
    }
    for (const [definitionId, workerTypeId] of [
      ["chatgpt-codex", "chatgpt"],
      ["gemini-antigravity", "gemini"],
      ["other-worker", "other"],
    ] as const) {
      db.prepare(
        `INSERT OR IGNORE INTO tool_profile_definitions (
           profile_definition_id, worker_type_id, display_name,
           provider_tool_name, engine_family, schema_version,
           lifecycle_state, created_at, updated_at
         ) VALUES (?, ?, ?, ?, 'cli', 1, 'active', ?, ?)`,
      ).run(
        definitionId,
        workerTypeId,
        definitionId,
        `${workerTypeId}-cli`,
        now,
        now,
      );
    }

    for (const [definitionId, workerTypeId, state, version] of [
      ["chatgpt-codex", "chatgpt", "revoked", 1],
      ["chatgpt-codex", "chatgpt", "testing", 2],
      ["gemini-antigravity", "gemini", "revoked", 1],
      ["other-worker", "other", "revoked", 1],
    ] as const) {
      db.prepare(
        `INSERT INTO tool_profile_releases (
           profile_definition_id, release_version, worker_type_id,
           lifecycle_state, schema_version, engine_family,
           engine_compatibility_min, engine_compatibility_max_exclusive,
           payload_json, payload_digest, signature, signing_key_id, publisher,
           published_at, created_at, updated_at
         ) VALUES (?, ?, ?, ?, 1, 'cli', '1.0.0', '2.0.0', ?, ?, ?, ?, ?, ?, ?, ?)`,
      ).run(
        definitionId,
        version,
        workerTypeId,
        state,
        "{}",
        String(version).padStart(64, "0"),
        "signature",
        "key",
        "conclave",
        now,
        now,
        now,
      );
    }

    db.prepare(
      `INSERT INTO tool_profile_release_audit (
         id, profile_definition_id, release_version, action, details_json, created_at
       ) VALUES ('audit-chatgpt', 'chatgpt-codex', 1, 'revoked', '{}', ?)`,
    ).run(now);
    db.prepare(
      `INSERT INTO tool_profile_release_audit (
         id, profile_definition_id, release_version, action, details_json, created_at
       ) VALUES ('audit-other', 'other-worker', 1, 'revoked', '{}', ?)`,
    ).run(now);

    db.exec(migrationText("0036_remove_revoked_chatgpt_gemini_releases.sql"));

    expect(
      db
        .prepare(
          "SELECT worker_type_id, release_version, lifecycle_state FROM tool_profile_releases ORDER BY worker_type_id, release_version",
        )
        .all(),
    ).toEqual([
      {
        worker_type_id: "chatgpt",
        release_version: 2,
        lifecycle_state: "testing",
      },
      {
        worker_type_id: "other",
        release_version: 1,
        lifecycle_state: "revoked",
      },
    ]);
    const remainingAudit = db
      .prepare(
        "SELECT profile_definition_id, release_version FROM tool_profile_release_audit ORDER BY id",
      )
      .all() as { profile_definition_id: string; release_version: number }[];
    expect(remainingAudit).toEqual(
      expect.arrayContaining([
        { profile_definition_id: "other-worker", release_version: 1 },
      ]),
    );
    expect(
      remainingAudit.some(
        (row) =>
          (row.profile_definition_id === "chatgpt-codex" ||
            row.profile_definition_id === "gemini-antigravity") &&
          row.release_version === 1,
      ),
    ).toBe(false);

    expect(() =>
      db
        .prepare(
          "DELETE FROM tool_profile_releases WHERE profile_definition_id = ?",
        )
        .run("other-worker"),
    ).toThrow(/published Tool Profile releases cannot be deleted/);
  });
});
