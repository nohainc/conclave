import { readFile } from "node:fs/promises";

const dist = new URL("../dist/", import.meta.url).pathname;
const routes = new Map([
  ["/", "index.html"],
  ["/how-it-works/", "how-it-works/index.html"],
  ["/workers/", "workers/index.html"],
  ["/security/", "security/index.html"],
  ["/privacy/", "privacy/index.html"],
  ["/terms/", "terms/index.html"],
]);

/** @type {Record<string, {title: string, heading: string, content: string[]}>} */
const expected = {
  "/": {
    title: "Conclave AX — Turn team decisions into verified AI work",
    heading: "Turn team decisions into verified AI work.",
    content: ["Workstreams", "Discuss", "Work Request", "Safe parallel work", "Accounts and privacy"],
  },
  "/how-it-works/": {
    title: "How Conclave AX works",
    heading: "From team discussion to a verified result.",
    content: ["Create a Project", "Open a Workstream", "Discuss", "Run a Work Request", "Coordinate", "Verify and continue"],
  },
  "/workers/": {
    title: "Workers — Conclave AX",
    heading: "Treat models and tools as capabilities, not as the whole workflow.",
    content: ["Codex", "Claude Code", "OpenAI", "Anthropic"],
  },
  "/security/": {
    title: "Security — Conclave AX",
    heading: "Share the project without sharing the whole machine.",
    content: ["Project", "Workspace", "Worker", "AI Account"],
  },
  "/privacy/": {
    title: "Privacy — Conclave AX",
    heading: "Privacy follows the same boundaries as the product.",
    content: ["Human identity and Projects", "Workspaces and local execution", "AI Accounts"],
  },
  "/terms/": {
    title: "Terms — Conclave AX",
    heading: "Terms of Service",
    content: ["Connected Workspaces", "Third-party AI providers", "Work outputs"],
  },
};

const errors = [];
const sources = new Map();

for (const [route, file] of routes) {
  const source = await readFile(`${dist}${file}`, "utf8");
  sources.set(route, source);
  const contract = expected[route];
  const title = source.match(/<title>([^<]+)<\/title>/i)?.[1]?.trim();
  const description = source.match(
    /<meta\b[^>]*name="description"[^>]*content="([^"]+)"/i,
  )?.[1];
  const canonical = source.match(
    /<link\b[^>]*rel="canonical"[^>]*href="([^"]+)"/i,
  )?.[1];
  const ogImage = source.match(
    /<meta\b[^>]*property="og:image"[^>]*content="([^"]+)"/i,
  )?.[1];
  const heading = source.match(/<h1\b[^>]*>([\s\S]*?)<\/h1>/i)?.[1];
  const visibleText = source
    .replace(/<script[\s\S]*?<\/script>/gi, "")
    .replace(/<style[\s\S]*?<\/style>/gi, "")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ");

  if (title !== contract.title)
    errors.push(`${route}: title changed or missing`);
  if (!description?.trim()) errors.push(`${route}: description missing`);
  if (!canonical?.startsWith("https://conclaveax.com/"))
    errors.push(`${route}: canonical URL is malformed`);
  if (!ogImage?.startsWith("https://conclaveax.com/"))
    errors.push(`${route}: OpenGraph image URL is malformed`);
  if (!heading?.includes(contract.heading))
    errors.push(`${route}: critical h1 content changed or missing`);
  for (const phrase of contract.content) {
    if (!visibleText.includes(phrase))
      errors.push(`${route}: required content missing: ${phrase}`);
  }
}

const home = sources.get("/");
const appLinks = [
  ...home.matchAll(/href="(https:\/\/app\.conclaveax\.com[^"]*)"/g),
];
if (appLinks.length < 3)
  errors.push("homepage: expected at least three direct Open Conclave AX links");
if (!home.includes('href="/#product"'))
  errors.push("homepage: Product navigation anchor is missing");
if (!home.includes('href="/#workstreams"'))
  errors.push("homepage: Workstreams navigation anchor is missing");

for (const [route, source] of sources) {
  if (/github\.com\/nohainc\/conclave/i.test(source))
    errors.push(`${route}: public GitHub repository link must not be present`);
  if (/\b(?:architecture\s+)?v\d+\b/i.test(source))
    errors.push(`${route}: architecture version language must not be public product copy`);
  if (/shared workspace/i.test(source))
    errors.push(`${route}: collaborative Workspace terminology must not return`);

  for (const [, href] of source.matchAll(
    /<a\b[^>]*href="([^"#]+)(#[^"]+)?"/g,
  )) {
    if (!href.startsWith("/")) continue;
    const target = href.endsWith("/") ? href : `${href}/`;
    if (!routes.has(target) && target !== "/scripts/")
      errors.push(`${route}: internal link has no generated route: ${href}`);
  }
}

if (errors.length)
  throw new Error(`Content regression checks failed:\n${errors.join("\n")}`);

console.log(
  `Content regression checks passed: ${routes.size} critical routes, Workstream terminology, CTA targets, private-repository posture, and metadata verified.`,
);
