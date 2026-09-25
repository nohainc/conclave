import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const migrationFiles = [
  "0001_conclave_v6.sql",
  "0002_workstream_integrations.sql",
  "0003_usage_audit_observability.sql",
  "0004_chat_workstream_mapping.sql",
  "0005_execution_foundation.sql",
  "0007_project_settings.sql",
  "0010_workspace_project_grant_policy.sql",
  "0011_project_invitations.sql",
  "0012_remove_project_repository.sql",
  "0013_configured_workers.sql",
  "0014_configured_worker_runtime_state.sql",
  "0015_configured_worker_assignments.sql",
  "0016_worker_first_execution_policy.sql",
  "0017_configured_worker_observability.sql",
];

const readMigration = (file: string) =>
  readFileSync(
    fileURLToPath(new URL(`../migrations-v6/${file}`, import.meta.url)),
    "utf8",
  );
const baseSchema = migrationFiles.map(readMigration).join("\n");
const conversion = readMigration("0018_migrate_legacy_ai_accounts.sql");

function applyConversion(): Array<Record<string, unknown>> {
  return JSON.parse(
    execFileSync("sqlite3", ["-json", ":memory:"], {
      input: `${baseSchema}
PRAGMA foreign_keys = ON;
INSERT INTO users VALUES ('u1', 'owner@example.test', 'Owner', 'active', 'now', 'now');
INSERT INTO execution_workspaces VALUES ('ws1', 'u1', 'Mac', 'online', 'now', 'now');
INSERT INTO workers VALUES ('wt1', 'Codex', 'active', 'now', 'now');
INSERT INTO ai_accounts VALUES ('account1', 'u1', 'wt1', 'ws1', 'Codex Personal', 'ready', 'now', 'now');
INSERT INTO ai_accounts VALUES ('account2', 'u1', 'wt1', NULL, 'Codex Personal', 'revoked', 'now', 'now');
${conversion}
${conversion}
SELECT cw.id, cw.name, cw.worker_type_id, b.workspace_id,
       c.state, c.local_secret_ref, l.action
  FROM configured_workers cw
  LEFT JOIN worker_workspace_bindings b ON b.worker_id = cw.id
  LEFT JOIN workspace_worker_credentials c
    ON c.worker_id = cw.id AND c.workspace_id = b.workspace_id
  JOIN configured_worker_audit_log l ON l.configured_worker_id = cw.id
 ORDER BY cw.id, l.action;`,
      encoding: "utf8",
    }),
  ) as Array<Record<string, unknown>>;
}

describe("EW-14 legacy AI Account conversion", () => {
  it("creates configured Workers, preserves Workspace placement, and is idempotent", () => {
    const rows = applyConversion();
    expect(rows).toEqual(
      expect.arrayContaining([
        {
          id: "configured-worker-account1",
          name: "Codex Personal (legacy account1)",
          worker_type_id: "wt1",
          workspace_id: "ws1",
          state: "setup_required",
          local_secret_ref: null,
          action: "worker.created",
        },
        {
          id: "configured-worker-account1",
          name: "Codex Personal (legacy account1)",
          worker_type_id: "wt1",
          workspace_id: "ws1",
          state: "setup_required",
          local_secret_ref: null,
          action: "worker.workspace.bound",
        },
        {
          id: "configured-worker-account2",
          name: "Codex Personal (legacy account2)",
          worker_type_id: "wt1",
          workspace_id: null,
          state: null,
          local_secret_ref: null,
          action: "worker.created",
        },
      ]),
    );
    expect(rows.filter((row) => row.action === "worker.created")).toHaveLength(
      2,
    );
    expect(
      rows.filter((row) => row.action === "worker.workspace.bound"),
    ).toHaveLength(1);
  });
});
