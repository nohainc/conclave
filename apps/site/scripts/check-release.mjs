import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";

const dist = new URL("../dist/", import.meta.url).pathname;
const requiredFiles = [
  "index.html",
  "404.html",
  "how-it-works/index.html",
  "workers/index.html",
  "security/index.html",
  "privacy/index.html",
  "terms/index.html",
  "favicon.svg",
  "social-preview.svg",
  "social-preview.png",
  "site.webmanifest",
  "robots.txt",
  "sitemap.xml",
];
const forbidden = /\b(?:studio|plugin|agent)\b/i;
const errors = [];

for (const file of requiredFiles) {
  try {
    await readFile(join(dist, file));
  } catch {
    errors.push(`missing release artifact: ${file}`);
  }
}

/** @param {string} directory @returns {Promise<string[]>} */
async function htmlFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...(await htmlFiles(path)));
    else if (path.endsWith(".html")) files.push(path);
  }
  return files;
}

for (const file of await htmlFiles(dist)) {
  const source = await readFile(file, "utf8");
  if (forbidden.test(source)) {
    errors.push(
      `${file.replace(`${dist}/`, "")}: legacy product terminology found`,
    );
  }
}

const home = await readFile(join(dist, "index.html"), "utf8");
const requiredHomepageContent = [
  "Build with a team of AI Workers.",
  "Why Conclave AX",
  "How it works",
  "Conclave Host",
  "Accounts and privacy",
  "Quality and verification",
  "Open Conclave AX",
];
for (const content of requiredHomepageContent) {
  if (!home.includes(content))
    errors.push(`homepage: missing release content: ${content}`);
}
if ((home.match(/href="https:\/\/app\.conclaveax\.com/g) ?? []).length < 4) {
  errors.push("homepage: expected direct app CTA links");
}
for (const link of ["/privacy/", "/terms/", "/security/"]) {
  if (!home.includes(`href="${link}"`))
    errors.push(`homepage: missing footer link ${link}`);
}

const workerSource = await readFile(
  new URL("../src/worker.ts", import.meta.url),
  "utf8",
);
for (const marker of [
  "www.conclaveax.com",
  "conclaveax.com",
  "308",
  "location",
]) {
  if (!workerSource.includes(marker))
    errors.push(`deployment: missing ${marker} redirect contract`);
}

if (errors.length)
  throw new Error(`Landing-page release gate failed:\n${errors.join("\n")}`);
console.log(
  "Landing-page release gate passed: required routes, content, terminology, metadata artifacts, and domain redirect contract verified.",
);
