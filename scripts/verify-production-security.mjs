/* global console, process */

import { readFile } from "node:fs/promises";

const configPath = process.argv[2] ?? "infra/cloudflare/app.wrangler.jsonc";
const config = await readFile(configPath, "utf8");

const isForgeService = configPath.includes("forge-execution");
const required = isForgeService
  ? [
      ["production environment", /"CONCLAVE_ENVIRONMENT"\s*:\s*"production"/],
      ["D1 binding", /"binding"\s*:\s*"CONCLAVE_DB"/],
      ["R2 artifact binding", /"binding"\s*:\s*"CONCLAVE_ARTIFACTS"/],
      ["Cloud API service binding", /"binding"\s*:\s*"CONCLAVE_API"/],
    ]
  : [
      ["production environment", /"CONCLAVE_ENVIRONMENT"\s*:\s*"production"/],
      ["Studio custom domain", /"pattern"\s*:\s*"app\.conclaveax\.com"/],
      ["D1 binding", /"binding"\s*:\s*"CONCLAVE_DB"/],
      ["R2 artifact binding", /"binding"\s*:\s*"CONCLAVE_ARTIFACTS"/],
      ["Forge service binding", /"binding"\s*:\s*"CONCLAVE_FORGE_EXECUTION"/],
      ["Workflow binding", /"binding"\s*:\s*"CONCLAVE_RUN_WORKFLOW"/],
      ["Workspace Gateway binding", /"name"\s*:\s*"CONCLAVE_WORKSPACE_GATEWAY"/],
    ];

const missing = required
  .filter(([, pattern]) => !pattern.test(config))
  .map(([name]) => name);
if (missing.length > 0) {
  throw new Error(
    `Production security preflight failed: ${missing.join(", ")}`,
  );
}

const developmentResourceNames = [
  ["D1 database", /"database_name"\s*:\s*"[^"]*development[^"]*"/i],
  ["R2 artifact bucket", /"bucket_name"\s*:\s*"[^"]*development[^"]*"/i],
].filter(([, pattern]) => pattern.test(config));
if (developmentResourceNames.length > 0) {
  throw new Error(
    `Production security preflight failed: development resource names are configured (${developmentResourceNames.map(([name]) => name).join(", ")})`,
  );
}

if (/CONCLAVE_ALLOW_ANONYMOUS_DEV/.test(config)) {
  throw new Error(
    "Production security preflight failed: anonymous development access is configured",
  );
}

console.log(`Production security preflight passed: ${configPath}`);
