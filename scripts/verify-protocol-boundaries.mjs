import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

const boundaryDocPath = "docs/architecture/PROTOCOL_BOUNDARIES.md";
const boundaryDoc = readFileSync(boundaryDocPath, "utf8");

const requiredContractText = [
  "## 1. AX ↔ Cloud — Human Product Protocol",
  "## 2. Workspace ↔ Cloud — Workspace Runtime Protocol",
  "## 3. Workspace ↔ CLI Worker Engine — Local Worker Protocol 4.0",
  "AX MUST NOT open a Workspace Runtime Protocol connection",
  "CLI Worker Engine process",
  "Local Worker Protocol 4.0: implemented by the Workspace supervisor",
  "## Shared canonical domain vocabulary",
  "`WorkspaceId`",
  "`WorkspaceRuntimeId`",
  "`WorkerId`",
  "`WorkerTypeId`",
  "`AssignmentId`",
  "`RunId`",
  "`TaskId`",
  "`WorkerReadiness`",
  "`AssignmentStatus`",
  "`ErrorCode`",
  "These are canonical domain concepts, not a shared message envelope.",
  "apps/app/lib/src/ax/ax_data.dart",
  "apps/cloud/src/workspace-gateway.ts",
  "apps/host/lib/worker_executor.dart",
];

const missingContractText = requiredContractText.filter(
  (required) => !boundaryDoc.includes(required),
);

const trackedFiles = execFileSync("git", ["ls-files", "-z"], {
  encoding: "utf8",
})
  .split("\0")
  .filter(Boolean);

const sourceFiles = trackedFiles
  .filter((file) => existsSync(file))
  .filter((file) => /\.(?:dart|ts|tsx|js|mjs|json)$/.test(file));

const violations = missingContractText.map(
  (required) =>
    `${boundaryDocPath}: missing required boundary statement: ${required}`,
);

const axRuntimeProtocolPattern =
  /conclave\.workspace-runtime-protocol|workspaceRuntimeProtocol|WorkspaceRuntimeMessage|workspace-runtime\.ts|@conclave\/host-protocol/i;
const firstPartyProviderPackagePattern = /\b(?:codex|antigravity)\b/i;

for (const file of sourceFiles) {
  const contents = readFileSync(file, "utf8");

  if (
    file.startsWith("apps/app/lib/") &&
    axRuntimeProtocolPattern.test(contents)
  ) {
    violations.push(
      `${file}: AX source references the Workspace Runtime Protocol`,
    );
  }

  if (
    file.startsWith("apps/app/lib/") &&
    firstPartyProviderPackagePattern.test(contents)
  ) {
    violations.push(
      `${file}: AX source references a first-party provider package ID`,
    );
  }

  if (
    [
      "apps/cloud/src/assignment-dispatcher.ts",
      "apps/cloud/src/scheduler.ts",
    ].includes(file) &&
    firstPartyProviderPackagePattern.test(contents)
  ) {
    violations.push(
      `${file}: Cloud assignment selection/dispatch references a provider package ID`,
    );
  }
}

if (violations.length > 0) {
  console.error("Protocol boundary architecture check failed:");
  for (const violation of violations) console.error(`- ${violation}`);
  process.exit(1);
}

console.log(
  "Protocol boundary architecture check passed: endpoint ownership is explicit, and Cloud assignments, AX, Workspace, and the CLI Worker Engine use their owned protocol boundaries.",
);
