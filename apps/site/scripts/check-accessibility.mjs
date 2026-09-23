import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";

const dist = new URL("../dist/", import.meta.url).pathname;

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

const files = await htmlFiles(dist);
const errors = [];

for (const file of files) {
  const source = await readFile(file, "utf8");
  const relative = file.replace(`${dist}/`, "");
  const headings = [...source.matchAll(/<h([1-6])\b/g)].map((match) =>
    Number(match[1]),
  );
  const h1Count = headings.filter((level) => level === 1).length;

  if (!/^<!doctype html>/i.test(source))
    errors.push(`${relative}: missing doctype`);
  if (!/<html\b[^>]*\blang="[^"]+"/i.test(source))
    errors.push(`${relative}: missing html lang`);
  if (!/<meta\b[^>]*name="viewport"/i.test(source))
    errors.push(`${relative}: missing viewport metadata`);
  if (!/<main\b/i.test(source))
    errors.push(`${relative}: missing main landmark`);
  if (!/<nav\b/i.test(source))
    errors.push(`${relative}: missing navigation landmark`);
  if (!/<footer\b/i.test(source))
    errors.push(`${relative}: missing footer landmark`);
  if (h1Count !== 1)
    errors.push(`${relative}: expected exactly one h1, found ${h1Count}`);
  if (
    headings.some(
      (level, index) => index > 0 && level > headings[index - 1] + 1,
    )
  ) {
    errors.push(`${relative}: heading levels skip a level`);
  }
  if (/<img\b/i.test(source) && /<img\b(?![^>]*\balt=)[^>]*>/i.test(source)) {
    errors.push(`${relative}: image missing alt text`);
  }
  if (/<button\b(?![^>]*\btype=)[^>]*>/i.test(source))
    errors.push(`${relative}: button missing type`);
  if (/tabindex=["']-[2-9]/i.test(source))
    errors.push(
      `${relative}: negative tabindex removes content from keyboard order`,
    );
  if (/tabindex=["'][1-9]/i.test(source))
    errors.push(
      `${relative}: positive tabindex creates a custom keyboard order`,
    );
  if (/user-scalable\s*=\s*["']no|maximum-scale\s*=\s*["']1/i.test(source))
    errors.push(`${relative}: viewport prevents zoom`);
}

if (errors.length)
  throw new Error(`Accessibility checks failed:\n${errors.join("\n")}`);
console.log(
  `Accessibility checks passed: ${files.length} generated HTML pages.`,
);
