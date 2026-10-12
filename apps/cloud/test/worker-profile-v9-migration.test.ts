import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const baseMigration = readFileSync(
  fileURLToPath(
    new URL("../migrations-v8/0001_conclave_v8.sql", import.meta.url),
  ),
  "utf8",
);
const v9Migration = readFileSync(
  fileURLToPath(
    new URL("../migrations-v8/0043_worker_profiles_v9.sql", import.meta.url),
  ),
  "utf8",
);

function apply(sql: string): unknown[] {
  const [beforeMigration, afterMigration = ""] = sql.split(
    "-- MIGRATION ASSERTIONS",
    2,
  );
  return JSON.parse(
    execFileSync("sqlite3", ["-bail", "-json", ":memory:"], {
      input: `${baseMigration}\n${beforeMigration}\n${v9Migration}\n${afterMigration}`,
      encoding: "utf8",
    }) || "[]",
  ) as unknown[];
}

describe("Worker Profile V9 additive migration", () => {
  it("creates one direct current Profile row per approved stable Worker", () => {
    expect(
      apply(`
        INSERT INTO tool_profile_releases (
          profile_definition_id, release_version, worker_type_id,
          lifecycle_state, schema_version, engine_family,
          engine_compatibility_min, engine_compatibility_max_exclusive,
          payload_json, payload_digest, signature, signing_key_id, publisher,
          published_at, created_at, updated_at
        ) VALUES (
          'chatgpt-codex', 7, 'chatgpt', 'stable', 1, 'cli',
          '1.0.0', '2.0.0',
          '{"schemaVersion":1,"profileDefinitionId":"chatgpt-codex","releaseVersion":7,"logicalWorkerTypeId":"chatgpt"}',
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'signature-v7', 'profile-key-v1', 'conclave',
          '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'
        );
        INSERT INTO tool_profile_channel_pointers (
          profile_definition_id, channel, release_version, updated_at
        ) VALUES ('chatgpt-codex', 'stable', 7, '2026-10-10T00:00:00Z');
        -- MIGRATION ASSERTIONS
        SELECT worker_type_id, revision, digest, signature, signing_key_id
          FROM worker_profiles;
      `),
    ).toEqual([
      {
        worker_type_id: "chatgpt",
        revision: 7,
        digest: "a".repeat(64),
        signature: "signature-v7",
        signing_key_id: "profile-key-v1",
      },
    ]);
  });

  it("copies earlier published stable snapshots into history without adding channels", () => {
    expect(
      apply(`
        INSERT INTO tool_profile_releases (
          profile_definition_id, release_version, worker_type_id,
          lifecycle_state, schema_version, engine_family,
          engine_compatibility_min, engine_compatibility_max_exclusive,
          payload_json, payload_digest, signature, signing_key_id, publisher,
          published_at, created_at, updated_at
        ) VALUES
          ('chatgpt-codex', 6, 'chatgpt', 'stable', 1, 'cli',
           '1.0.0', '2.0.0',
           '{"schemaVersion":1,"profileDefinitionId":"chatgpt-codex","releaseVersion":6,"logicalWorkerTypeId":"chatgpt"}',
           'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
           'signature-v6', 'profile-key-v1', 'conclave',
           '2026-10-09T00:00:00Z', '2026-10-09T00:00:00Z', '2026-10-09T00:00:00Z'),
          ('chatgpt-codex', 7, 'chatgpt', 'stable', 1, 'cli',
           '1.0.0', '2.0.0',
           '{"schemaVersion":1,"profileDefinitionId":"chatgpt-codex","releaseVersion":7,"logicalWorkerTypeId":"chatgpt"}',
           'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
           'signature-v7', 'profile-key-v1', 'conclave',
           '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z');
        INSERT INTO tool_profile_channel_pointers (
          profile_definition_id, channel, release_version, updated_at
        ) VALUES ('chatgpt-codex', 'stable', 7, '2026-10-10T00:00:00Z');
        -- MIGRATION ASSERTIONS
        SELECT worker_type_id, revision, digest, restoration_reason
          FROM worker_profile_history;
      `),
    ).toEqual([
      {
        worker_type_id: "chatgpt",
        revision: 6,
        digest: "b".repeat(64),
        restoration_reason: null,
      },
    ]);
  });

  it("rejects malformed migrated JSON rather than creating a current row", () => {
    expect(() =>
      apply(`
        INSERT INTO tool_profile_releases (
          profile_definition_id, release_version, worker_type_id,
          lifecycle_state, schema_version, engine_family,
          engine_compatibility_min, engine_compatibility_max_exclusive,
          payload_json, payload_digest, signature, signing_key_id, publisher,
          published_at, created_at, updated_at
        ) VALUES (
          'chatgpt-codex', 8, 'chatgpt', 'stable', 1, 'cli',
          '1.0.0', '2.0.0', '{"schemaVersion":2}',
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
          'signature-v8', 'profile-key-v1', 'conclave',
          '2026-10-11T00:00:00Z', '2026-10-11T00:00:00Z', '2026-10-11T00:00:00Z'
        );
        INSERT INTO tool_profile_channel_pointers (
          profile_definition_id, channel, release_version, updated_at
        ) VALUES ('chatgpt-codex', 'stable', 8, '2026-10-11T00:00:00Z');
      `),
    ).toThrow();
  });
});
