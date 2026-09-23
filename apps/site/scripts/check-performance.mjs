import { readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";

const dist = new URL("../dist/", import.meta.url);
const maxHtmlBytes = 50_000;
const maxCssBytes = 75_000;
const maxScriptBytes = 15_000;

async function filesIn(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...(await filesIn(path)));
    else files.push(path);
  }
  return files;
}

const files = await filesIn(dist.pathname);
const htmlFiles = files.filter((file) => file.endsWith(".html"));
const cssFiles = files.filter((file) => file.endsWith(".css"));
const scriptFiles = files.filter((file) => file.endsWith(".js"));

for (const file of htmlFiles) {
  const source = await readFile(file, "utf8");
  if (Buffer.byteLength(source) > maxHtmlBytes)
    throw new Error(`${file} exceeds ${maxHtmlBytes} bytes`);
  if (!source.includes('rel="canonical"'))
    throw new Error(`${file} is missing a canonical URL`);
  if (!source.includes('name="description"'))
    throw new Error(`${file} is missing a meta description`);
  if (/<script[^>]+src=["']https?:\/\//i.test(source))
    throw new Error(`${file} loads a third-party script`);
}

for (const file of cssFiles) {
  if ((await stat(file)).size > maxCssBytes)
    throw new Error(`${file} exceeds ${maxCssBytes} bytes`);
}

for (const file of scriptFiles) {
  if ((await stat(file)).size > maxScriptBytes)
    throw new Error(`${file} exceeds ${maxScriptBytes} bytes`);
}

console.log(
  `Performance budget passed: ${htmlFiles.length} HTML, ${cssFiles.length} CSS, ${scriptFiles.length} JS assets.`,
);
