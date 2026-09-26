import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const handlers = readFileSync(
  fileURLToPath(new URL("../src/routes/handlers.ts", import.meta.url)),
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

describe("v6 Project lifecycle integrity", () => {
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
    expect(handlers).toContain(
      "UPDATE execution_workspaces SET status = 'revoked'",
    );
    expect(handlers).toContain(
      "UPDATE workspace_project_grants SET status = 'revoked'",
    );
    expect(handlers).toContain(
      'const alreadyRevoked = workspace.status === "revoked"',
    );
    expect(handlers).toContain("status <> 'revoked'");
  });

  it("records Project-scoped audits without requiring a Workspace", () => {
    const start = handlers.indexOf("async function recordAudit");
    const end = handlers.indexOf("function errorMessage", start);
    const body = handlers.slice(start, end);

    expect(body).toContain("project_audit_log");
    expect(body).toContain("if (!auditWorkspaceId)");
  });

  it("preserves instructions when the v5 snapshot reloads Projects", () => {
    const start = handlers.indexOf("async function handleStudioSnapshot");
    const end = handlers.indexOf(
      "async function handleProjectReadModel",
      start,
    );
    const body = handlers.slice(start, end);

    expect(body).toContain("instructions:");
    expect(body).toContain("settings,");
  });

  it("guards duplicate names, grants, and invitations across lifecycle changes", () => {
    expect(handlers).toContain("LOWER(TRIM(name)) = LOWER(TRIM(?2))");
    expect(handlers).toContain("id <> ?2");
    expect(handlers).toContain("status IN ('active', 'suspended')");
    expect(handlers).toContain(
      "status = 'pending' AND LOWER(email) = LOWER(?2)",
    );
    expect(handlers).toContain("You already have a Project with this name");
    expect(handlers).toContain(
      "This Project already has a Workstream with this name",
    );
  });

  it("cleans restrictive Workstream dependencies before deleting a Project", () => {
    const start = handlers.indexOf("async function handleDeleteProject");
    const end = handlers.indexOf(
      "async function authorizeProjectOwnerOrThrow",
      start,
    );
    const body = handlers.slice(start, end);

    expect(body).toContain("DELETE FROM workstream_current_checkpoints");
    expect(body).toContain("DELETE FROM workstream_diff_artifacts");
    expect(body).toContain("DELETE FROM workstream_execution_leases");
    expect(body).toContain("DELETE FROM runs WHERE project_id = ?1");
    expect(body).toContain("DELETE FROM work_requests");
    expect(body).toContain("DELETE FROM workstream_checkouts");
    expect(body).toContain("DELETE FROM workstreams");
    expect(body).toContain(
      "DELETE FROM workspace_project_grants WHERE project_id = ?1",
    );
    expect(body).toContain("for (const sql of cleanupStatements)");
    expect(body).toContain("DELETE FROM projects WHERE id = ?1");
  });
});
