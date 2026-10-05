import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export function qualificationProvisioningSql(baseline) {
  const start = baseline.indexOf(
    "CREATE TABLE tool_profile_local_qualification_evidence (",
  );
  const end = baseline.indexOf(
    "CREATE INDEX idx_tool_profile_acceptance_evidence_release",
    start,
  );
  if (start < 0 || end < 0)
    throw new Error("Qualification baseline definition not found");
  return baseline
    .slice(start, end)
    .replaceAll("CREATE TABLE ", "CREATE TABLE IF NOT EXISTS ")
    .replaceAll("CREATE INDEX ", "CREATE INDEX IF NOT EXISTS ")
    .replaceAll("CREATE TRIGGER ", "CREATE TRIGGER IF NOT EXISTS ");
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const root = new URL("../", import.meta.url);
  mkdirSync(new URL(".development/", root), { recursive: true });
  writeFileSync(
    new URL(".development/provision-profile-qualification.sql", root),
    qualificationProvisioningSql(
      readFileSync(
        new URL("apps/cloud/migrations-v8/0001_conclave_v8.sql", root),
        "utf8",
      ),
    ),
  );
  console.log(
    "Prepared additive qualification evidence provisioning; existing Drafts and releases are preserved.",
  );
}
