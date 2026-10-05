import { DatabaseSync } from "node:sqlite";
import { expect, it, vi } from "vitest";

vi.mock("../src/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeRequest: async () => ({ userId: "user-owner" }),
}));
import { handleListProjectWorkstreams } from "../src/routes/workstreams.js";

it("reads workstreams and configuration with distinct update timestamps", async () => {
  const sqlite = new DatabaseSync(":memory:");
  try {
    sqlite.exec(`
      CREATE TABLE projects (id TEXT, settings_json TEXT);
      CREATE TABLE workstreams (id TEXT, project_id TEXT, name TEXT, status TEXT,
        access_policy_json TEXT, lead_user_id TEXT, created_at TEXT, updated_at TEXT);
      CREATE TABLE workstream_work_configs (workstream_id TEXT, config_json TEXT, updated_at TEXT);
      CREATE TABLE project_memberships (id TEXT, project_id TEXT, user_id TEXT, role TEXT, created_at TEXT, updated_at TEXT);
      INSERT INTO projects VALUES ('project-test', '{}');
      INSERT INTO workstreams VALUES ('stream-test', 'project-test', 'Test stream', 'active', '{}', 'user-owner', 'created', 'stream-updated');
      INSERT INTO workstream_work_configs VALUES ('stream-test', '{"defaultWorkflowId":"full_cycle","bindings":{}}', 'config-updated');
      INSERT INTO project_memberships VALUES ('membership', 'project-test', 'user-owner', 'owner', 'created', 'updated');
    `);
    const db = {
      prepare(sql: string) {
        let values: string[] = [];
        return {
          bind(...args: string[]) {
            values = args;
            return this;
          },
          async first() {
            return sqlite.prepare(sql).get(...values) ?? null;
          },
          async all() {
            return { results: sqlite.prepare(sql).all(...values) };
          },
        };
      },
    };
    const response = await handleListProjectWorkstreams(
      new Request(
        "https://conclave.test/api/projects/project-test/workstreams",
      ),
      { CONCLAVE_DB: db } as unknown as Parameters<
        typeof handleListProjectWorkstreams
      >[1],
      "project-test",
    );
    expect(response.status).toBe(200);
    const data = (await response.json()) as {
      workstreams: Record<string, unknown>[];
    };
    expect(data.workstreams).toHaveLength(1);
    expect(data.workstreams[0]).toMatchObject({
      id: "stream-test",
      name: "Test stream",
      updatedAt: "stream-updated",
    });
  } finally {
    sqlite.close();
  }
});
