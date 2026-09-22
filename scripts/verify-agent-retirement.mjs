import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const trackedFiles = execFileSync("git", ["ls-files", "-z"], {
  encoding: "utf8",
})
  .split("\0")
  .filter(Boolean);

const codeFiles = trackedFiles.filter((file) =>
  /\.(?:ts|tsx|js|mjs|json|yaml|yml)$/.test(file),
);
const legacyPatterns = [
  /(?:^|["'`])(?:\.\/)?apps\/agent(?:[\/"'`]|$)/,
  /(?:^|["'`])(?:\.\/)?packages\/agent(?:[\/"'`]|$)/,
];
const violations = [];

for (const file of codeFiles) {
  const contents = readFileSync(file, "utf8");
  for (const pattern of legacyPatterns) {
    if (pattern.test(contents)) {
      violations.push(`${file}: ${pattern}`);
    }
  }
}

if (violations.length > 0) {
  console.error("Retired TypeScript Agent references found:");
  for (const violation of violations) console.error(`- ${violation}`);
  process.exit(1);
}

console.log(
  "Agent retirement check passed: no legacy TypeScript Agent imports.",
);
