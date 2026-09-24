import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const files = [
  "apps/app/lib/src/features/home/home_page.dart",
  "apps/app/lib/src/features/navigation/studio_sidebar.dart",
  "apps/app/lib/src/features/common/command_palette.dart",
  "apps/app/lib/src/features/chat/prompt_composer.dart",
  "apps/app/lib/src/notifications/notification_models.dart",
  "apps/app/lib/src/studio/studio_app.dart",
  "apps/app/lib/src/studio/studio_data.dart",
  "apps/app/lib/src/features/workspace/workspace_settings_page.dart",
  "apps/host/lib/main.dart",
  "apps/host/lib/cloud_connection.dart",
  "apps/site/src",
];

function walk(entry) {
  const absolute = path.join(root, entry);
  if (!fs.statSync(absolute).isDirectory()) return [absolute];
  return fs
    .readdirSync(absolute, { withFileTypes: true })
    .flatMap((item) => walk(path.join(entry, item.name)));
}

const violations = [];
for (const file of files.flatMap(walk)) {
  const relative = path.relative(root, file);
  const lines = fs.readFileSync(file, "utf8").split("\n");
  lines.forEach((line, index) => {
    const isAstro = file.endsWith(".astro");
    const visibleText = isAstro
      ? line
      : [...line.matchAll(/['"]([^'"\\]*(?:\\.[^'"\\]*)*)['"]/g)]
          .map((match) => match[1])
          .join(" ");
    if (/\bHosts?\b/.test(visibleText)) {
      violations.push(`${relative}:${index + 1}: ${line.trim()}`);
    }
  });
}

if (violations.length > 0) {
  console.error("Active user-facing surfaces still contain Host terminology:");
  console.error(violations.join("\n"));
  process.exit(1);
}

console.log("v5 Workspace terminology check passed.");
