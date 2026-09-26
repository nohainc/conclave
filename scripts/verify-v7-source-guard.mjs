import { execFileSync } from "node:child_process";
import fs from "node:fs";

const sourceRoots = [
  "apps/app/lib",
  "apps/cloud/src",
  "apps/host/lib",
  "packages",
];
const workingDiff = execFileSync(
  "git",
  ["diff", "--unified=0", "HEAD", "--", ...sourceRoots],
  { encoding: "utf8" },
);
let committedDiff = "";
try {
  committedDiff = execFileSync(
    "git",
    ["diff", "--unified=0", "HEAD^", "HEAD", "--", ...sourceRoots],
    { encoding: "utf8" },
  );
} catch {
  // A shallow/single-commit checkout still gets working-tree protection.
}
const diff = `${committedDiff}\n${workingDiff}`;
const additions = diff
  .split("\n")
  .filter((line) => line.startsWith("+") && !line.startsWith("+++"))
  .map((line) => line.slice(1));
const untracked = execFileSync(
  "git",
  ["ls-files", "--others", "--exclude-standard", "--", ...sourceRoots],
  { encoding: "utf8" },
)
  .split("\n")
  .filter(Boolean)
  .flatMap((file) => fs.readFileSync(file, "utf8").split("\n"));
additions.push(...untracked);

const forbidden = [
  [
    "multi-Workspace Worker binding UX",
    /connect existing worker|remove worker binding|attach worker to workspace/i,
  ],
  [
    "Cloud-side Add Worker flow",
    /add worker.{0,40}(?:cloud|conclave ax)|(?:cloud|conclave ax).{0,40}add worker/i,
  ],
  [
    "AI Account peer resource",
    /\b(?:create|add|manage)\s+(?:an?\s+)?ai account\b/i,
  ],
  [
    "model-specific Worker Type",
    /workerType(?:Id|Name)?\s*[:=]\s*["'`](?:gpt[- ]?\d|gemini[- ]?(?:pro|flash)|claude[- ]?(?:sonnet|opus|haiku))/i,
  ],
];

const violations = [];
for (const line of additions) {
  for (const [label, pattern] of forbidden) {
    if (pattern.test(line)) violations.push(`${label}: ${line.trim()}`);
  }
}

if (violations.length) {
  console.error("V7 source guard failed:");
  for (const violation of violations) console.error(`- ${violation}`);
  process.exit(1);
}
console.log("V7 source guard passed.");
