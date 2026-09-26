import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";

const root = process.argv[2];
if (!root) throw new Error("A directory to scan is required");

const forbidden = [];

async function scan(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      await scan(path);
      continue;
    }
    const content = await readFile(path, "utf8");
    for (const secretName of forbidden) {
      if (content.includes(secretName))
        throw new Error(
          `Browser bundle contains forbidden secret name: ${secretName}`,
        );
    }
  }
}

await scan(root);
console.log(`Browser bundle secret scan passed: ${root}`);
