import { readFile } from "node:fs/promises";

const checks = [
  [
    "Flutter active Workspace selector",
    "apps/app/lib/src/studio/studio_app.dart",
    /_workspaceSelector|selectedWorkspaceId|activeWorkspaceId/,
  ],
  [
    "Flutter Workspace settings screen",
    "apps/app/lib/src/features/workspace/workspace_settings_page.dart",
    /.*/,
  ],
  [
    "Workspace invitation routes",
    "apps/cloud/src/routes/router.ts",
    /workspaceInvitationsMatch|handleCreateWorkspaceInvitation|handleAcceptWorkspaceInvitation/,
  ],
  [
    "Host enrollment routes",
    "apps/cloud/src/routes/router.ts",
    /host-enrollments|\/api\/hosts\/enroll/,
  ],
  [
    "Assignment legacy fallback",
    "apps/cloud/src/assignment-dispatcher.ts",
    /selectWorkerForTask\(\s*env\.CONCLAVE_DB/,
  ],
  [
    "Product Usage route",
    "apps/app/lib/src/navigation/studio_navigation.dart",
    /\bStudioRouteKind\.usage\b/,
  ],
  [
    "Usage API handlers",
    "apps/cloud/src/routes/handlers.ts",
    /\bhandleProjectUsage\b|\bhandleWorkspaceUsage\b/,
  ],
  [
    "Budget assertion in dispatch",
    "apps/cloud/src/assignment-dispatcher.ts",
    /\bassertV5BudgetAvailable\b/,
  ],
  [
    "Usage accounting in dispatch",
    "apps/cloud/src/assignment-dispatcher.ts",
    /\brecordV5AssignmentUsage\b/,
  ],
];

const failures = [];
for (const [label, file, pattern] of checks) {
  let source = "";
  try {
    source = await readFile(file, "utf8");
  } catch (error) {
    if (file.includes("workspace_settings_page")) continue;
    failures.push(`${label}: cannot read ${file} (${error.message})`);
    continue;
  }
  const activeSource = source
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/\/\/.*$/gm, "");
  if (pattern.test(activeSource))
    failures.push(`${label}: forbidden active reference in ${file}`);
}

if (failures.length) {
  console.error("V6 convergence guard failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log("V6 convergence guard passed.");
