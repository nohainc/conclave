import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  productionSmokeSchemaIssues,
  requiredProductionSmokeColumns,
} from "./production-workspace-gateway-smoke-schema.mjs";

describe("production Workspace Gateway smoke schema gate", () => {
  it("accepts the required production schema contract", () => {
    const tables = Object.keys(requiredProductionSmokeColumns);
    const columns = Object.fromEntries(
      Object.entries(requiredProductionSmokeColumns),
    );

    expect(productionSmokeSchemaIssues(tables, columns)).toEqual([]);
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

    expect(productionSmokeSchemaIssues(tables, columns)).toEqual([
      "workspace_runtime_identities has unexpected columns: credential_key_ref",
      "desktop_auth_intents is missing columns: audience",
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
