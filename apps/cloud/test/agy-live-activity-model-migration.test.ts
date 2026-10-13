import { createHash } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const directory = fileURLToPath(new URL("../migrations-v8/", import.meta.url));
const migration = readFileSync(
  `${directory}/0051_agy_live_activity_combined_models.sql`,
  "utf8",
);
const canonical = (value: any): string =>
  JSON.stringify(value, (_, item) =>
    item && typeof item === "object" && !Array.isArray(item)
      ? Object.fromEntries(
          Object.keys(item)
            .sort()
            .map((key) => [key, item[key]]),
        )
      : item,
  );
const digest = (text: string) =>
  createHash("sha256").update(text).digest("hex");
// Applied migrations use frozen historical input, not mutable authoring templates.
const template = (_version: number) =>
  JSON.parse(
    readFileSync(
      new URL("./fixtures/agy-live-activity-pre-0051.json", import.meta.url),
      "utf8",
    ),
  );

describe("current AGY live-activity mapping repair", () => {
  for (const revision of [6, 7, 12]) {
    it(`preserves live activity and advances exact payload at revision ${revision}`, () => {
      const db = new DatabaseSync(":memory:");
      for (const name of readdirSync(directory)
        .filter((name) => name.endsWith(".sql") && name < "0051")
        .sort())
        db.exec(readFileSync(`${directory}/${name}`, "utf8"));
      const previous = canonical(template(4));
      db.prepare(
        "INSERT INTO worker_profiles (worker_type_id, schema_version, profile_json, revision, digest, updated_at) VALUES ('gemini', 1, ?, ?, ?, '2026-10-13T00:00:00Z')",
      ).run(previous, revision, digest(previous));
      db.exec(migration);
      const row = db
        .prepare(
          "SELECT * FROM worker_profiles WHERE worker_type_id = 'gemini'",
        )
        .get() as any;
      expect(row.revision).toBe(revision + 1);
      expect(row.digest).toBe(digest(row.profile_json));
      // Applied migrations remain immutable history after their reversal.
      expect(row.profile_json).toBe(
        migration.match(/SET profile_json = '(.*?)',/)![1],
      );
      const profile = JSON.parse(row.profile_json);
      expect(profile.model.selectionMapping.models).toHaveLength(7);
      expect(
        profile.model.selectionMapping.models.flatMap(
          (model: any) => model.variants,
        ),
      ).toHaveLength(18);
      const { selectionMapping: _oldMapping, ...oldModel } = template(4).model;
      const { selectionMapping: _newMapping, ...newModel } = profile.model;
      expect(newModel).toEqual(oldModel);
      expect({ ...profile, model: undefined }).toEqual({
        ...template(4),
        model: undefined,
      });
      expect(
        db
          .prepare(
            "SELECT profile_json FROM worker_profile_history WHERE worker_type_id = 'gemini' AND revision = ?",
          )
          .get(revision),
      ).toEqual({ profile_json: previous });
      db.exec(migration);
      expect(
        db
          .prepare(
            "SELECT revision FROM worker_profiles WHERE worker_type_id = 'gemini'",
          )
          .get(),
      ).toEqual({ revision: revision + 1 });
      db.prepare(
        "UPDATE worker_profiles SET profile_json = ?, digest = ? WHERE worker_type_id = 'gemini'",
      ).run(previous, "a".repeat(64));
      db.exec(migration);
      expect(
        db
          .prepare(
            "SELECT digest FROM worker_profiles WHERE worker_type_id = 'gemini'",
          )
          .get(),
      ).toEqual({ digest: "a".repeat(64) });
      db.close();
    });
  }
});
