import { describe, expect, it, beforeEach } from "vitest";
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import worker from "../src/index.js";
import {
  selectEnsembleCandidateWorkers,
  dispatchEnsembleTaskAssignment,
} from "../src/ensemble-dispatcher.js";
import type { AssignmentDispatcherEnv } from "../src/assignment-dispatcher.js";
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

describe("Multi-Agent Ensemble Dispatcher (Cloud -> Multi-Agent -> Workers)", () => {
  let db: DatabaseSync;
  let d1: D1Database;
  const adminToken = "tok_admin_ensemble_123";
  const dispatchedAssignments: Array<{
    agentId: string;
    assignmentId: string;
  }> = [];

  const mockGatewayStub = {
    async fetch(url: string, init?: RequestInit) {
      const parsedUrl = new URL(url);
      if (parsedUrl.pathname === "/dispatch-assignment") {
        const body = JSON.parse(String(init?.body || "{}")) as {
          agentId: string;
          assignmentId: string;
        };
        dispatchedAssignments.push({
          agentId: body.agentId,
          assignmentId: body.assignmentId,
        });
        db.prepare(
          `UPDATE worker_assignments
           SET status = 'completed',
               output_json = ?,
               updated_at = ?
           WHERE id = ?`,
        ).run(
          JSON.stringify({
            status: "completed",
            summary: "Fixture Agent completed the assignment",
            output: { accepted: true },
            artifactIds: [],
          }),
          new Date().toISOString(),
          body.assignmentId,
        );
        return new Response(
          JSON.stringify({
            accepted: true,
            assignedAt: new Date().toISOString(),
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      return new Response("Not found", { status: 404 });
    },
  };

  const mockGatewayNamespace = {
    idFromName: (name: string) => ({ toString: () => `id-${name}` }),
    get: () => mockGatewayStub,
  } as unknown as DurableObjectNamespace;

  let env: AssignmentDispatcherEnv;

  beforeEach(async () => {
    db = new DatabaseSync(":memory:");
    db.exec("PRAGMA foreign_keys = ON;");
    const sql = fs.readFileSync(schemaPath, "utf8");
    db.exec(sql);
    d1 = createD1Mock(db) as unknown as D1Database;
    dispatchedAssignments.length = 0;

    env = {
      CONCLAVE_ENVIRONMENT: "development",
      CONCLAVE_DB: d1,
      AGENT_GATEWAY: mockGatewayNamespace,
      CONCLAVE_AGENT_GATEWAY: mockGatewayNamespace,
    } as unknown as AssignmentDispatcherEnv;

    const now = new Date().toISOString();
    const adminTokenHash = await hashToken(adminToken);

    // Seed test user, workspace, project, goal, run, phase, task
    db.prepare(
      `INSERT INTO users (id, email, display_name, status, created_at, updated_at)
       VALUES ('u-admin', 'admin@conclave.local', 'Admin User', 'active', ?, ?)`,
    ).run(now, now);

    db.prepare(
      `INSERT INTO workspaces (id, name, slug, status, created_at, updated_at)
       VALUES ('ws-1', 'Test Workspace', 'test-ws', 'active', ?, ?)`,
    ).run(now, now);

    db.prepare(
      `INSERT INTO workspace_memberships (id, workspace_id, user_id, role, created_at, updated_at)
       VALUES ('wm-1', 'ws-1', 'u-admin', 'admin', ?, ?)`,
    ).run(now, now);

    db.prepare(
      `INSERT INTO auth_sessions (id, user_id, token_hash, client_type, created_at, updated_at, expires_at)
       VALUES ('sess-admin', 'u-admin', ?, 'web', ?, ?, '2099-01-01T00:00:00.000Z')`,
    ).run(adminTokenHash, now, now);

    db.prepare(
      `INSERT INTO projects (id, workspace_id, name, description, created_at, updated_at)
       VALUES ('proj-1', 'ws-1', 'Project 1', 'Test project', ?, ?)`,
    ).run(now, now);

    db.prepare(
      `INSERT INTO goals (id, workspace_id, project_id, original_message, objective, status, created_at, updated_at)
       VALUES ('goal-1', 'ws-1', 'proj-1', 'Design Architecture', 'Design Architecture', 'running', ?, ?)`,
    ).run(now, now);

    db.prepare(
      `INSERT INTO runs (id, workspace_id, project_id, goal_id, policy_snapshot_json, status, created_at, updated_at)
       VALUES ('run-1', 'ws-1', 'proj-1', 'goal-1', '{}', 'running', ?, ?)`,
    ).run(now, now);

    db.prepare(
      `INSERT INTO phases (id, run_id, name, purpose, sequence, status, created_at, updated_at)
       VALUES ('ph-1', 'run-1', 'Phase 1', 'Design', 0, 'running', ?, ?)`,
    ).run(now, now);

    db.prepare(
      `INSERT INTO tasks (id, phase_id, role, objective, capabilities_json, status, created_at, updated_at)
       VALUES ('task-arch', 'ph-1', 'architect', 'Design Architecture', '["architecture"]', 'ready', ?, ?)`,
    ).run(now, now);

    // Seed 3 Agents on distinct machines:
    // Agent 1: MacBook
    db.prepare(
      `INSERT INTO agents (id, workspace_id, name, hostname, status, version, capabilities_json, enrolled_at, created_at, updated_at)
       VALUES ('ag-macbook', 'ws-1', 'MacBook Pro Agent', 'macbook.local', 'online', '2.0.0', '[]', ?, ?, ?)`,
    ).run(now, now, now);

    // Agent 2: Linux Server
    db.prepare(
      `INSERT INTO agents (id, workspace_id, name, hostname, status, version, capabilities_json, enrolled_at, created_at, updated_at)
       VALUES ('ag-linux', 'ws-1', 'Linux Server Agent', 'ubuntu-srv.cloud', 'online', '2.0.0', '[]', ?, ?, ?)`,
    ).run(now, now, now);

    // Agent 3: Web Worker Client
    db.prepare(
      `INSERT INTO agents (id, workspace_id, name, hostname, status, version, capabilities_json, enrolled_at, created_at, updated_at)
       VALUES ('ag-web', 'ws-1', 'Web Worker Agent', 'browser-client.local', 'online', '2.0.0', '[]', ?, ?, ?)`,
    ).run(now, now, now);

    // Seed worker plugins
    db.prepare(
      `INSERT INTO worker_plugins (id, display_name, description, publisher, supported_roles_json, supported_capabilities_json, status, created_at, updated_at)
       VALUES ('conclave.claude-code', 'Claude Code', 'Claude plugin', 'Anthropic', '["architect","reviewer","implementer"]', '["architecture","code_review"]', 'active', ?, ?)`,
    ).run(now, now);

    db.prepare(
      `INSERT INTO worker_plugins (id, display_name, description, publisher, supported_roles_json, supported_capabilities_json, status, created_at, updated_at)
       VALUES ('conclave.openai-api', 'OpenAI API', 'OpenAI plugin', 'OpenAI', '["architect","synthesizer","implementer"]', '["architecture","synthesis"]', 'active', ?, ?)`,
    ).run(now, now);

    db.prepare(
      `INSERT INTO worker_plugins (id, display_name, description, publisher, supported_roles_json, supported_capabilities_json, status, created_at, updated_at)
       VALUES ('conclave.echo-worker', 'Echo Worker', 'Deterministic test worker', 'Conclave', '["architect","evaluator","reviewer","implementer"]', '["architecture","evaluation","code_review"]', 'active', ?, ?)`,
    ).run(now, now);

    // Seed Workers on the disparate machines:
    // Worker A: Claude on MacBook
    db.prepare(
      `INSERT INTO workers (id, workspace_id, agent_id, plugin_id, plugin_version_policy, name, roles_json, capabilities_json, config_json, secret_refs_json, billing_mode, cost_metadata_json, independence_key, concurrency_limit, session_policy, enabled, status, created_at, updated_at)
       VALUES ('w-claude-mac', 'ws-1', 'ag-macbook', 'conclave.claude-code', 'latest', 'Claude on MacBook', '["architect"]', '["architecture"]', '{}', '[]', 'local_compute', '{}', 'indep-claude-mac', 1, 'stateless', 1, 'available', ?, ?)`,
    ).run(now, now);

    // Worker B: GPT on Linux Server
    db.prepare(
      `INSERT INTO workers (id, workspace_id, agent_id, plugin_id, plugin_version_policy, name, roles_json, capabilities_json, config_json, secret_refs_json, billing_mode, cost_metadata_json, independence_key, concurrency_limit, session_policy, enabled, status, created_at, updated_at)
       VALUES ('w-gpt-linux', 'ws-1', 'ag-linux', 'conclave.openai-api', 'latest', 'GPT on Linux', '["architect"]', '["architecture"]', '{}', '[]', 'local_compute', '{}', 'indep-gpt-linux', 1, 'stateless', 1, 'available', ?, ?)`,
    ).run(now, now);

    // Worker C: ChatGPT Web Worker
    db.prepare(
      `INSERT INTO workers (id, workspace_id, agent_id, plugin_id, plugin_version_policy, name, roles_json, capabilities_json, config_json, secret_refs_json, billing_mode, cost_metadata_json, independence_key, concurrency_limit, session_policy, enabled, status, created_at, updated_at)
       VALUES ('w-web-worker', 'ws-1', 'ag-web', 'conclave.echo-worker', 'latest', 'ChatGPT Web Worker', '["architect"]', '["architecture"]', '{}', '[]', 'local_compute', '{}', 'indep-web', 1, 'stateless', 1, 'available', ?, ?)`,
    ).run(now, now);

    // Synthesizer Worker
    db.prepare(
      `INSERT INTO workers (id, workspace_id, agent_id, plugin_id, plugin_version_policy, name, roles_json, capabilities_json, config_json, secret_refs_json, billing_mode, cost_metadata_json, independence_key, concurrency_limit, session_policy, enabled, status, created_at, updated_at)
       VALUES ('w-synthesizer', 'ws-1', 'ag-linux', 'conclave.openai-api', 'latest', 'Consensus Synthesizer', '["synthesizer"]', '["synthesis"]', '{}', '[]', 'local_compute', '{}', 'indep-synth', 1, 'stateless', 1, 'available', ?, ?)`,
    ).run(now, now);

    // Evaluator / Selector Worker
    db.prepare(
      `INSERT INTO workers (id, workspace_id, agent_id, plugin_id, plugin_version_policy, name, roles_json, capabilities_json, config_json, secret_refs_json, billing_mode, cost_metadata_json, independence_key, concurrency_limit, session_policy, enabled, status, created_at, updated_at)
       VALUES ('w-evaluator', 'ws-1', 'ag-macbook', 'conclave.echo-worker', 'latest', 'Architecture Evaluator', '["evaluator"]', '["evaluation"]', '{}', '[]', 'local_compute', '{}', 'indep-eval', 1, 'stateless', 1, 'available', ?, ?)`,
    ).run(now, now);
  });

  describe("selectEnsembleCandidateWorkers", () => {
    it("selects 3 candidate workers across disparate agents with distinct independence keys", async () => {
      const candidates = await selectEnsembleCandidateWorkers(
        d1,
        "ws-1",
        {
          id: "task-arch",
          role: "architect",
          objective: "Design Architecture",
          capabilities: ["architecture"],
        },
        3,
      );

      expect(candidates).toHaveLength(3);
      const agentIds = candidates.map((c) => c.agentId);
      expect(agentIds).toContain("ag-macbook");
      expect(agentIds).toContain("ag-linux");
      expect(agentIds).toContain("ag-web");

      const indepKeys = candidates.map((c) => c.independenceKey);
      expect(new Set(indepKeys).size).toBe(3);
    });

    it("excludes offline Agents even when candidate IDs are explicit", async () => {
      db.prepare(
        "UPDATE agents SET status = 'offline' WHERE id = 'ag-linux'",
      ).run();

      const candidates = await selectEnsembleCandidateWorkers(
        d1,
        "ws-1",
        {
          id: "task-arch",
          role: "architect",
          objective: "Design Architecture",
          capabilities: ["architecture"],
        },
        3,
        ["w-claude-mac", "w-gpt-linux", "w-web-worker"],
      );

      expect(candidates.map((candidate) => candidate.id)).toEqual([
        "w-claude-mac",
        "w-web-worker",
      ]);
    });
  });

  describe("dispatchEnsembleTaskAssignment", () => {
    it("dispatches parallel ensemble across 3 machines and records assignments in D1", async () => {
      const ensembleRes = await dispatchEnsembleTaskAssignment(env, {
        workspaceId: "ws-1",
        runId: "run-1",
        taskId: "task-arch",
        task: {
          id: "task-arch",
          role: "architect",
          objective: "Design Architecture",
          capabilities: ["architecture"],
        },
        policy: { mode: "parallel" },
      });

      expect(ensembleRes.mode).toBe("parallel");
      expect(ensembleRes.candidates).toHaveLength(3);
      expect(dispatchedAssignments).toHaveLength(3);

      // Verify attempts in D1
      const attempts = db
        .prepare("SELECT * FROM attempts WHERE task_id = 'task-arch'")
        .all() as Record<string, unknown>[];
      expect(attempts).toHaveLength(3);

      // Verify worker_assignments in D1
      const assignments = db
        .prepare("SELECT * FROM worker_assignments WHERE task_id = 'task-arch'")
        .all() as Record<string, unknown>[];
      expect(assignments).toHaveLength(3);
      const assignedAgents = assignments.map((a) => String(a.agent_id));
      expect(assignedAgents).toContain("ag-macbook");
      expect(assignedAgents).toContain("ag-linux");
      expect(assignedAgents).toContain("ag-web");
    });

    it("dispatches synthesize ensemble with independent synthesizer worker", async () => {
      const ensembleRes = await dispatchEnsembleTaskAssignment(env, {
        workspaceId: "ws-1",
        runId: "run-1",
        taskId: "task-arch",
        task: {
          id: "task-arch",
          role: "architect",
          objective: "Design Architecture",
          capabilities: ["architecture"],
        },
        policy: { mode: "synthesize" },
        synthesizerWorkerId: "w-synthesizer",
      });

      expect(ensembleRes.mode).toBe("synthesize");
      expect(ensembleRes.candidates).toHaveLength(3);
      expect(ensembleRes.decisionResult).not.toBeNull();
      // Total dispatched assignments: 3 candidates + 1 synthesizer = 4
      expect(dispatchedAssignments).toHaveLength(4);
    });

    it("dispatches compare_and_select ensemble with selector worker", async () => {
      const ensembleRes = await dispatchEnsembleTaskAssignment(env, {
        workspaceId: "ws-1",
        runId: "run-1",
        taskId: "task-arch",
        task: {
          id: "task-arch",
          role: "architect",
          objective: "Design Architecture",
          capabilities: ["architecture"],
        },
        policy: { mode: "compare_and_select" },
        selectorWorkerId: "w-evaluator",
      });

      expect(ensembleRes.mode).toBe("compare_and_select");
      expect(ensembleRes.selectedCandidateIndex).toBeDefined();
      expect(ensembleRes.selectedWorkerId).toBeDefined();
    });
  });

  describe("REST Endpoint (/api/v2/workspaces/:ws/tasks/:id/ensemble-dispatch)", () => {
    it("coordinates multi-agent ensemble via REST POST endpoint", async () => {
      const res = await worker.fetch(
        new Request(
          "https://conclave.local/api/v2/workspaces/ws-1/tasks/task-arch/ensemble-dispatch",
          {
            method: "POST",
            headers: {
              Authorization: `Bearer ${adminToken}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              policy: { mode: "parallel" },
              capabilities: ["architecture"],
            }),
          },
        ),
        env as unknown as Env,
      );

      expect(res.status).toBe(200);
      const body = (await res.json()) as {
        ensemble: {
          mode: string;
          candidates: Array<{ workerId: string; agentId: string }>;
        };
      };
      expect(body.ensemble.mode).toBe("parallel");
      expect(body.ensemble.candidates).toHaveLength(3);
    });
  });
});
