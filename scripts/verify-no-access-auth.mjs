/* global console, process */

import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";

const roots = [
  "apps",
  "packages",
  "infra",
  "scripts",
  ".github",
  ".env.example",
];
const ignored = [/\.test\./, /(^|\/)test\//, /worker-configuration\.d\.ts$/];
const retiredApplicationAuth = [
  /CF_Authorization/i,
  /Cf-Access-Jwt-Assertion/i,
  /cf-access-authenticated-user-email/i,
  /CONCLAVE_ACCESS_/i,
  /accessSecurityContext/i,
  /Cloudflare Access authentication required/i,
];

const files = execFileSync("git", ["ls-files", "--", ...roots], {
  encoding: "utf8",
})
  .trim()
  .split("\n")
  .filter(Boolean)
  .filter((file) => !ignored.some((pattern) => pattern.test(file)));

const violations = [];
for (const file of files) {
  const text = await readFile(file, "utf8");
  for (const pattern of retiredApplicationAuth) {
    if (pattern.test(text)) violations.push(`${file}: ${pattern}`);
  }
}

if (violations.length > 0) {
  console.error("Retired Cloudflare Access application-auth markers found:");
  console.error(violations.join("\n"));
  process.exit(1);
}

console.log(
  "Cloudflare Access application-auth guard passed: no active markers found.",
);
