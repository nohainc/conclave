import { createHash } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";
import { expect, it } from "vitest";

const directory = fileURLToPath(new URL("../migrations-v8/", import.meta.url));
const sql = (name: string) => readFileSync(`${directory}/${name}`, "utf8");
const revert = sql("0052_revert_gemini_model_mapping_changes.sql");
const hash = (value: string) =>
  createHash("sha256").update(value).digest("hex");

for (const [forward, original] of [
  [
    "0050_add_claude_gpt_model_selection.sql",
    "0048_gemini_publish_all_cli_models.sql",
  ],
  ["0051_agy_live_activity_combined_models.sql", null],
] as const) {
  it(`reverses ${forward} exactly, retaining history and other Workers`, () => {
    const db = new DatabaseSync(":memory:");
    for (const name of readdirSync(directory)
      .filter((name) => name.endsWith(".sql") && name < "0050")
      .sort())
      db.exec(sql(name));
    const profile = original
      ? sql(original).match(/SET profile_json = '(.*?)',/)![1]
      : JSON.stringify(
          JSON.parse(
            readFileSync(
              fileURLToPath(
                new URL(
                  "../../../docs/profile-templates/gemini-antigravity-runtime-catalog.live-activity-v4.json",
                  import.meta.url,
                ),
              ),
              "utf8",
            ),
          ),
          (_, value) =>
            value && typeof value === "object" && !Array.isArray(value)
              ? Object.fromEntries(
                  Object.keys(value)
                    .sort()
                    .map((key) => [key, value[key]]),
                )
              : value,
        );
    const insert = db.prepare(
      "INSERT INTO worker_profiles (worker_type_id, schema_version, profile_json, revision, digest, updated_at) VALUES (?, 1, ?, 7, ?, '2026-10-13T00:00:00Z')",
    );
    insert.run("gemini", profile, hash(profile));
    insert.run("claude", profile, hash(profile));
    db.exec(sql(forward));
    const read = () =>
      db
        .prepare(
          "SELECT revision, digest, profile_json FROM worker_profiles WHERE worker_type_id='gemini'",
        )
        .get() as any;
    // 0050 admits revision 3 only.
    if (original) {
      db.prepare(
        "UPDATE worker_profiles SET revision=3 WHERE worker_type_id='gemini'",
      ).run();
      db.exec(sql(forward));
    }
    const before = read();
    db.exec(revert);
    expect(read()).toEqual({
      revision: before.revision + 1,
      digest: hash(profile),
      profile_json: profile,
    });
    expect(
      db
        .prepare(
          "SELECT digest FROM worker_profile_history WHERE worker_type_id='gemini' AND revision=?",
        )
        .get(before.revision),
    ).toEqual({ digest: before.digest });
    expect(
      db
        .prepare(
          "SELECT revision FROM worker_profiles WHERE worker_type_id='claude'",
        )
        .get(),
    ).toEqual({ revision: 7 });
    const restored = read();
    db.exec(revert);
    expect(read()).toEqual(restored);
    db.prepare(
      "UPDATE worker_profiles SET digest=? WHERE worker_type_id='gemini'",
    ).run("a".repeat(64));
    db.exec(revert);
    expect(read().digest).toBe("a".repeat(64));
    // Even an exact forward digest cannot restore when its source history is absent.
    db.prepare(
      "DELETE FROM worker_profile_history WHERE worker_type_id='gemini' AND digest=?",
    ).run(hash(profile));
    db.prepare(
      "UPDATE worker_profiles SET digest=? WHERE worker_type_id='gemini'",
    ).run(before.digest);
    db.exec(revert);
    expect(read().digest).toBe(before.digest);
    db.close();
  });
}
