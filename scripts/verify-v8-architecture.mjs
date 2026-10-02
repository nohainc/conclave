import { readFileSync, readdirSync, existsSync } from "node:fs";

const failures = [];

if (existsSync("workers")) {
  failures.push("The retired top-level workers/ runtime tree must be absent.");
}

function readRequired(file) {
  if (!existsSync(file)) {
    failures.push(`Required v8 architecture file is missing: ${file}`);
    return "";
  }
  return readFileSync(file, "utf8");
}

const assignment = readRequired("apps/host/lib/worker_executor.dart");
const runtime = readRequired("apps/host/lib/workspace_runtime.dart");
const architecture = readRequired("ARCHITECTURE.md");
const architectureV8 = readRequired("docs/architecture/ARCHITECTURE_V8.md");
const schema = readRequired("apps/cloud/migrations-v8/0001_conclave_v8.sql");
const appRouter = readRequired("apps/cloud/src/routes/router.ts");
const axData = readRequired("apps/app/lib/src/ax/ax_data.dart");
const cloudWrangler = readRequired("apps/cloud/wrangler.jsonc");
const infraWrangler = readRequired("infra/cloudflare/app.wrangler.jsonc");
const packageJson = JSON.parse(readRequired("package.json") || "{}");
const ci = readRequired(".github/workflows/ci.yml");
const deploy = readRequired(".github/workflows/deploy-app.yml");
const cloudPackage = JSON.parse(
  readRequired("apps/cloud/package.json") || "{}",
);
const workspacePackages = readRequired("pnpm-workspace.yaml");
const lockfile = readRequired("pnpm-lock.yaml");
const wranglerTypes = readRequired("apps/cloud/worker-configuration.d.ts");

const canonicalExecutionPath =
  "AX → Cloud → Workspace → CLI Worker Engine → signed Tool Profile → provider CLI";
const architectureProhibitions = [
  [
    "provider-specific Worker executable",
    "provider_specific_worker_executable: true",
  ],
  ["browser/Web AI Worker", "browser_or_web_ai_worker: true"],
  ["Interactive Connector", "interactive_connector: true"],
  [
    "Conclave-managed provider credentials",
    "conclave_managed_provider_credentials: true",
  ],
  ["Agent/Host runtime", "agent_or_host_runtime: true"],
  ["ConfiguredWorker product entity", "configured_worker_product_entity: true"],
  [
    "pre-v8 Goal/Phase/Task orchestration",
    "pre_v8_goal_phase_task_orchestration: true",
  ],
  [
    "compatibility API for unreleased architectures",
    "compatibility_api_for_unreleased_architecture: true",
  ],
];

