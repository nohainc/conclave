import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// Adopt the authoring-only addition from the fresh v8 baseline without replaying
// that baseline, overwriting templates, or touching existing Draft/release rows.
export function starterTemplateProvisioningSql(
  baseline,
  starterAlignment = "",
) {
  const table = baseline.match(
    /CREATE TABLE tool_profile_starter_templates \([\s\S]*?\n\);/,
  );
  const seeds = baseline
    .split("\n")
    .filter((line) =>
      line.startsWith("INSERT OR IGNORE INTO tool_profile_starter_templates "),
    );
  if (!table || seeds.length !== 2)
    throw new Error(
      "Current baseline starter-template definition/seeds were not found.",
    );
  return `${table[0].replace("CREATE TABLE ", "CREATE TABLE IF NOT EXISTS ")}\n${seeds.join("\n")}\n${starterAlignment}`;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const root = fileURLToPath(new URL("../", import.meta.url));
  const file = join(
    root,
    ".development/provision-profile-starter-templates.sql",
  );
  const baseline = readFileSync(
    join(root, "apps/cloud/migrations-v8/0001_conclave_v8.sql"),
    "utf8",
  );
  mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
  writeFileSync(
    file,
    starterTemplateProvisioningSql(
      baseline,
      [
        "0007_chat_profile_starter_attestation.sql",
        "0008_codex_compatibility_approval_policy.sql",
        "0017_chatgpt_starter_model_catalog.sql",
        "0030_gemini_model_discovery_starter.sql",
        "0034_runtime_model_catalog_starters.sql",
        "0035_codex_app_server_model_discovery.sql",
        "0038_gemini_combined_model_selection.sql",
        "0041_full_local_access_profile_mappings.sql",
      ]
        .map((name) =>
          readFileSync(join(root, "apps/cloud/migrations-v8", name), "utf8"),
        )
        .join("\n"),
      // The provisioning script intentionally creates only the starter-table
      // subset. Apply the Profile cleanup here without replaying the full
      // capability-column migration against unrelated tables.
      `UPDATE tool_profile_starter_templates
       SET profile_json = json_remove(profile_json, '$.capabilities')
       WHERE json_valid(profile_json) = 1;`,
    ),
  );
  console.log(
    "Prepared .development/provision-profile-starter-templates.sql from the v8 baseline; existing templates, Drafts, and releases are preserved.",
  );
}
