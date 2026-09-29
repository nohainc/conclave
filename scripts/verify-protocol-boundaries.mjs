import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

const boundaryDocPath = "docs/architecture/PROTOCOL_BOUNDARIES.md";
const boundaryDoc = readFileSync(boundaryDocPath, "utf8");

const requiredContractText = [
  "## 1. AX ↔ Cloud — Human Product Protocol",
  "## 2. Workspace ↔ Cloud — Workspace Runtime Protocol",
  "## 3. Workspace ↔ Adapter — Local Adapter Protocol",
  "AX MUST NOT open a Workspace Runtime Protocol connection",
  "Worker adapters are\nnot runtime clients and MUST NOT connect to Cloud",
  "adapter child process",
  "Workspace Runtime Protocol frame",
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
  "apps/app/lib/src/studio/studio_data.dart",
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
const adapterCloudProtocolPattern =
  /conclave\.workspace-runtime-protocol|workspaceRuntimeProtocol|WorkspaceRuntimeMessage|workspace-runtime\.ts|@conclave\/host-protocol|apps\/cloud\/(?:api|workspace-gateway)|conclaveCloud(?:Url|Origin|BaseUrl)?|cloudGateway|workspaceRuntimeCredential/i;
const firstPartyAdapterPackagePattern = /\b(?:codex|antigravity)\b/i;

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
    firstPartyAdapterPackagePattern.test(contents)
  ) {
    violations.push(
      `${file}: AX source references a first-party adapter package ID`,
    );
  }

  if (
    [
      "apps/cloud/src/assignment-dispatcher.ts",
      "apps/cloud/src/v7-scheduler.ts",
    ].includes(file) &&
    firstPartyAdapterPackagePattern.test(contents)
  ) {
    violations.push(
      `${file}: Cloud assignment selection/dispatch references an adapter package ID`,
    );
  }

  if (
    file.startsWith("packages/worker-manifest/adapters/") &&
    !file.includes("/test/") &&
    adapterCloudProtocolPattern.test(contents)
  ) {
    violations.push(
      `${file}: adapter source references a Cloud/runtime protocol`,
    );
  }
}

if (violations.length > 0) {
  console.error("Protocol boundary architecture check failed:");
  for (const violation of violations) console.error(`- ${violation}`);
  process.exit(1);
}

console.log(
  "Protocol boundary architecture check passed: endpoint ownership is explicit, Cloud assignments and AX use product Worker Types, and adapters do not reference Cloud/runtime protocols.",
);
