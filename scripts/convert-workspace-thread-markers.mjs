import {
  lstatSync,
  readdirSync,
  readFileSync,
  writeFileSync,
  renameSync,
} from "node:fs";
import { resolve, join, basename } from "node:path";
import { fileURLToPath } from "node:url";

// Offline cutover only: runtime admission continues to require current markers.
export function convertWorkspaceThreadMarkers(root, { apply = false } = {}) {
  root = resolve(root);
  if (!lstatSync(root).isDirectory() || lstatSync(root).isSymbolicLink())
    throw new Error("Work Root must be a real directory");
  const plan = [];
  for (const space of readdirSync(root, { withFileTypes: true })) {
    if (!space.isDirectory() || space.isSymbolicLink()) continue;
    for (const thread of readdirSync(join(root, space.name), {
      withFileTypes: true,
    })) {
      if (!thread.isDirectory() || thread.isSymbolicLink()) continue;
      const directory = join(root, space.name, thread.name);
      const entries = readdirSync(directory);
      const oldName = ".conclave-workstream.json";
      if (!entries.includes(oldName)) continue;
      const source = join(directory, oldName);
      if (!lstatSync(source).isFile() || lstatSync(source).isSymbolicLink())
        throw new Error("Unsafe source marker");
      const old = JSON.parse(readFileSync(source, "utf8"));
      const safeId = /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/;
      if (
        Object.keys(old).sort().join(",") !==
          "createdAt,projectId,schemaVersion,workstreamId" ||
        old.schemaVersion !== 1 ||
        !safeId.test(old.projectId) ||
        !safeId.test(old.workstreamId) ||
        old.projectId !== space.name ||
        old.workstreamId !== thread.name ||
        typeof old.createdAt !== "string" ||
        !old.createdAt.endsWith("Z") ||
        Number.isNaN(Date.parse(old.createdAt))
      )
        throw new Error("Source marker does not match directory identity");
      const target = join(directory, ".conclave-thread.json");
      const backup = `${source}.pre-thread-cutover`;
      if (
        entries.includes(basename(target)) ||
        entries.includes(basename(backup))
      )
        throw new Error(
          "Current marker or cutover backup already exists; inspect before conversion",
        );
      plan.push({
        source,
        target,
        backup,
        marker: {
          schemaVersion: 1,
          spaceId: old.projectId,
          threadId: old.workstreamId,
          createdAt: old.createdAt,
        },
      });
    }
  }
  // Validate the complete inventory before writing any marker.
  if (apply)
    for (const item of plan) {
      writeFileSync(item.target, `${JSON.stringify(item.marker)}\n`, {
        flag: "wx",
        mode: 0o600,
      });
      renameSync(item.source, item.backup);
    }
  return plan.map(({ marker }) => ({
    spaceId: marker.spaceId,
    threadId: marker.threadId,
  }));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  if (!args[0] || args.some((v, i) => i > 0 && v !== "--apply"))
    throw new Error(
      "Usage: node scripts/convert-workspace-thread-markers.mjs WORK_ROOT [--apply] (stop Workspace before applying)",
    );
  const apply = args.includes("--apply");
  console.log(
    JSON.stringify({
      applied: apply,
      markers: convertWorkspaceThreadMarkers(args[0], { apply }),
    }),
  );
}
