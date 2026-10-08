import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { assertSpaceThreadSchema } from "./space-thread-schema-preflight.mjs";
import { renameArtifacts } from "./rename-hygiene.mjs";

const current = [
  "spaces",
  "threads",
  "space_memberships",
  "space_invitations",
  "workspace_space_grants",
].map((name) => ({
  type: "table",
  name,
  sql: `CREATE TABLE ${name} (id TEXT PRIMARY KEY, ${name === "spaces" ? "owner_user_id" : "space_id"} TEXT)`,
}));
const response = (rows) => [{ success: true, results: rows }];

describe("Space/Thread rename follow-up", () => {
  it.each([
    "body['spaces'] ?? body['spaces']",
    "navigation.spaceId ??\n navigation.spaceId",
    "'threads' || 'threads'",
    "payload['threadId'] ?? payload['threadId']",
  ])("rejects mechanical artifact %s", (source) => {
    expect(renameArtifacts(source)).toHaveLength(1);
  });
  it.each([
    "navigatorKey.currentState?.context ?? context",
    "head?.newestCursor ?? newestCursor ?? current.newestCursor",
    "spaceId ?? this.spaceId",
    "body['spaces'] ?? []",
    "!sessionId || sessionId !== this.sessionId",
    "steps.size !== input.steps.length || input.steps.length > 1000",
  ])("preserves valid fallback %s", (source) => {
    expect(renameArtifacts(source)).toHaveLength(0);
  });
  it("accepts renamed schema and rejects old, mixed and unavailable schema", () => {
    expect(() => assertSpaceThreadSchema(response(current))).not.toThrow();
    expect(() =>
      assertSpaceThreadSchema(
        response([
          {
            type: "table",
            name: "projects",
            sql: "CREATE TABLE projects(id TEXT)",
          },
        ]),
      ),
    ).toThrow(/cutover required/);
    expect(() =>
      assertSpaceThreadSchema(
        response([
          ...current,
          {
            type: "table",
            name: "conversation_turns",
            sql: "CREATE TABLE conversation_turns (workstream_id TEXT)",
          },
        ]),
      ),
    ).toThrow(/cutover required/);
    expect(() => assertSpaceThreadSchema([{ success: false }])).toThrow(
      /inspection failed/,
    );
    expect(() => assertSpaceThreadSchema(response([]))).toThrow(
      /cutover required/,
    );
  });
  it("accepts the fresh-start baseline and rejects missing identity columns", () => {
    const baseline = readFileSync(
      new URL(
        "../apps/cloud/migrations-v8/0001_conclave_v8.sql",
        import.meta.url,
      ),
      "utf8",
    );
    const tables = [
      ...baseline.matchAll(/CREATE TABLE (\w+) \([\s\S]*?\n\);/g),
    ].map((match) => ({ type: "table", name: match[1], sql: match[0] }));
    expect(() => assertSpaceThreadSchema(response(tables))).not.toThrow();
    expect(() =>
      assertSpaceThreadSchema(
        response(
          current.map((row) =>
            row.name === "threads"
              ? { ...row, sql: "CREATE TABLE threads (id TEXT)" }
              : row,
          ),
        ),
      ),
    ).toThrow(/missing identity columns/);
  });
  it("runs the cutover guard before attempting any migration transformation or apply", () => {
    const source = readFileSync(
      new URL("./migrate-production-d1.sh", import.meta.url),
      "utf8",
    );
    expect(source.indexOf("space-thread-schema-preflight.mjs")).toBeLessThan(
      source.indexOf("prepare-chat-workflow-migration.mjs"),
    );
    expect(source.indexOf("space-thread-schema-preflight.mjs")).toBeLessThan(
      source.indexOf("d1 migrations apply"),
    );
  });
});
