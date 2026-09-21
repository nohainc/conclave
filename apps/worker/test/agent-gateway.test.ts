import { describe, expect, it, beforeEach } from "vitest";
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import worker from "../src/index.js";
import {
  AgentGateway,
  assignmentContextMatches,
  assignmentIsActive,
} from "../src/agent-gateway.js";
import { hashToken } from "../../../packages/security/src/index.js";
import {
  AGENT_PROTOCOL_NAME,
  AGENT_PROTOCOL_VERSION,
  type AgentProtocolMessage,
} from "../../../packages/agent-protocol/src/index.js";

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
  CONCLAVE_AGENT_GATEWAY: DurableObjectNamespace;
}

describe("Agent Enrollment & Agent Gateway (Architecture v2)", () => {
  it("requires every assignment correlation field to match D1", () => {
    const row = {
      id: "assignment-1",
      workspace_id: "workspace-1",
      agent_id: "agent-1",
      worker_id: "worker-1",
      run_id: "run-1",
      task_id: "task-1",
      attempt_id: "attempt-1",
      idempotency_key: "idem-1",
    };
    const message = {
      workspaceId: "workspace-1",
      agentId: "agent-1",
      workerId: "worker-1",
      runId: "run-1",
      taskId: "task-1",
      attemptId: "attempt-1",
      assignmentId: "assignment-1",
      idempotencyKey: "idem-1",
    };
    expect(assignmentContextMatches(message, row)).toBe(true);
    expect(
      assignmentContextMatches({ ...message, taskId: "other-task" }, row),
    ).toBe(false);
  });

  it("rejects terminal assignments from internal Gateway operations", () => {
    expect(assignmentIsActive({ status: "dispatched" })).toBe(true);
    expect(assignmentIsActive({ status: "running" })).toBe(true);
    expect(assignmentIsActive({ status: "completed" })).toBe(false);
    expect(assignmentIsActive({ status: "cancelled" })).toBe(false);
  });
  let db: DatabaseSync;
  let d1: D1Database;
  let mockEnv: TestEnv;

  beforeEach(async () => {
    db = new DatabaseSync(":memory:");
    db.exec("PRAGMA foreign_keys = ON;");
    const sql = fs.readFileSync(schemaPath, "utf8");
    db.exec(sql);
    d1 = createD1Mock(db) as unknown as D1Database;

    const gatewayMap = new Map<string, AgentGateway>();

    const agentGatewayNamespace = {
      getByName(name: string) {
        if (!gatewayMap.has(name)) {
          const mockState = {
            storage: {
              get: async () => undefined,
              put: async () => {},
              delete: async () => true,
            },
          } as unknown as DurableObjectState;
          gatewayMap.set(
            name,
            new AgentGateway(mockState, { CONCLAVE_DB: d1 }),
          );
        }
        return {
          fetch: (req: Request) => gatewayMap.get(name)!.fetch(req),
        } as unknown as DurableObjectStub;
      },
    } as unknown as DurableObjectNamespace;

    mockEnv = {
      CONCLAVE_ENVIRONMENT: "development",
      CONCLAVE_DB: d1,
      CONCLAVE_AGENT_GATEWAY: agentGatewayNamespace,
    } as TestEnv;

    // Seed test user and workspace
    const now = new Date().toISOString();
    const adminToken = "tok_admin_123";
    const adminTokenHash = await hashToken(adminToken);

    db.prepare(
      `
      INSERT INTO users (id, email, display_name, status, created_at, updated_at)
      VALUES ('u-admin', 'admin@conclave.local', 'Admin User', 'active', ?, ?)
    `,
    ).run(now, now);

    db.prepare(
      `
      INSERT INTO workspaces (id, name, slug, status, created_at, updated_at)
      VALUES ('ws-test-1', 'Test Workspace', 'test-ws', 'active', ?, ?)
    `,
    ).run(now, now);

    db.prepare(
      `
      INSERT INTO workspace_memberships (id, workspace_id, user_id, role, created_at, updated_at)
      VALUES ('wm-1', 'ws-test-1', 'u-admin', 'admin', ?, ?)
    `,
    ).run(now, now);

    db.prepare(
      `
      INSERT INTO auth_sessions (id, user_id, token_hash, client_type, created_at, updated_at, expires_at)
      VALUES ('sess-admin', 'u-admin', ?, 'web', ?, ?, '2099-01-01T00:00:00.000Z')
    `,
    ).run(adminTokenHash, now, now);
  });

  it("fails closed for unauthenticated WebSocket upgrades", async () => {
    const gateway = new AgentGateway(
      {
        storage: {
          get: async () => undefined,
          put: async () => {},
          delete: async () => true,
        },
      } as unknown as DurableObjectState,
      { CONCLAVE_DB: d1 },
    );
    const response = await gateway.fetch(
      new Request(
        "http://localhost/agent?agentId=agent-1&workspaceId=ws-test-1",
        {
          headers: { Upgrade: "websocket" },
        },
      ),
    );
    expect(response.status).toBe(401);
  });

  it("creates agent enrollment tokens and lists them", async () => {
    const createReq = new Request(
      "http://localhost/api/v2/workspaces/ws-test-1/agent-enrollments",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer tok_admin_123",
        },
        body: JSON.stringify({ expiresHours: 48 }),
      },
    );

    const createRes = await worker.fetch(createReq, mockEnv);
    expect(createRes.status).toBe(201);
    const enrollment = (await createRes.json()) as {
      id: string;
      token: string;
      expiresAt: string;
    };
    expect(enrollment.id).toBeDefined();
    expect(enrollment.token).toContain("conclave_enroll_");

    // List enrollments
    const listReq = new Request(
      "http://localhost/api/v2/workspaces/ws-test-1/agent-enrollments",
      {
        method: "GET",
        headers: {
          Authorization: "Bearer tok_admin_123",
        },
      },
    );

    const listRes = await worker.fetch(listReq, mockEnv);
    expect(listRes.status).toBe(200);
    const listData = (await listRes.json()) as {
      enrollments: Array<{ id: string }>;
    };
    expect(listData.enrollments.length).toBe(1);
    expect(listData.enrollments[0]?.id).toBe(enrollment.id);
  });

  it("enrolls a new agent using a valid enrollment token", async () => {
    // 1. Create enrollment token
    const createReq = new Request(
      "http://localhost/api/v2/workspaces/ws-test-1/agent-enrollments",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer tok_admin_123",
        },
        body: JSON.stringify({ expiresHours: 24 }),
      },
    );
    const createRes = await worker.fetch(createReq, mockEnv);
    const enrollment = (await createRes.json()) as { token: string };

    // 2. Enroll agent
    const enrollReq = new Request("http://localhost/api/v2/agents/enroll", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        token: enrollment.token,
        name: "MacBook Build Runner",
        hostname: "macbook-pro.local",
        agentId: "agent-mbp-1",
      }),
    });

    const enrollRes = await worker.fetch(enrollReq, mockEnv);
    expect(enrollRes.status).toBe(201);
    const enrollData = (await enrollRes.json()) as {
      agentId: string;
      workspaceId: string;
      authToken: string;
    };

    expect(enrollData.agentId).toBe("agent-mbp-1");
    expect(enrollData.workspaceId).toBe("ws-test-1");
    expect(enrollData.authToken).toContain("conclave_agent_tok_");

    // 3. Verify agent in fleet list
    const fleetReq = new Request(
      "http://localhost/api/v2/workspaces/ws-test-1/agents",
      {
        headers: { Authorization: "Bearer tok_admin_123" },
      },
    );
    const fleetRes = await worker.fetch(fleetReq, mockEnv);
    expect(fleetRes.status).toBe(200);
    const fleetData = (await fleetRes.json()) as {
      agents: Array<{ name: string; status: string }>;
    };
    expect(fleetData.agents.length).toBe(1);
    expect(fleetData.agents[0]?.name).toBe("MacBook Build Runner");
    expect(fleetData.agents[0]?.status).toBe("enrolled");
  });

  it("rejects enrollment with invalid or revoked token", async () => {
    const invalidReq = new Request("http://localhost/api/v2/agents/enroll", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        token: "conclave_enroll_nonexistent",
      }),
    });

    const invalidRes = await worker.fetch(invalidReq, mockEnv);
    expect(invalidRes.status).toBe(401);
  });

  it("handles agent protocol messages via HTTP fallback", async () => {
    // 1. Enroll agent
    const createReq = new Request(
      "http://localhost/api/v2/workspaces/ws-test-1/agent-enrollments",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer tok_admin_123",
        },
        body: JSON.stringify({}),
      },
    );
    const createRes = await worker.fetch(createReq, mockEnv);
    const enrollment = (await createRes.json()) as { token: string };

    const enrollReq = new Request("http://localhost/api/v2/agents/enroll", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        token: enrollment.token,
        agentId: "agent-http-1",
      }),
    });
    const enrollRes = await worker.fetch(enrollReq, mockEnv);
    const { authToken } = (await enrollRes.json()) as { authToken: string };

    // 2. Send agent.hello
    const helloMessage: AgentProtocolMessage = {
      protocol: AGENT_PROTOCOL_NAME,
      protocolVersion: AGENT_PROTOCOL_VERSION,
      messageId: "msg-hello-1",
      timestamp: new Date().toISOString(),
      type: "agent.hello",
      payload: {
        agentId: "agent-http-1",
        workspaceId: "ws-test-1",
        name: "Test Agent",
        hostname: "test-host",
        agentVersion: "0.2.0",
        capabilities: {
          os: "macos",
          arch: "arm64",
          agentVersion: "0.2.0",
          supportedRuntimes: ["node", "git"],
          maxConcurrentWorkers: 4,
        },
      },
    };

    const helloReq = new Request(
      "http://localhost/api/v2/agent-protocol/messages",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${authToken}`,
        },
        body: JSON.stringify(helloMessage),
      },
    );

    const helloRes = await worker.fetch(helloReq, mockEnv);
    expect(helloRes.status).toBe(200);
    const helloAck = (await helloRes.json()) as AgentProtocolMessage;
    expect(helloAck.type).toBe("agent.hello.ack");
  });
});
