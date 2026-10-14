import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { expect, it } from "vitest";

const migration = readFileSync(
  new URL("../migrations-v8/0056_admit_gemini_cli_1_3_5.sql", import.meta.url),
  "utf8",
);
const sourceProfile = JSON.parse(
  readFileSync(
    new URL("../../profile_lab/assets/profiles/gemini.json", import.meta.url),
    "utf8",
  ),
);
const previousDigest =
  "23dd2cef514bac63dad017836ab883b44a3a522f9a54319d9d9af04a3a044892";
const updatedDigest =
  "a978c7a9ba029a4ee2d72a587a0acf63c8ad3a322bcf78b244cd89b9d7c102d1";
const previousMigration = readFileSync(
  new URL(
    "../migrations-v8/0051_agy_live_activity_combined_models.sql",
    import.meta.url,
  ),
  "utf8",
);
const previousPayloadStart = "SET profile_json = '";
const previousPayloadEnd = `',
       revision = revision + 1,
       digest = '${previousDigest}',`;
const previousPayloadStartIndex =
  previousMigration.indexOf(previousPayloadStart);
const previousPayloadEndIndex = previousMigration.indexOf(
  previousPayloadEnd,
  previousPayloadStartIndex,
);
if (previousPayloadStartIndex < 0 || previousPayloadEndIndex < 0) {
  throw new Error("Could not locate the published Gemini Profile payload");
}
const previousProfile = previousMigration.slice(
  previousPayloadStartIndex + previousPayloadStart.length,
  previousPayloadEndIndex,
);

it("authoring Gemini Profile admits CLI 1.3.5", () => {
  expect(sourceProfile.providerTool.supportedVersions).toContainEqual({
    min: "1.3.4",
    maxExclusive: "1.3.6",
  });
});

it("updates the single published Gemini Profile once and preserves history", () => {
  const db = new DatabaseSync(":memory:");
  db.exec(`
    CREATE TABLE worker_profiles (
      worker_type_id TEXT PRIMARY KEY,
      revision INTEGER NOT NULL,
      schema_version INTEGER NOT NULL,
      profile_json TEXT NOT NULL,
      digest TEXT NOT NULL,
      updated_by_user_id TEXT,
      updated_at TEXT NOT NULL
    );
    CREATE TABLE worker_profile_history (
      worker_type_id TEXT NOT NULL,
      revision INTEGER NOT NULL,
      schema_version INTEGER NOT NULL,
      profile_json TEXT NOT NULL,
      digest TEXT NOT NULL,
      actor_user_id TEXT,
      published_at TEXT,
      restoration_reason TEXT
    );
  `);

  db.prepare(
    `INSERT INTO worker_profiles
      (worker_type_id, revision, schema_version, profile_json, digest,
       updated_by_user_id, updated_at)
     VALUES ('gemini', 4, 1, ?, ?, 'system', '2026-10-14T00:00:00Z')`,
  ).run(previousProfile, previousDigest);

  db.exec(migration);

  const updated = db
    .prepare(
      "SELECT revision, profile_json, digest FROM worker_profiles WHERE worker_type_id = 'gemini'",
    )
    .get() as { revision: number; profile_json: string; digest: string };
  expect(updated.revision).toBe(5);
  expect(
    JSON.parse(updated.profile_json).providerTool.supportedVersions[2],
  ).toEqual({
    min: "1.3.4",
    maxExclusive: "1.3.6",
  });
  expect(updated.digest).toBe(updatedDigest);
  expect(createHash("sha256").update(updated.profile_json).digest("hex")).toBe(
    updatedDigest,
  );
  expect(
    db
      .prepare(
        "SELECT revision, digest, restoration_reason FROM worker_profile_history WHERE worker_type_id = 'gemini'",
      )
      .get(),
  ).toEqual({
    revision: 4,
    digest: previousDigest,
    restoration_reason: "Admit Antigravity CLI 1.3.5",
  });

  db.exec(migration);
  expect(
    db
      .prepare(
        "SELECT revision, digest FROM worker_profiles WHERE worker_type_id = 'gemini'",
      )
      .get(),
  ).toEqual({ revision: 5, digest: updatedDigest });
  expect(
    db
      .prepare(
        "SELECT COUNT(*) AS count FROM worker_profile_history WHERE worker_type_id = 'gemini'",
      )
      .get(),
  ).toEqual({ count: 1 });
  db.close();
});
