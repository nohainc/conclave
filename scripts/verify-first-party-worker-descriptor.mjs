import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

const descriptorPath =
  "apps/host/lib/first_party_worker_adapter_descriptor.dart";
const descriptor = readFileSync(descriptorPath, "utf8");
const expectedMappings = [
  [
    "productWorkerTypeId: 'chatgpt'",
    "productName: 'ChatGPT'",
    "adapterPackageId: 'codex'",
    "executableCandidates: ['codex']",
  ],
  [
    "productWorkerTypeId: 'gemini'",
    "productName: 'Gemini'",
    "adapterPackageId: 'antigravity'",
    "executableCandidates: ['agy']",
  ],
];
const violations = [];

for (const mapping of expectedMappings) {
  const missing = mapping.filter((field) => !descriptor.includes(field));
  if (missing.length) {
    violations.push(
      `${descriptorPath}: descriptor is missing mapping fields: ${missing.join(", ")}`,
    );
  }
}

const trackedFiles = execFileSync(
  "git",
  ["ls-files", "-z", "--", "apps/host/lib"],
  {
    encoding: "utf8",
  },
)
  .split("\0")
  .filter(Boolean);
const untrackedFiles = execFileSync(
  "git",
  ["ls-files", "--others", "--exclude-standard", "--", "apps/host/lib"],
  { encoding: "utf8" },
)
  .split("\n")
  .filter(Boolean);
const hostSources = [...new Set([...trackedFiles, ...untrackedFiles])]
  .filter((file) => file !== descriptorPath && existsSync(file))
  .filter((file) => file.endsWith(".dart"));
const scatteredImplementationId = /['"](?:codex|antigravity|agy)['"]/;

for (const file of hostSources) {
  if (scatteredImplementationId.test(readFileSync(file, "utf8"))) {
    violations.push(
      `${file}: first-party adapter or executable ID is outside the descriptor registry`,
    );
  }
}

if (violations.length) {
  console.error("First-party Worker descriptor check failed:");
  for (const violation of violations) console.error(`- ${violation}`);
  process.exit(1);
}

console.log(
  "First-party Worker descriptor check passed: ChatGPT and Gemini implementation IDs are centralized in one Workspace registry.",
);
