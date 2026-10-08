import { DatabaseSync } from "node:sqlite";
import { expect, it, vi } from "vitest";

vi.mock("../src/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeRequest: async () => ({ userId: "user-owner" }),
}));
import { handleListSpaceThreads } from "../src/routes/threads.js";

it("reads threads and configuration with distinct update timestamps", async () => {
  const sqlite = new DatabaseSync(":memory:");
  try {
    sqlite.exec(`
      CREATE TABLE spaces (id TEXT, owner_user_id TEXT, settings_json TEXT);
      CREATE TABLE users (id TEXT, email TEXT, display_name TEXT);
      CREATE TABLE threads (id TEXT, space_id TEXT, name TEXT, status TEXT,
        access_policy_json TEXT, lead_user_id TEXT, created_at TEXT, updated_at TEXT);
      CREATE TABLE thread_work_configs (thread_id TEXT, config_json TEXT, updated_at TEXT);
      CREATE TABLE space_memberships (id TEXT, space_id TEXT, user_id TEXT, role TEXT, created_at TEXT, updated_at TEXT);
      INSERT INTO spaces VALUES ('space-test', 'user-owner', '{}');
      INSERT INTO users VALUES ('user-owner', 'owner@conclave.test', 'Owner');
      INSERT INTO threads VALUES ('stream-test', 'space-test', 'Test stream', 'active', '{}', 'user-owner', 'created', 'stream-updated');
      INSERT INTO thread_work_configs VALUES ('stream-test', '{"defaultWorkflowId":"full_cycle","bindings":{}}', 'config-updated');
      INSERT INTO space_memberships VALUES ('membership', 'space-test', 'user-owner', 'owner', 'created', 'updated');
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
    const response = await handleListSpaceThreads(
      new Request("https://conclave.test/api/spaces/space-test/threads"),
      { CONCLAVE_DB: db } as unknown as Parameters<
        typeof handleListSpaceThreads
      >[1],
      "space-test",
    );
    expect(response.status).toBe(200);
    const data = (await response.json()) as {
      threads: Record<string, unknown>[];
    };
    expect(data.threads).toHaveLength(1);
    expect(data.threads[0]).toMatchObject({
      id: "stream-test",
      name: "Test stream",
      updatedAt: "stream-updated",
    });
  } finally {
    sqlite.close();
  }
});
