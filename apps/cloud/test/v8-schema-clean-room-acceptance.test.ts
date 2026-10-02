import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const migration = readFileSync(
  fileURLToPath(
    new URL("../migrations-v8/0001_conclave_v8.sql", import.meta.url),
  ),
  "utf8",
);

function apply(sql: string): unknown[] {
  return JSON.parse(
    execFileSync("sqlite3", ["-json", ":memory:"], {
      input: `${migration}\n${sql}`,
      encoding: "utf8",
    }),
  ) as unknown[];
}

describe("v8 clean D1 schema acceptance", () => {
  it("applies as one migration and includes current Workspace, Work, and Profile tables", () => {
    const tables = apply(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name;",
    ) as { name: string }[];
    const tableNames = tables.map(({ name }) => name);
    expect(tableNames).toEqual(
      expect.arrayContaining([
        "users",
        "projects",
        "project_memberships",
        "execution_workspaces",
        "workspace_project_grants",
        "workspace_releases",
        "worker_scheduling",
        "worker_scheduling_audit",
        "workspace_pairing_intents",
        "workstreams",
        "work_requests",
        "worker_assignments",
        "worker_catalog",
        "tool_profile_definitions",
        "tool_profile_releases",
        "tool_profile_channel_pointers",
      ]),
    );
    expect(tableNames).not.toContain("worker_releases");
    expect(tableNames).not.toContain("worker_versions");
    expect(tableNames).not.toContain("credential_profiles");
    expect(tableNames).not.toContain("host_releases");
    expect(tableNames).not.toContain("v7_worker_scheduling");
    expect(tableNames).not.toContain("v7_worker_scheduling_audit");
    expect(tableNames).not.toContain("v7_adapter_releases");
    expect(tableNames).not.toContain("ai_accounts");
    expect(tableNames).not.toContain("host_workspace_bindings");
    expect(tableNames).not.toContain("project_account_grants");
    expect(tableNames).not.toContain("chat_workstream_migrations");
    expect(tableNames).not.toContain("workspace_worker_installations");
    expect(tableNames).not.toContain("worker_attribution_audit_archive");
    const grantColumns = apply(
      "PRAGMA table_info(workspace_project_grants);",
    ) as {
      name: string;
    }[];
    expect(grantColumns.map(({ name }) => name)).toContain("budget_json");
    const policyColumns = apply(
      "PRAGMA table_info(workstream_execution_policies);",
    ) as {
      name: string;
    }[];
    expect(policyColumns.map(({ name }) => name)).toContain("budget_json");
    expect(
      apply(
        "SELECT worker_type_id FROM worker_catalog ORDER BY worker_type_id;",
      ),
    ).toEqual([{ worker_type_id: "chatgpt" }, { worker_type_id: "gemini" }]);
  });

  it("keeps the regular development seed to official logical identities", () => {
    const seed = readFileSync(
      fileURLToPath(new URL("../seed/development.sql", import.meta.url)),
      "utf8",
    );
    expect(
      apply(`${seed}
        SELECT (SELECT COUNT(*) FROM worker_catalog) AS workers,
               (SELECT COUNT(*) FROM tool_profile_definitions) AS profiles,
               (SELECT COUNT(*) FROM tool_profile_releases) AS releases,
               (SELECT COUNT(*) FROM execution_workspaces) AS workspaces,
               (SELECT COUNT(*) FROM work_requests) AS work_requests;`),
    ).toEqual([
      { workers: 2, profiles: 2, releases: 0, workspaces: 0, work_requests: 0 },
    ]);
  });

  it("keeps the fixture CLI Worker in a separate development-only seed", () => {
    const seed = readFileSync(
      fileURLToPath(
        new URL("../seed/development-fixtures.sql", import.meta.url),
      ),
      "utf8",
    );
    expect(
      apply(`${seed}
        SELECT worker.worker_type_id, worker.release_stage,
               definition.profile_definition_id, definition.provider_tool_name
          FROM worker_catalog worker
          JOIN tool_profile_definitions definition
            ON definition.worker_type_id = worker.worker_type_id
         WHERE worker.worker_type_id = 'fixture-worker';`),
    ).toEqual([
      {
        worker_type_id: "fixture-worker",
        release_stage: "testing",
        profile_definition_id: "fixture-cli",
        provider_tool_name: "Fixture CLI",
      },
    ]);
    expect(migration).not.toContain("fixture-worker");
  });

  it("stores pairing intent before creating a permanent execution Workspace", () => {
    expect(
      apply(`
        INSERT INTO users (id, email, display_name, status, created_at, updated_at)
          VALUES ('u1', 'owner@example.test', 'Owner', 'active', '2026-01-01', '2026-01-01');
        INSERT INTO workspace_pairing_intents
          (pairing_id, owner_user_id, token_hash, created_at, expires_at)
          VALUES ('pair-1', 'u1', 'sha256:token-hash', '2026-01-01', '2026-01-01T00:15:00Z');
        SELECT (SELECT COUNT(*) FROM workspace_pairing_intents) AS intent_count,
               (SELECT COUNT(*) FROM execution_workspaces) AS workspace_count;
      `),
    ).toEqual([{ intent_count: 1, workspace_count: 0 }]);
  });

  it("preserves the synchronized v8 Engine and Profile evidence columns", () => {
    const columns = apply("PRAGMA table_info(workspace_worker_inventory);") as {
      name: string;
    }[];
    const names = columns.map(({ name }) => name);
    expect(names).toEqual(
      expect.arrayContaining([
        "activation_state",
        "readiness_state",
        "engine_version",
        "profile_definition_id",
        "profile_release_version",
        "provider_tool_name",
        "provider_tool_version",
      ]),
    );
    expect(names).not.toContain("worker_runtime_version");
    expect(names).not.toContain("adapter_version");
    expect(names).not.toContain("provider_tool_path");
    expect(names).not.toContain("account_id");
    const workerForeignKey = apply(
      "PRAGMA foreign_key_list(worker_assignments);",
    ) as { from: string; table: string; to: string }[];
    expect(
      workerForeignKey.find(({ from }) => from === "worker_id"),
    ).toMatchObject({ table: "worker_catalog", to: "worker_type_id" });
  });
});
