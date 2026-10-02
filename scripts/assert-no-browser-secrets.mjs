import { readdir, readFile } from "node:fs/promises";
import { join, relative, resolve } from "node:path";

const root = process.argv[2];
if (!root) throw new Error("A directory to scan is required");

const rootPath = resolve(root);
const findings = [];
const secretPatterns = [
  ["private key", /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/],
  ["OpenAI-style API key", /\bsk-[A-Za-z0-9_-]{20,}\b/],
  [
    "GitHub token",
    /\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b/,
  ],
  ["Google API key", /\bAIza[0-9A-Za-z_-]{35}\b/],
  ["AWS access key", /\bAKIA[0-9A-Z]{16}\b/],
  ["Slack token", /\bxox[baprs]-[A-Za-z0-9-]{20,}\b/],
  [
    "secret assigned to a browser-visible setting",
    /\b(?:VITE|NEXT_PUBLIC|PUBLIC|ASTRO)_[A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|API_KEY|PRIVATE_KEY)[A-Z0-9_]*\s*[:=]\s*["'`]?(?!\$\{)[A-Za-z0-9_./+=-]{8,}/i,
  ],
];

const environmentSecrets = Object.entries(process.env)
  .filter(
    ([name, value]) =>
      /(?:secret|token|password|api[_-]?key|private[_-]?key|signing[_-]?seed)/i.test(
        name,
      ) &&
      typeof value === "string" &&
      value.length >= 8,
  )
  .map(([name, value]) => [name, value]);

async function scan(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      await scan(path);
      continue;
    }
    if (!entry.isFile()) continue;

    const content = await readFile(path, "utf8");
    const displayPath = relative(rootPath, path) || entry.name;
    for (const [label, pattern] of secretPatterns) {
      if (pattern.test(content)) findings.push(`${displayPath}: ${label}`);
    }
    for (const [name, value] of environmentSecrets) {
      if (content.includes(value)) {
        findings.push(
          `${displayPath}: value from secret environment variable ${name}`,
        );
      }
    }
  }
}

await scan(rootPath);
if (findings.length > 0) {
  throw new Error(
    `Browser bundle secret scan failed:\n${findings.map((item) => `  ${item}`).join("\n")}`,
  );
}

console.log(`Browser bundle secret scan passed: ${rootPath}`);
