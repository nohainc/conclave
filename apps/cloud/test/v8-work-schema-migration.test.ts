import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const fixture = readFileSync(
  fileURLToPath(
    new URL("./fixtures/pre-v8-production-work-schema.sql", import.meta.url),
  ),
  "utf8",
);
const migrationDirectory = fileURLToPath(
  new URL("../migrations-v6/", import.meta.url),
);
const migrationNames = [
  "0048_reconcile_work_v1_runtime_schema.sql",
  "0049_safe_worker_inventory_v8.sql",
  "0050_remove_native_worker_release_catalog.sql",
];
const migrations = migrationNames
  .map((name) => readFileSync(`${migrationDirectory}${name}`, "utf8"))
  .join("\n");

function apply(sql: string): unknown[] {
  return JSON.parse(
    execFileSync("sqlite3", ["-json", ":memory:"], {
      input: `${fixture}\n${sql}\nSELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name;`,
      encoding: "utf8",
    }),
  ) as unknown[];
}

describe("v8 forward migration from the production Work schema", () => {
  it("reconciles empty v6 Work tables before applying v8 inventory cleanup", () => {
    apply(migrations);

    const columns = JSON.parse(
      execFileSync("sqlite3", ["-json", ":memory:"], {
        input: `${fixture}\n${migrations}\nPRAGMA table_info(work_requests);`,
        encoding: "utf8",
      }),
    ) as { name: string }[];
    expect(columns.map(({ name }) => name)).toEqual([
      "id",
      "workstream_id",
      "requested_by_user_id",
      "mode",
      "workflow_id",
      "workflow_version",
      "workflow_snapshot_json",
      "status",
      "primary_workspace_id",
      "checkout_id",
      "input_json",
      "created_at",
      "updated_at",
      "snapshot_json",
      "cancel_requested_at",
    ]);

    const taskColumns = JSON.parse(
      execFileSync("sqlite3", ["-json", ":memory:"], {
        input: `${fixture}\n${migrations}\nPRAGMA table_info(workflow_tasks);`,
        encoding: "utf8",
      }),
    ) as { name: string }[];
    expect(taskColumns.map(({ name }) => name)).toEqual([
      "id",
      "work_request_id",
      "step_kind",
      "execution_mode",
      "timeout_ms",
      "prompt_profile_version",
      "status",
      "attempt",
      "output_json",
      "error",
      "created_at",
      "updated_at",
      "started_at",
      "finished_at",
    ]);

    const releaseTables = JSON.parse(
      execFileSync("sqlite3", ["-json", ":memory:"], {
        input: `${fixture}\n${migrations}\nSELECT COUNT(*) AS count FROM sqlite_schema WHERE type = 'table' AND name = 'worker_releases';`,
        encoding: "utf8",
      }),
    ) as { count: number }[];
    expect(releaseTables).toEqual([{ count: 0 }]);

    let triggerError: string | undefined;
    try {
      execFileSync("sqlite3", ["-batch", ":memory:"], {
        input: `${fixture}\n${migrations}
          INSERT INTO users VALUES ('user-1');
          INSERT INTO workstreams VALUES ('workstream-1');
          INSERT INTO work_requests (
            id, workstream_id, requested_by_user_id, mode, workflow_id,
            workflow_version, workflow_snapshot_json, status,
            input_json, created_at, updated_at
          ) VALUES (
            'request-1', 'workstream-1', 'user-1', 'stateless', 'direct',
            1, '{}', 'queued', '{}', 'now', 'now'
          );
          UPDATE work_requests SET workflow_version = 2 WHERE id = 'request-1';`,
        encoding: "utf8",
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch (error) {
      triggerError = String(
        (error as NodeJS.ErrnoException & { stderr?: Buffer }).stderr ?? "",
      );
    }
    expect(triggerError).toContain("Work Request snapshots are immutable");
  });

  it("stops before rebuilding if existing Work Request data would be lost", () => {
    const withExistingWork = `${fixture}
      INSERT INTO users VALUES ('user-1');
      INSERT INTO workstreams VALUES ('workstream-1');
      INSERT INTO workflow_definitions VALUES ('workflow-1');
      INSERT INTO workflow_versions VALUES ('version-1', 'workflow-1', 1);
      INSERT INTO work_requests (
        id, workstream_id, requested_by_user_id, mode,
        workflow_definition_id, workflow_version_id,
        workflow_snapshot_json, status, input_json, created_at, updated_at
      ) VALUES (
        'request-1', 'workstream-1', 'user-1', 'stateless',
        'workflow-1', 'version-1', '{}', 'queued', '{}', 'now', 'now'
      );
    `;

    expect(() =>
      execFileSync("sqlite3", ["-batch", ":memory:"], {
        input: `${withExistingWork}\n${migrations}`,
        encoding: "utf8",
        stdio: ["pipe", "pipe", "ignore"],
      }),
    ).toThrow();
  });
});