if (!architecture.includes(canonicalExecutionPath)) {
  failures.push("ARCHITECTURE.md must state the canonical v8 execution path.");
}
if (
  !architecture.includes(
    "docs/architecture/ARCHITECTURE_V8.md#architecture-contract",
  )
) {
  failures.push(
    "ARCHITECTURE.md must link to the normative v8 architecture contract.",
  );
}
if (!architectureV8.includes(canonicalExecutionPath)) {
  failures.push("Architecture v8 must state the canonical v8 execution path.");
}
for (const [label, declaration] of architectureProhibitions) {
  if (!architectureV8.includes(declaration)) {
    failures.push(`Architecture v8 is missing exclusion: ${label}.`);
  }
}

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
  ["Studio AX naming", /\bStudio\w*\b|\/studio\//i],
  ["Studio snapshot API", /\/api\/studio\/snapshot/i],
  ["compatibility Project read model", /\/read-model\b/i],
  ["legacy snapshot API client", /\bloadSnapshot\s*\(/],
  ["V7Adapter", /V7Adapter/],
  ["FirstPartyWorkerPackage", /FirstPartyWorkerPackage/],
  ["ConfiguredWorker identifier", /\bConfiguredWorker\b|\bconfiguredWorker\w*/],
  ["worker_releases", /worker_releases/i],
  ["worker_versions", /worker_versions/i],
  ["credential_profiles", /credential_profiles/i],
  ["ai_accounts", /ai_accounts/i],
  ["host_workspace_bindings", /host_workspace_bindings/i],
  ["AgentEngine", /AgentEngine/],
  ["workerPlugin", /workerPlugin/i],
  ["Web AI Worker", /\bWebAiWorker\b|web_ai_worker/i],
  ["Interactive Connector", /\bInteractiveConnector\b|interactive-connector/i],
  [
    "Forge orchestration",
    /\bForge(?:Execution|Pipeline)\b|forge-execution|forge-terminal|forge-events/i,
  ],
  ["connector API route", /\/api\/connector\//i],
  ["managed provider credential identity", /\bcredentialProfileId\b/],
  [
    "provider-specific Worker executable",
    /provider-specific\s+Worker\s+executable/i,
  ],
];

if (existsSync("apps/app/lib/src/studio")) {
  failures.push("The AX source tree must use current AX naming, not studio/.");
}
for (const [label, pattern] of forbiddenArchitecture.slice(0, 3)) {
  if (pattern.test(appRouter))
    failures.push(`${label} remains in Cloud routes.`);
}
for (const [label, pattern] of [
  forbiddenArchitecture[0],
  forbiddenArchitecture[1],
  forbiddenArchitecture[3],
]) {
  if (pattern.test(axData))
    failures.push(`${label} remains in the AX API client.`);
}

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
        failures.push(
          `${path} retains retired architecture reference ${label}.`,
        );
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
  "allowed_configured_worker_ids_json",
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
if (!/^ {2}repository-check:/m.test(ci)) {
  failures.push("CI is missing the consolidated repository-check job.");
}
if (
  /engine-tests|profile-fixture-tests|profile-security-tests|workspace-runtime-tests|v8-runtime-e2e|work-v1-e2e|v7-runtime-e2e|worker-adapters:test|v4-architecture-guard/.test(
    ci,
  )
) {
  failures.push("CI retains a historical runtime or architecture gate.");
}
if (!ci.includes("run: pnpm check")) {
  failures.push("CI must run the consolidated pnpm check gate.");
}
if (!deploy.includes("run: pnpm check")) {
  failures.push("The production deployment workflow must pass pnpm check.");
}

for (const check of [
  "pnpm cloud:schema-check",
  "pnpm v8:architecture-check",
  "pnpm protocol:check",
  "pnpm --dir apps/cloud types:check",
  "pnpm format:check",
  "pnpm format:dart:check",
  "pnpm lint",
  "pnpm build",
  "pnpm test",
  "pnpm check:dart-protocol",
  "pnpm check:engine",
  "pnpm check:workspace",
  "pnpm check:ax",
  "pnpm check:fixture-e2e",
]) {
  if (!scripts.check?.includes(check)) {
    failures.push(`pnpm check is missing required validation: ${check}.`);
  }
}
if (
  !/wrangler types --check --config wrangler\.jsonc/.test(
    cloudPackage.scripts?.["types:check"] ?? "",
  )
) {
  failures.push(
    "Cloud must verify generated Wrangler types without rewriting them.",
  );
}
if (!infraWrangler.includes('"name": "CONCLAVE_WORKSTREAM_COORDINATOR"')) {
  failures.push(
    "Production Wrangler configuration is missing the Workstream coordinator binding.",
  );
}
if (!infraWrangler.includes('"class_name": "WorkstreamExecutionCoordinator"')) {
  failures.push(
    "Production Wrangler configuration is missing the Workstream coordinator class.",
  );
}
if (!infraWrangler.includes('"tag": "v8-workstream-coordinator"')) {
  failures.push(
    "Production Wrangler configuration is missing its Workstream coordinator migration.",
  );
}
for (const binding of [
  "CONCLAVE_WORKSPACE_GATEWAY",
  "CONCLAVE_REALTIME_GATEWAY",
  "CONCLAVE_WORKSTREAM_COORDINATOR",
  "CONCLAVE_RUN_WORKFLOW",
]) {
  if (!wranglerTypes.includes(binding)) {
    failures.push(`Generated Wrangler types are missing ${binding}.`);
  }
}
if (
  /CONCLAVE_PLUGIN_PUBLISHER_EMAIL|CONCLAVE_FORGE_EXECUTION|CONCLAVE_FORGE_CALLBACK_TOKEN/.test(
    `${infraWrangler}\n${cloudWrangler}`,
  )
) {
  failures.push(
    "Wrangler configuration retains a retired plugin or Forge binding.",
  );
}
if (
  /forge-execution\.wrangler\.jsonc|forge-execution|CONCLAVE_FORGE_/.test(
    deploy,
  )
) {
  failures.push(
    "Production deployment retains retired Forge deployment configuration.",
  );
}
if (
  /packages\/(?:orchestration|persistence|worker-manifest)/.test(
    workspacePackages,
  )
) {
  failures.push(
    "pnpm workspace still includes a package retained only for retired architecture.",
  );
}
if (
  /packages\/(?:orchestration|persistence|worker-manifest)\//.test(lockfile) ||
  /@conclave\/(?:orchestration|persistence|worker-manifest)/.test(
    `${JSON.stringify(packageJson)}\n${JSON.stringify(cloudPackage)}\n${lockfile}`,
  )
) {
  failures.push(
    "Package manifests or lockfile retain dependencies for retired architecture.",
  );
}
for (const file of [
  "apps/cloud/forge-execution.wrangler.jsonc",
  "packages/orchestration/package.json",
  "packages/persistence/package.json",
  "packages/worker-manifest/package.json",
]) {
  if (existsSync(file))
    failures.push(`Retired package or deployment file remains: ${file}.`);
}

if (failures.length > 0) {
  console.error("Architecture v8 guard failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log("Architecture v8 guard passed.");
