import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { describe, expect, it } from "vitest";
import {
  productionSmokeSchemaIssues,
  requiredProductionSmokeColumns,
  requiredProductionSmokeTableDefinitions,
} from "./production-workspace-gateway-smoke-schema.mjs";

const canonicalDefinitions = Object.fromEntries(
  Object.entries(requiredProductionSmokeTableDefinitions),
);

describe("production Workspace Gateway smoke schema gate", () => {
  it("accepts the required production schema contract", () => {
    const tables = Object.keys(requiredProductionSmokeColumns);
    const columns = Object.fromEntries(
      Object.entries(requiredProductionSmokeColumns),
    );

    expect(
      productionSmokeSchemaIssues(tables, columns, canonicalDefinitions),
    ).toEqual([]);
  });

  it("tracks the canonical v8 migration columns", () => {
    const migration = readFileSync(
      new URL(
        "../apps/cloud/migrations-v8/0001_conclave_v8.sql",
        import.meta.url,
      ),
      "utf8",
    );

    for (const [table, expectedColumns] of Object.entries(
      requiredProductionSmokeColumns,
    )) {
      const definition = migration.match(
        new RegExp(`CREATE TABLE ${table} \\(([\\s\\S]*?)\\n\\);`),
      );
      expect(definition, `canonical migration table ${table}`).not.toBeNull();
      const actualColumns = [...definition[1].matchAll(/^ {2}([a-z_]+)\s+/gm)]
        .map((match) => match[1])
        .sort();
      expect(actualColumns, `${table} columns`).toEqual(
        [...expectedColumns].sort(),
      );
    }
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
      productionSmokeSchemaIssues(tables, columns, canonicalDefinitions),
    ).toEqual([
      "workspace_runtime_identities has unexpected columns: credential_key_ref",
      "desktop_auth_intents is missing columns: audience",
    ]);
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
    const definitions = Object.fromEntries(
      database
        .prepare(
          "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name IN (?, ?, ?, ?)",
        )
        .all(
          "execution_workspaces",
          "workspace_runtime_identities",
          "desktop_auth_intents",
          "desktop_human_sessions",
        )
        .map((row) => [row.name, row.sql]),
    );

    expect(
      productionSmokeSchemaIssues(
        Object.keys(requiredProductionSmokeColumns),
        requiredProductionSmokeColumns,
        definitions,
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

    expect(productionSmokeSchemaIssues(tables, columns, definitions)).toEqual([
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
});
