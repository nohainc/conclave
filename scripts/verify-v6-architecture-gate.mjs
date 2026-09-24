import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const roots = ["apps/app/lib", "apps/cloud/src", "apps/host/lib", "packages"];
const ignored = new Set([
  "packages/core/src/v4-entities.ts",
  "packages/core/src/v4-scheduler.ts",
  "apps/cloud/migrations-v4",
]);
const forbidden = [
  ["WorkspaceRole authorization", /\bWorkspaceRole\b|WORKSPACE_ROLE_PERMISSIONS/],
  ["Host Workspace binding", /host_workspace_bindings|host\.bind_workspace|x-conclave-workspace-id/],
  ["configured Worker fallback", /configuredWorker|configured_worker|legacy assignment fallback/],
  ["Chat execution authority", /startChatExecution|automatic(?:ally)?\s+(?:create|start)\s+(?:a\s+)?(?:Goal|Run)/i],
  ["mutable registered repository path", /registered(?:Base)?RepositoryPath|baseRepositoryPath/],
  ["user-supplied worktree path", /(?:worktreePath|worktree_path|absoluteWorktreePath)/],
];

function files(entry) {
  const relative = path.relative(root, entry);
  if (ignored.has(relative) || [...ignored].some((item) => relative.startsWith(`${item}/`))) return [];
  const link = fs.lstatSync(entry);
  if (link.isSymbolicLink()) return [];
  const stat = link;
  if (stat.isDirectory()) return fs.readdirSync(entry).flatMap((name) => files(path.join(entry, name)));
  return /\.(?:ts|tsx|dart|js|mjs)$/.test(entry) && !entry.includes(`${path.sep}test${path.sep}`) ? [entry] : [];
}

const violations = [];
for (const rootEntry of roots.flatMap((entry) => files(path.join(root, entry)))) {
  const source = fs.readFileSync(rootEntry, "utf8")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/\/\/.*$/gm, "");
  for (const [label, pattern] of forbidden) {
    if (pattern.test(source)) violations.push(`${label}: ${path.relative(root, rootEntry)}`);
  }
}

if (violations.length) {
  console.error("V6 architecture cleanup gate failed:");
  for (const violation of violations) console.error(`- ${violation}`);
  process.exit(1);
}
console.log("V6 architecture cleanup gate passed.");
