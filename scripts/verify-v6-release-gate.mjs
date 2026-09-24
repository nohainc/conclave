/* global console, process */
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";

const root = process.cwd();
const failures = [];

function run(label, command, args, cwd = root) {
  console.log(`\n[V6 gate] ${label}`);
  const result = spawnSync(command, args, {
    cwd,
    stdio: "inherit",
    env: process.env,
  });
  if (result.error || result.status !== 0) {
    failures.push(`${label}${result.error ? `: ${result.error.message}` : ""}`);
  }
}

run("TypeScript build", "npm", ["run", "build"]);
run(
  "Solo, team, and recovery acceptance",
  "npx",
  [
    "vitest",
    "run",
    "packages/core/test/v6-clean-room-acceptance.test.ts",
    "packages/core/test/v6-team-concurrency-acceptance.test.ts",
    "apps/cloud/test/v6-clean-room-solo-acceptance.test.ts",
    "apps/cloud/test/v6-schema.test.ts",
    "apps/cloud/test/v5-scheduler.test.ts",
  ],
);
run("Protocol generation and consistency", "npm", ["run", "protocol:check"]);
run("V6 architecture search gate", "npm", ["run", "v6:architecture-gate"]);
run("V6 convergence gate", "npm", ["run", "v6:convergence"]);
run("Documentation consistency", "npm", ["run", "docs:check"]);
run("Cloudflare production preflight", "npm", [
  "run",
  "production:preflight",
  "--",
  "infra/cloudflare/app.wrangler.jsonc",
]);

const flutter = process.env.FLUTTER_BIN ?? "flutter";
if (process.env.V6_SKIP_FLUTTER === "1") {
  console.warn("\n[V6 gate] Flutter checks skipped by V6_SKIP_FLUTTER=1");
} else {
  run("Flutter Studio UI acceptance", flutter, ["test", "test/projects_pages_test.dart"], join(root, "apps/app"));
  run(
    "macOS Workspace runtime acceptance",
    flutter,
    ["test", "test/workstream_checkout_manager_test.dart", "test/runtime_capabilities_test.dart", "test/trust_policy_test.dart"],
    join(root, "apps/host"),
  );
}

if (process.env.V6_REQUIRE_PLATFORM_MATRIX === "1" && process.env.V6_PLATFORM_MATRIX !== "passed") {
  failures.push("Windows/Linux compile matrix is required; run it in CI and set V6_PLATFORM_MATRIX=passed");
} else {
  console.warn("\n[V6 gate] Windows/Linux compile matrix is an external CI requirement");
}

if (failures.length) {
  console.error("\nV6 release gate failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}
console.log("\nV6 local release gate passed; external Windows/Linux matrix remains required in CI.");
