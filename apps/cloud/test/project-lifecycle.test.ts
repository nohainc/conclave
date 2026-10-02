import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const workspaces = readFileSync(
  fileURLToPath(
    new URL("../src/routes/workspaces-management.ts", import.meta.url),
  ),
  "utf8",
);
const httpSecurity = readFileSync(
  fileURLToPath(new URL("../src/routes/http-security.ts", import.meta.url)),
  "utf8",
);
const projects = readFileSync(
  fileURLToPath(new URL("../src/routes/projects.ts", import.meta.url)),
  "utf8",
);
const workstreams = readFileSync(
  fileURLToPath(new URL("../src/routes/workstreams.ts", import.meta.url)),
  "utf8",
);
const entrypoint = readFileSync(
  fileURLToPath(new URL("../src/index.ts", import.meta.url)),
  "utf8",
);
const router = readFileSync(
  fileURLToPath(new URL("../src/routes/router.ts", import.meta.url)),
  "utf8",
);

describe("Project lifecycle integrity", () => {
  it("registers project deletion in the production route handler table", () => {
    expect(entrypoint).toContain(
      "handleDeleteProject: handlers.handleDeleteProject",
    );
  });

  it("routes Workspace revoke to the execution Workspace lifecycle", () => {
    const start = router.indexOf("const workspaceMatch = url.pathname.match");
    const end = router.indexOf('if (request.method === "PATCH"', start);
    const body = router.slice(start, end);

    expect(body).toContain('request.method === "DELETE"');
    expect(body).toContain("handleRevokeWorkspace");
    expect(entrypoint).toContain(
      "handleRevokeWorkspace: handlers.handleRevokeWorkspace",
    );
    expect(workspaces).toContain(
      "UPDATE execution_workspaces SET status = 'revoked'",
    );
    expect(workspaces).toContain(
      "UPDATE workspace_project_grants SET status = 'revoked'",
    );
    expect(workspaces).toContain(
      "UPDATE workspace_runtime_identities SET revoked_at = ?1",
    );
    expect(workspaces).not.toContain("catch(() => undefined)");
    expect(workspaces).not.toContain(
      "partially migrated development/preview database",
    );
    expect(workspaces).toContain(
      'const alreadyRevoked = workspace.status === "revoked"',
    );
    expect(workspaces).toContain("status <> 'revoked'");
  });

  it("records Project-scoped audits without requiring a Workspace", () => {
    expect(httpSecurity).toContain("project_audit_log");
    expect(httpSecurity).toContain("if (!auditWorkspaceId)");
    expect(httpSecurity).not.toContain(".catch(() => undefined)");
  });

  it("guards duplicate names, grants, and invitations across lifecycle changes", () => {
    const all = `${projects}\n${workstreams}\n${workspaces}`;
    expect(all).toContain("LOWER(TRIM(name)) = LOWER(TRIM(?2))");
    expect(all).toContain("id <> ?2");
    expect(all).toContain("status IN ('active', 'suspended')");
    expect(all).toContain("status = 'pending' AND LOWER(email) = LOWER(?2)");
    expect(all).toContain("You already have a Project with this name");
    expect(all).toContain(
      "This Project already has a Workstream with this name",
    );
  });

  it("cleans restrictive Workstream dependencies before deleting a Project", () => {
    const start = projects.indexOf("async function handleDeleteProject");
    const end = projects.indexOf(
      "async function authorizeProjectOwnerOrThrow",
      start,
    );
    const body = projects.slice(start, end);

    expect(body).toContain("DELETE FROM runs WHERE project_id = ?1");
    expect(body).toContain("DELETE FROM work_requests");
    expect(body).toContain("DELETE FROM workstreams");
    expect(body).toContain(
      "DELETE FROM workspace_project_grants WHERE project_id = ?1",
    );
    expect(body).toContain("for (const sql of cleanupStatements)");
    expect(body).toContain("DELETE FROM projects WHERE id = ?1");
  });
});
