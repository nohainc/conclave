import { readFileSync, readdirSync, existsSync } from "node:fs";

const failures = [];

function readRequired(file) {
  if (!existsSync(file)) {
    failures.push(`Required v8 architecture file is missing: ${file}`);
    return "";
  }
  return readFileSync(file, "utf8");
}

const assignment = readRequired("apps/host/lib/worker_executor.dart");
const runtime = readRequired("apps/host/lib/workspace_runtime.dart");
const schema = readRequired("apps/cloud/migrations-v8/0001_conclave_v8.sql");
const cloudWrangler = readRequired("apps/cloud/wrangler.jsonc");
const infraWrangler = readRequired("infra/cloudflare/app.wrangler.jsonc");
const packageJson = JSON.parse(readRequired("package.json") || "{}");
const ci = readRequired(".github/workflows/ci.yml");

const sourceRoots = [
  "apps/cloud/src",
  "apps/cloud/migrations-v8",
  "apps/host/lib",
  "apps/app/lib",
  "engines/cli_worker/lib",
  "packages/core/src",
  "packages/protocol/src",
  "packages/host-protocol/src",
  "packages/dart/protocol/lib",
  "packages/security/src",
  "packages/tool-profile/src",
  "workers/fixture_cli/lib",
].filter(existsSync);
const sourceExtensions = new Set([
  ".dart",
  ".json",
  ".js",
  ".mjs",
  ".sql",
  ".ts",
  ".yaml",
  ".yml",
]);
const forbiddenArchitecture = [
  ["V7Adapter", /V7Adapter/],
  ["FirstPartyWorkerPackage", /FirstPartyWorkerPackage/],
  ["worker_releases", /worker_releases/i],
  ["worker_versions", /worker_versions/i],
  ["credential_profiles", /credential_profiles/i],
  ["ai_accounts", /ai_accounts/i],
  ["host_workspace_bindings", /host_workspace_bindings/i],
  ["AgentEngine", /AgentEngine/],
  ["workerPlugin", /workerPlugin/i],
  [
    "provider-specific Worker executable",
    /provider-specific\s+Worker\s+executable/i,
  ],
];

function* sourceFiles(directory) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = `${directory}/${entry.name}`;
    if (entry.isDirectory()) yield* sourceFiles(path);
    else if (sourceExtensions.has(path.slice(path.lastIndexOf("."))))
      yield path;
  }
}

for (const root of sourceRoots) {
  for (const path of sourceFiles(root)) {
    const source = readFileSync(path, "utf8");
    for (const [label, pattern] of forbiddenArchitecture) {
      if (pattern.test(source)) {
        failures.push(`${path} retains retired architecture reference ${label}.`);
      }
    }
  }
}

const requiredAssignment = [
  ["logical Worker resolution", /resolveLogicalWorker/],
  ["Tool Profile assignment executor", /executeWithToolProfile/],
  [
    "required Profile resolution",
    /ToolProfileResolver\(toolProfileReleaseStore\)/,
  ],
  ["CLI Worker Engine execution", /supervisor\.execute\(/],
];
for (const [label, pattern] of requiredAssignment) {
  if (!pattern.test(assignment) && !pattern.test(runtime)) {
    failures.push(`Workspace assignment path is missing ${label}.`);
  }
}

for (const [label, source] of [
  ["Workspace assignment handler", assignment],
  ["Workspace runtime", runtime],
]) {
  if (
    /resolveV7Adapter|V7AdapterPackageStore|WorkerProcessExecutor/.test(source)
  ) {
    failures.push(`${label} references a retired assignment executor.`);
  }
}

for (const [label, config] of [
  ["Cloud Wrangler configuration", cloudWrangler],
  ["production Wrangler configuration", infraWrangler],
]) {
  if (
    !/["']?migrations_dir["']?\s*:\s*["'][^"']*migrations-v8["']/.test(config)
  ) {
    failures.push(`${label} must select migrations-v8.`);
  }
}

for (const table of [
  "worker_scheduling",
  "worker_scheduling_audit",
  "workspace_releases",
  "tool_profile_releases",
]) {
  if (
    !new RegExp(`CREATE TABLE (?:IF NOT EXISTS )?${table}\\b`, "i").test(schema)
  ) {
    failures.push(`The v8 schema is missing ${table}.`);
  }
}
for (const retiredName of [
  "v7_worker_scheduling",
  "v7_worker_scheduling_audit",
  "host_releases",
  "worker_releases",
  "worker_versions",
  "credential_profiles",
  "ai_accounts",
  "host_workspace_bindings",
]) {
  if (schema.includes(retiredName)) {
    failures.push(`The v8 schema retains historical name ${retiredName}.`);
  }
}

const scripts = packageJson.scripts ?? {};
if (!scripts["v8:architecture-check"]) {
  failures.push("package.json must expose v8:architecture-check.");
}
for (const step of ["pnpm v8:architecture-check", "pnpm build", "pnpm test"]) {
  if (!scripts.check?.includes(step)) {
    failures.push(`pnpm check must include ${step}.`);
  }
}
for (const name of Object.keys(scripts)) {
  if (/^(?:v5:workspace-terminology|v6:|v7:)/.test(name)) {
    failures.push(
      `package.json retains a historical architecture check: ${name}.`,
    );
  }
}
for (const job of [
  "engine-tests",
  "profile-fixture-tests",
  "profile-security-tests",
  "workspace-runtime-tests",
  "v8-runtime-e2e",
  "work-v1-e2e",
]) {
  if (!new RegExp(`^  ${job}:`, "m").test(ci)) {
    failures.push(`CI is missing the current architecture job ${job}.`);
  }
}
if (/v7-runtime-e2e|worker-adapters:test|v4-architecture-guard/.test(ci)) {
  failures.push("CI retains a historical runtime or architecture gate.");
}

if (failures.length > 0) {
  console.error("Architecture v8 guard failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log("Architecture v8 guard passed.");
