import { describe, expect, it, beforeEach } from "vitest";
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import worker from "../src/index.js";
import { hashToken } from "../../../packages/security/src/index.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const schemaPath = path.resolve(__dirname, "../migrations/0001_initial.sql");

function createD1Mock(db: DatabaseSync) {
  return {
    prepare(query: string) {
      let params: Array<string | number | bigint | null | Uint8Array> = [];
      const stmtObj = {
        bind(...args: unknown[]) {
          params = args as Array<string | number | bigint | null | Uint8Array>;
          return stmtObj;
        },
        async first<T = Record<string, unknown>>() {
          const stmt = db.prepare(query);
          const res = stmt.get(...params) as T | undefined;
          return res ?? null;
        },
        async all<T = Record<string, unknown>>() {
          const stmt = db.prepare(query);
          const res = stmt.all(...params) as T[];
          return { results: res };
        },
        async run() {
          const stmt = db.prepare(query);
          stmt.run(...params);
          return { success: true };
        },
      };
      return stmtObj;
    },
    async batch(statements: Array<{ run: () => Promise<unknown> }>) {
      for (const stmt of statements) {
        await stmt.run();
      }
    },
  };
}

interface TestEnv extends Env {
  CONCLAVE_ENVIRONMENT: "development";
  CONCLAVE_DB: D1Database;
}

