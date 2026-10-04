import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { describe, expect, it } from "vitest";
import {
  productionSmokeSchemaIssues,
  requiredProductionSmokeColumns,
  requiredProductionSmokeIndexes,
  requiredProductionSmokeTableDefinitions,
} from "./production-workspace-gateway-smoke-schema.mjs";

const canonicalDefinitions = Object.fromEntries(
  Object.entries(requiredProductionSmokeTableDefinitions),
);
const canonicalIndexes = Object.fromEntries(
  Object.entries(requiredProductionSmokeIndexes).map(([name, index]) => [
    name,
    { name, tbl_name: index.tableName, sql: index.sql },
  ]),
);

describe("production Workspace Gateway smoke schema gate", () => {
  it("accepts the required production schema contract", () => {
    const tables = Object.keys(requiredProductionSmokeColumns);
    const columns = Object.fromEntries(
      Object.entries(requiredProductionSmokeColumns),
    );

    expect(
      productionSmokeSchemaIssues(
        tables,
        columns,
        canonicalDefinitions,
        canonicalIndexes,
      ),
    ).toEqual([]);
  });

  it("tracks canonical columns after all forward migrations", () => {
    const database = new DatabaseSync(":memory:");
    for (const migration of [
      "0001_conclave_v8.sql",
      "0002_desktop_auth_multi_audience.sql",
      "0003_workspace_installations.sql",
      "0004_workspace_runtime_identity_uniqueness.sql",
    ]) {
      database.exec(
        readFileSync(
          new URL(`../apps/cloud/migrations-v8/${migration}`, import.meta.url),
          "utf8",
        ),
      );
    }

    for (const [table, expectedColumns] of Object.entries(
      requiredProductionSmokeColumns,
    )) {
      const actualColumns = database
        .prepare(`PRAGMA table_info(${table})`)
        .all()
        .map((column) => column.name)
        .sort();
      expect(actualColumns, `${table} columns`).toEqual(
        [...expectedColumns].sort(),
      );
    }
    database.close();
  });

  it("fails on missing auth audience columns and legacy schema columns", () => {
    const tables = Object.keys(requiredProductionSmokeColumns);
    const columns = Object.fromEntries(
      Object.entries(requiredProductionSmokeColumns),
    );
    columns.desktop_auth_intents = columns.desktop_auth_intents.filter(
      (column) => column !== "audience",
    );
    columns.workspace_runtime_identities = [
      ...columns.workspace_runtime_identities,
      "credential_key_ref",
    ];

    expect(
      productionSmokeSchemaIssues(
        tables,
        columns,
        canonicalDefinitions,
        canonicalIndexes,
      ),
    ).toEqual([
      "workspace_runtime_identities has unexpected columns: credential_key_ref",
      "desktop_auth_intents is missing columns: audience",
    ]);
  });

  it("requires the stable Workspace ownership table before deployment", () => {
    const tables = Object.keys(requiredProductionSmokeColumns).filter(
      (table) => table !== "workspace_installations",
    );

    expect(
      productionSmokeSchemaIssues(
        tables,
        requiredProductionSmokeColumns,
        canonicalDefinitions,
        canonicalIndexes,
      ),
    ).toContain(
      "Production D1 workspace_installations is missing. Apply pending migration before deployment.",
    );
  });

  it("requires the active Workspace runtime uniqueness index", () => {
    const indexes = { ...canonicalIndexes };
    delete indexes.idx_workspace_runtime_identities_active_workspace;

    expect(
      productionSmokeSchemaIssues(
        Object.keys(requiredProductionSmokeColumns),
        requiredProductionSmokeColumns,
        canonicalDefinitions,
        indexes,
      ),
    ).toContain(
      "Production D1 is missing required unique partial index idx_workspace_runtime_identities_active_workspace. Apply pending migration before deployment.",
    );
  });

  it("matches sqlite_master definitions after the ordered migrations", () => {
    const database = new DatabaseSync(":memory:");
    database.exec(
      readFileSync(
        new URL(
          "../apps/cloud/migrations-v8/0001_conclave_v8.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    database.exec(
      readFileSync(
        new URL(
          "../apps/cloud/migrations-v8/0002_desktop_auth_multi_audience.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    database.exec(
      readFileSync(
        new URL(
          "../apps/cloud/migrations-v8/0003_workspace_installations.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    database.exec(
      readFileSync(
        new URL(
          "../apps/cloud/migrations-v8/0004_workspace_runtime_identity_uniqueness.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    database.exec(
      readFileSync(
        new URL(
          "../apps/cloud/migrations-v8/0005_workspace_schema_alignment.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    const definitions = Object.fromEntries(
      database
        .prepare(
          "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name IN (?, ?, ?, ?, ?)",
        )
        .all(
          "execution_workspaces",
          "workspace_installations",
          "workspace_runtime_identities",
          "desktop_auth_intents",
          "desktop_human_sessions",
        )
        .map((row) => [row.name, row.sql]),
    );
    const indexes = Object.fromEntries(
      database
        .prepare(
          "SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL",
        )
        .all()
        .map((row) => [row.name, row]),
    );

    expect(
      productionSmokeSchemaIssues(
        Object.keys(requiredProductionSmokeColumns),
        requiredProductionSmokeColumns,
        definitions,
        indexes,
      ),
    ).toEqual([]);
    database.close();
  });

  it("rejects legacy single-audience constraints and table contract drift", () => {
    const tables = Object.keys(requiredProductionSmokeColumns);
    const columns = Object.fromEntries(
      Object.entries(requiredProductionSmokeColumns),
    );
    const definitions = { ...canonicalDefinitions };
    definitions.desktop_auth_intents = definitions.desktop_auth_intents.replace(
      "'conclave.profile-lab.management'",
      "'conclave.workspace.legacy'",
    );
    definitions.desktop_human_sessions =
      definitions.desktop_human_sessions.replace(
        "'conclave.profile-lab.management'",
        "'conclave.workspace.legacy'",
      );
    definitions.execution_workspaces = definitions.execution_workspaces.replace(
      "'draining'",
      "'suspended'",
    );

    expect(
      productionSmokeSchemaIssues(
        tables,
        columns,
        definitions,
        canonicalIndexes,
      ),
    ).toEqual([
      "Production D1 execution_workspaces table definition differs from the v8 contract. Apply a forward migration before deployment.",
      "Production D1 desktop_auth_intents has legacy single-audience constraint. Apply pending migration before deployment.",
      "Production D1 desktop_human_sessions has legacy single-audience constraint. Apply pending migration before deployment.",
    ]);
  });

  it("contains no production table definition mutations", () => {
    const script = readFileSync(
      new URL("./production-workspace-gateway-smoke.mjs", import.meta.url),
      "utf8",
    );

    expect(script).not.toMatch(/\b(?:ALTER|DROP|CREATE)\s+TABLE\b/i);
  });

  it("checks desktop audience boundaries and rejects non-owner Lab approval", () => {
    const script = readFileSync(
      new URL("./production-workspace-gateway-smoke.mjs", import.meta.url),
      "utf8",
    );

    for (const contract of [
      'audience: "conclave.desktop.management"',
      'audience: "conclave.profile-lab.management"',
      "verifyWorkspaceAuth",
      "CONCLAVE_PROFILE_LAB_OWNER_EMAIL",
      "Profile Lab is restricted to its verified owner account",
      "deniedClaim.status !== 409",
      "Rejected Profile Lab intent must remain unapproved and unclaimed",
      "/api/desktop-auth/intents/",
      "/approve",
      "/claim",
      "claimed_session_id",
      "conclave.profile-lab.management",
      "/api/desktop-auth/session",
      "/api/admin/tool-profiles/definitions",
      "The profiles:admin permission is required",
      "/api/workspace-runtime/register",
      "/api/workspace-runtime/sessions",
      "/api/admin/tool-profiles/definitions",
      "workspaceHumanCredential = await verifyWorkspaceAuth()",
      "DELETE FROM auth_sessions",
    ]) {
      expect(script).toContain(contract);
    }
    expect(script).not.toMatch(/INSERT\s+INTO\s+desktop_human_sessions/i);
  });

  it("requires the browser signing secret and runs dual auth acceptance after deployment", () => {
    const workflow = readFileSync(
      new URL("../.github/workflows/deploy-app.yml", import.meta.url),
      "utf8",
    );
    const migrations = workflow.indexOf("name: Apply production D1 migrations");
    const deployedSmoke = workflow.indexOf(
      "name: Require production dual desktop-auth and Workspace Gateway acceptance",
    );
    const deploy = workflow.indexOf("name: Deploy app.conclaveax.com");
    const secretRequirement = workflow.indexOf(
      "name: Require Better Auth signing secret for desktop auth smoke",
    );

    expect(secretRequirement).toBeGreaterThan(-1);
    expect(workflow).toContain(
      "name: Require Better Auth signing secret for desktop auth smoke",
    );
    expect(secretRequirement).toBeLessThan(migrations);
    expect(migrations).toBeLessThan(deployedSmoke);
    expect(deployedSmoke).toBeGreaterThan(deploy);
    expect(workflow).toContain(
      "BETTER_AUTH_SECRET: ${{ secrets.BETTER_AUTH_SECRET }}",
    );
  });
});
