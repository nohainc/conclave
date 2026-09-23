/* global console, process */

import { readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";

const root = "apps/cloud/src";
const forbidden = [
  /@conclave\/providers/,
  /api\.openai\.com/i,
  /api\.anthropic\.com/i,
  /new\s+OpenAI\s*\(/,
  /new\s+Anthropic\s*\(/,
];

async function sourceFiles(path) {
  const metadata = await stat(path);
  if (metadata.isFile()) {
    return /\.(?:ts|tsx|js|mjs)$/.test(path) ? [path] : [];
  }

  const entries = await readdir(path, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    files.push(...(await sourceFiles(join(path, entry.name))));
  }
  return files;
}

const violations = [];
for (const file of await sourceFiles(root)) {
  const contents = await readFile(file, "utf8");
  const lines = contents.split("\n");
  lines.forEach((line, index) => {
    if (forbidden.some((pattern) => pattern.test(line))) {
      violations.push(`${file}:${index + 1}: ${line.trim()}`);
    }
  });
}

if (violations.length > 0) {
  console.error("Cloud execution boundary violation:");
  console.error(violations.join("\n"));
  process.exit(1);
}

console.log(`Cloud execution boundary check passed: ${root}`);