describe("Worker Configuration REST API (Architecture v2)", () => {
  let db: DatabaseSync;
  let d1: D1Database;
  let mockEnv: TestEnv;
  const adminToken = "tok_admin_workers_123";

  beforeEach(async () => {
    db = new DatabaseSync(":memory:");
    db.exec("PRAGMA foreign_keys = ON;");
    const sql = fs.readFileSync(schemaPath, "utf8");
    db.exec(sql);
    d1 = createD1Mock(db) as unknown as D1Database;

    mockEnv = {
      CONCLAVE_ENVIRONMENT: "development",
      CONCLAVE_DB: d1,
    } as TestEnv;

    const now = new Date().toISOString();
    const adminTokenHash = await hashToken(adminToken);

    // Seed test user, workspace, membership, agent, and plugin
    db.prepare(
      `INSERT INTO users (id, email, display_name, status, created_at, updated_at)
       VALUES ('u-admin', 'admin@conclave.local', 'Admin User', 'active', ?, ?)`,
    ).run(now, now);

    db.prepare(
      `INSERT INTO workspaces (id, name, slug, status, created_at, updated_at)
       VALUES ('ws-test-1', 'Test Workspace', 'test-ws', 'active', ?, ?)`,
    ).run(now, now);

    db.prepare(
      `INSERT INTO workspace_memberships (id, workspace_id, user_id, role, created_at, updated_at)
       VALUES ('wm-1', 'ws-test-1', 'u-admin', 'admin', ?, ?)`,
    ).run(now, now);

    db.prepare(
      `INSERT INTO auth_sessions (id, user_id, token_hash, client_type, created_at, updated_at, expires_at)
       VALUES ('sess-admin', 'u-admin', ?, 'web', ?, ?, '2099-01-01T00:00:00.000Z')`,
    ).run(adminTokenHash, now, now);

    db.prepare(
      `INSERT INTO agents (id, workspace_id, name, hostname, status, version, capabilities_json, enrolled_at, created_at, updated_at)
       VALUES ('ag-test-1', 'ws-test-1', 'Agent Mac 1', 'macbook.local', 'online', '2.0.0', '{}', ?, ?, ?)`,
    ).run(now, now, now);

    db.prepare(
      `INSERT INTO worker_plugins (id, display_name, description, publisher, supported_roles_json, supported_capabilities_json, status, created_at, updated_at)
       VALUES ('openai', 'OpenAI Worker Plugin', 'OpenAI Models', 'conclave', '["architect", "reviewer", "implementer"]', '["code_design", "code_review", "code_write"]', 'active', ?, ?)`,
    ).run(now, now);

    db.prepare(
      `INSERT INTO worker_plugins (id, display_name, description, publisher, supported_roles_json, supported_capabilities_json, status, created_at, updated_at)
       VALUES ('codex', 'Codex Worker Plugin', 'Codex CLI Agent', 'conclave', '["implementer"]', '["code_write"]', 'active', ?, ?)`,
    ).run(now, now);
  });

  it("configures multiple specialized workers sharing the same plugin", async () => {
    // 1. Create GPT Architect Worker
    const res1 = await worker.fetch(
      new Request("http://localhost/api/v2/workspaces/ws-test-1/workers", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${adminToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          id: "w-gpt-architect",
          agentId: "ag-test-1",
          pluginId: "openai",
          pluginVersionPolicy: "^1.0",
          name: "GPT Architect",
          roles: ["architect"],
          capabilities: ["code_design"],
          config: { model: "o3-mini", temperature: 0.2 },
          secretRefs: ["OPENAI_API_KEY"],
          billingMode: "api_metered",
          costMetadata: { currency: "USD", inputMicrosPerMillionTokens: 1100 },
          independenceKey: "key-gpt-arch",
          concurrencyLimit: 2,
          sessionPolicy: "isolated_workspace",
        }),
      }),
      mockEnv,
    );

    expect(res1.status).toBe(201);
    const body1 = (await res1.json()) as { worker: Record<string, unknown> };
    expect(body1.worker.id).toBe("w-gpt-architect");
    expect(body1.worker.name).toBe("GPT Architect");
    expect(body1.worker.roles).toEqual(["architect"]);
    expect(body1.worker.sessionPolicy).toBe("isolated_workspace");

    // 2. Create GPT Reviewer Worker on the SAME plugin
    const res2 = await worker.fetch(
      new Request("http://localhost/api/v2/workspaces/ws-test-1/workers", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${adminToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          id: "w-gpt-reviewer",
          agentId: "ag-test-1",
          pluginId: "openai",
          pluginVersionPolicy: "1.0.0",
          name: "GPT Reviewer",
          roles: ["reviewer"],
          capabilities: ["code_review"],
          config: { model: "gpt-4o", temperature: 0.0 },
          secretRefs: ["OPENAI_API_KEY"],
          billingMode: "subscription",
          independenceKey: "key-gpt-rev",
          concurrencyLimit: 4,
          sessionPolicy: "stateless",
        }),
      }),
      mockEnv,
    );

    expect(res2.status).toBe(201);
    const body2 = (await res2.json()) as { worker: Record<string, unknown> };
    expect(body2.worker.id).toBe("w-gpt-reviewer");
    expect(body2.worker.pluginId).toBe("openai");

    // 3. List all workers in workspace
    const listRes = await worker.fetch(
      new Request("http://localhost/api/v2/workspaces/ws-test-1/workers", {
        headers: { Authorization: `Bearer ${adminToken}` },
      }),
      mockEnv,
    );
    expect(listRes.status).toBe(200);
    const listBody = (await listRes.json()) as {
      workers: Array<Record<string, unknown>>;
    };
    expect(listBody.workers.length).toBe(2);

    const audits = db
      .prepare(
        "SELECT action, target_id FROM audit_log WHERE workspace_id = 'ws-test-1' ORDER BY created_at ASC",
      )
      .all() as Array<{ action: string; target_id: string }>;
    expect(audits.map((audit) => audit.action)).toEqual([
      "worker.created",
      "worker.created",
    ]);
    expect(audits.map((audit) => audit.target_id)).toEqual([
      "w-gpt-architect",
      "w-gpt-reviewer",
    ]);
  });

  it("updates and retrieves a worker configuration", async () => {
    // Create initial worker
    await worker.fetch(
      new Request("http://localhost/api/v2/workspaces/ws-test-1/workers", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${adminToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          id: "w-codex-main",
          agentId: "ag-test-1",
          pluginId: "codex",
          name: "Codex Main",
          roles: ["implementer"],
          capabilities: ["code_write"],
          concurrencyLimit: 1,
        }),
      }),
      mockEnv,
    );

    // Update worker concurrency and session policy
    const updateRes = await worker.fetch(
      new Request(
        "http://localhost/api/v2/workspaces/ws-test-1/workers/w-codex-main",
        {
          method: "PUT",
          headers: {
            Authorization: `Bearer ${adminToken}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            name: "Codex Main Implementer v2",
            concurrencyLimit: 3,
            sessionPolicy: "persistent_context",
          }),
        },
      ),
      mockEnv,
    );
    expect(updateRes.status).toBe(200);
    const updated = (await updateRes.json()) as {
      worker: Record<string, unknown>;
    };
    expect(updated.worker.name).toBe("Codex Main Implementer v2");
    expect(updated.worker.concurrencyLimit).toBe(3);
    expect(updated.worker.sessionPolicy).toBe("persistent_context");

    // Retrieve single worker
    const getRes = await worker.fetch(
      new Request(
        "http://localhost/api/v2/workspaces/ws-test-1/workers/w-codex-main",
        {
          headers: { Authorization: `Bearer ${adminToken}` },
        },
      ),
      mockEnv,
    );
    expect(getRes.status).toBe(200);
    const fetched = (await getRes.json()) as {
      worker: Record<string, unknown>;
    };
    expect(fetched.worker.id).toBe("w-codex-main");
    expect(fetched.worker.concurrencyLimit).toBe(3);
  });

  it("deletes a configured worker", async () => {
    // Create worker
    await worker.fetch(
      new Request("http://localhost/api/v2/workspaces/ws-test-1/workers", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${adminToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          id: "w-to-delete",
          agentId: "ag-test-1",
          pluginId: "codex",
          name: "Temporary Worker",
          roles: ["implementer"],
          capabilities: ["code_write"],
        }),
      }),
      mockEnv,
    );

    const deleteRes = await worker.fetch(
      new Request(
        "http://localhost/api/v2/workspaces/ws-test-1/workers/w-to-delete",
        {
          method: "DELETE",
          headers: { Authorization: `Bearer ${adminToken}` },
        },
      ),
      mockEnv,
    );
    expect(deleteRes.status).toBe(200);

    const getRes = await worker.fetch(
      new Request(
        "http://localhost/api/v2/workspaces/ws-test-1/workers/w-to-delete",
        {
          headers: { Authorization: `Bearer ${adminToken}` },
        },
      ),
      mockEnv,
    );
    expect(getRes.status).toBe(404);
  });

  it("rejects worker creation if agent does not exist or plugin does not exist", async () => {
    const invalidAgentRes = await worker.fetch(
      new Request("http://localhost/api/v2/workspaces/ws-test-1/workers", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${adminToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          id: "w-invalid-agent",
          agentId: "ag-nonexistent",
          pluginId: "codex",
          name: "Bad Worker",
          roles: ["implementer"],
          capabilities: ["code_write"],
        }),
      }),
      mockEnv,
    );
    expect(invalidAgentRes.status).toBe(404);

    const invalidPluginRes = await worker.fetch(
      new Request("http://localhost/api/v2/workspaces/ws-test-1/workers", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${adminToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          id: "w-invalid-plugin",
          agentId: "ag-test-1",
          pluginId: "nonexistent-plugin",
          name: "Bad Worker",
          roles: ["implementer"],
          capabilities: ["code_write"],
        }),
      }),
      mockEnv,
    );
    expect(invalidPluginRes.status).toBe(404);
  });

  it("rejects worker creation with an agent owned by another workspace", async () => {
    const now = new Date().toISOString();
    db.prepare(
      `INSERT INTO workspaces (id, name, slug, status, created_at, updated_at)
       VALUES ('ws-other', 'Other Workspace', 'other-ws', 'active', ?, ?)`,
    ).run(now, now);
    db.prepare(
      `INSERT INTO agents (id, workspace_id, name, hostname, status, version, capabilities_json, enrolled_at, created_at, updated_at)
       VALUES ('ag-other', 'ws-other', 'Other Agent', 'other.local', 'online', '2.0.0', '{}', ?, ?, ?)`,
    ).run(now, now, now);

    const response = await worker.fetch(
      new Request("http://localhost/api/v2/workspaces/ws-test-1/workers", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${adminToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          id: "w-cross-workspace",
          agentId: "ag-other",
          pluginId: "codex",
          name: "Cross Workspace Worker",
        }),
      }),
      mockEnv,
    );

    expect(response.status).toBe(404);
    expect(
      (
        db
          .prepare("SELECT COUNT(*) AS count FROM workers WHERE id = ?")
          .get("w-cross-workspace") as { count: number }
      ).count,
    ).toBe(0);
  });

  it("does not allow a workspace member to address fleet routes in another workspace", async () => {
    const response = await worker.fetch(
      new Request("http://localhost/api/v2/workspaces/ws-other/workers", {
        headers: { Authorization: `Bearer ${adminToken}` },
      }),
      mockEnv,
    );

    expect(response.status).toBe(404);
  });
});
