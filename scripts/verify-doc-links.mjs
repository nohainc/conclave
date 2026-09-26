import { readdir, readFile, stat } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";

const roots = ["README.md", "ARCHITECTURE.md", "ROADMAP.md", "docs"];

async function markdownFiles(path) {
  const metadata = await stat(path);
  if (metadata.isFile()) return path.endsWith(".md") ? [path] : [];

  const entries = await readdir(path, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    files.push(...(await markdownFiles(join(path, entry.name))));
  }
  return files;
}

const files = (await Promise.all(roots.map(markdownFiles))).flat();
const missing = [];
const markdownLink = /\[[^\]]+\]\(([^)#]+)(?:#[^)]+)?\)/g;

for (const file of files) {
  const contents = await readFile(file, "utf8");
  for (const match of contents.matchAll(markdownLink)) {
    const target = match[1];
    if (
      target.startsWith("http://") ||
      target.startsWith("https://") ||
      target.startsWith("mailto:")
    ) {
      continue;
    }

    try {
      await stat(resolve(dirname(file), target));
    } catch {
      missing.push(`${file} -> ${target}`);
    }
  }
}

if (missing.length > 0) {
  console.error("Broken local Markdown links:");
  console.error(missing.join("\n"));
  process.exit(1);
}

console.log(`Markdown link check passed: ${files.length} files scanned`);
