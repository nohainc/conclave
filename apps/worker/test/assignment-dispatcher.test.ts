import { describe, expect, it, beforeEach } from "vitest";
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import worker from "../src/index.js";
import {
  selectWorkerForTask,
  dispatchTaskAssignment,
  recordAssignmentResult,
  recordAssignmentError,
  cancelTaskAssignment,
  type AssignmentDispatcherEnv,
} from "../src/assignment-dispatcher.js";
import { hashToken } from "../../../packages/security/src/index.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const schemaPath = path.resolve(
  __dirname,
  "../migrations/0001_conclave_v3.sql",
);

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

describe("Assignment Dispatcher (Cloud -> Agent -> Worker)", () => {
  let db: DatabaseSync;
  let d1: D1Database;
  const adminToken = "tok_admin_dispatcher_123";
  let lastDispatchedPayload: unknown = null;
  let lastCancelledPayload: unknown = null;
  let gatewayShouldReject = false;

  const mockGatewayStub = {
    async fetch(url: string, init?: RequestInit) {
      const parsedUrl = new URL(url);
      if (parsedUrl.pathname === "/dispatch-assignment") {
        if (gatewayShouldReject) {
          return new Response(
            JSON.stringify({ accepted: false, reason: "Agent at capacity" }),
            { status: 200, headers: { "Content-Type": "application/json" } },
          );
        }
        lastDispatchedPayload = JSON.parse(String(init?.body || "{}"));
        return new Response(
          JSON.stringify({
            accepted: true,
            assignedAt: new Date().toISOString(),
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (parsedUrl.pathname === "/cancel-assignment") {
        lastCancelledPayload = JSON.parse(String(init?.body || "{}"));
        return new Response(JSON.stringify({ cancelled: true }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
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
    lastDispatchedPayload = null;
    lastCancelledPayload = null;
    gatewayShouldReject = false;

    env = {
      CONCLAVE_ENVIRONMENT: "development",
      CONCLAVE_DB: d1,
      CONCLAVE_HOST_GATEWAY: mockGatewayNamespace,
    } as unknown as AssignmentDispatcherEnv;

    const now = new Date().toISOString();
    const adminTokenHash = await hashToken(adminToken);

    // Seed test entities
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
       VALUES ('goal-1', 'ws-1', 'proj-1', 'Build feature X', 'Build feature X', 'running', ?, ?)`,
    ).run(now, now);

    db.prepare(
      `INSERT INTO runs (id, workspace_id, project_id, goal_id, policy_snapshot_json, status, created_at, updated_at)
       VALUES ('run-1', 'ws-1', 'proj-1', 'goal-1', '{}', 'running', ?, ?)`,
    ).run(now, now);

    db.prepare(
      `INSERT INTO phases (id, run_id, name, purpose, sequence, status, created_at, updated_at)
       VALUES ('ph-1', 'run-1', 'Phase 1', 'Implementation', 0, 'running', ?, ?)`,
    ).run(now, now);

    db.prepare(
      `INSERT INTO tasks (id, phase_id, role, objective, status, created_at, updated_at)
       VALUES ('task-1', 'ph-1', 'implementer', 'Build feature X', 'ready', ?, ?)`,
    ).run(now, now);

    // Seed agents
    db.prepare(
      `INSERT INTO agents (id, workspace_id, name, hostname, status, version, capabilities_json, enrolled_at, created_at, updated_at)
       VALUES ('ag-1', 'ws-1', 'Agent Mac 1', 'mac1.local', 'online', '2.0.0', '[]', ?, ?, ?)`,
    ).run(now, now, now);

    db.prepare(
      `INSERT INTO agents (id, workspace_id, name, hostname, status, version, capabilities_json, enrolled_at, created_at, updated_at)
       VALUES ('ag-offline', 'ws-1', 'Agent Offline', 'offline.local', 'offline', '2.0.0', '[]', ?, ?, ?)`,
    ).run(now, now, now);

    // Seed plugins
    db.prepare(
      `INSERT INTO worker_plugins (id, display_name, description, publisher, supported_roles_json, supported_capabilities_json, status, created_at, updated_at)
       VALUES ('conclave.echo-worker', 'Echo Worker', 'Deterministic test worker', 'Conclave Core', '["implementer","reviewer"]', '["test_echo"]', 'active', ?, ?)`,
    ).run(now, now);

    // Seed workers:
    // worker-1: Implementer (independence_key: key-worker-1)
    db.prepare(
      `INSERT INTO workers (id, workspace_id, agent_id, plugin_id, plugin_version_policy, name, roles_json, capabilities_json, config_json, secret_refs_json, billing_mode, cost_metadata_json, independence_key, concurrency_limit, session_policy, enabled, status, created_at, updated_at)
       VALUES ('worker-implementer', 'ws-1', 'ag-1', 'conclave.echo-worker', 'latest', 'Echo Implementer', '["implementer"]', '["test_echo"]', '{}', '[]', 'local_compute', '{}', 'indep-impl', 1, 'stateless', 1, 'available', ?, ?)`,
    ).run(now, now);

    // worker-2: Reviewer (independence_key: key-worker-2)
    db.prepare(
      `INSERT INTO workers (id, workspace_id, agent_id, plugin_id, plugin_version_policy, name, roles_json, capabilities_json, config_json, secret_refs_json, billing_mode, cost_metadata_json, independence_key, concurrency_limit, session_policy, enabled, status, created_at, updated_at)
       VALUES ('worker-reviewer', 'ws-1', 'ag-1', 'conclave.echo-worker', 'latest', 'Echo Reviewer', '["reviewer"]', '["test_echo"]', '{}', '[]', 'local_compute', '{}', 'indep-rev', 1, 'stateless', 1, 'available', ?, ?)`,
    ).run(now, now);
  });

  describe("selectWorkerForTask", () => {
    it("selects worker matching role and capabilities on online agent", async () => {
      const selected = await selectWorkerForTask(d1, "ws-1", {
        id: "task-1",
        role: "implementer",
        objective: "Build feature X",
        capabilities: ["test_echo"],
      });

      expect(selected).not.toBeNull();
      expect(selected?.id).toBe("worker-implementer");
      expect(selected?.agentId).toBe("ag-1");
      expect(selected?.pluginId).toBe("conclave.echo-worker");
    });

    it("does not select a worker at its concurrency limit", async () => {
      const now = new Date().toISOString();
      db.prepare(
        `INSERT INTO attempts (id, task_id, worker_id, attempt_number, input_snapshot_json, status, started_at)
         VALUES ('att-active', 'task-1', 'worker-implementer', 1, '{}', 'running', ?)`,
      ).run(now);
      db.prepare(
        `INSERT INTO worker_assignments (id, workspace_id, run_id, task_id, attempt_id, agent_id, worker_id, plugin_id, resolved_plugin_version, status, input_json, idempotency_key, timeout_ms, created_at, updated_at)
         VALUES ('asg-active', 'ws-1', 'run-1', 'task-1', 'att-active', 'ag-1', 'worker-implementer', 'conclave.echo-worker', 'latest', 'running', '{}', 'idem-active', 60000, ?, ?)`,
      ).run(now, now);

      const selected = await selectWorkerForTask(d1, "ws-1", {
        id: "task-next",
        role: "implementer",
        objective: "Build another feature",
        capabilities: ["test_echo"],
      });
      expect(selected).toBeNull();
    });

    it("enforces anti-collusion by excluding specified independence keys for reviewer", async () => {
      // Implementer has independence_key 'indep-impl'.
      // When verifying, we exclude 'indep-impl'.
      const selected = await selectWorkerForTask(
        d1,
        "ws-1",
        {
          id: "task-review",
          role: "reviewer",
          objective: "Review code",
          capabilities: ["test_echo"],
        },
        {
          excludeIndependenceKeys: ["indep-impl"],
        },
      );

      expect(selected).not.toBeNull();
      expect(selected?.id).toBe("worker-reviewer");
      expect(selected?.independenceKey).toBe("indep-rev");
    });

    it("returns null if no worker matches required role or capability", async () => {
      const selected = await selectWorkerForTask(d1, "ws-1", {
        id: "task-unknown",
        role: "non_existent_role",
        objective: "Something impossible",
        capabilities: ["quantum_compute"],
      });

      expect(selected).toBeNull();
    });

    it("does not select an explicitly requested offline worker", async () => {
      const selected = await selectWorkerForTask(
        d1,
        "ws-1",
        {
          id: "task-offline",
          role: "implementer",
          objective: "Build feature X",
        },
        { explicitWorkerId: "worker-implementer" },
      );

      db.prepare(
        "UPDATE agents SET status = 'offline' WHERE id = 'ag-1'",
      ).run();

      const offlineSelected = await selectWorkerForTask(
        d1,
        "ws-1",
        {
          id: "task-offline",
          role: "implementer",
          objective: "Build feature X",
        },
        { explicitWorkerId: "worker-implementer" },
      );

      expect(selected).not.toBeNull();
      expect(offlineSelected).toBeNull();
    });
  });

  describe("dispatchTaskAssignment", () => {
    it("creates Attempt & WorkerAssignment in D1 and dispatches over Gateway DO", async () => {
      const result = await dispatchTaskAssignment(env, {
        workspaceId: "ws-1",
        runId: "run-1",
        taskId: "task-1",
        task: {
          id: "task-1",
          role: "implementer",
          objective: "Build feature X",
          capabilities: ["test_echo"],
          input: { key: "value" },
        },
      });

      expect(result.status).toBe("dispatched");
      expect(result.accepted).toBe(true);
      expect(result.workerId).toBe("worker-implementer");
      expect(result.assignmentId).toContain("asg-task-1-1");

      // Verify Attempt created in D1
      const attemptRow = db
        .prepare("SELECT * FROM attempts WHERE task_id = 'task-1'")
        .get() as Record<string, unknown>;
      expect(attemptRow).toBeDefined();
      expect(attemptRow.status).toBe("running");
      expect(attemptRow.worker_id).toBe("worker-implementer");

      // Verify WorkerAssignment created in D1
      const assignmentRow = db
        .prepare("SELECT * FROM worker_assignments WHERE task_id = 'task-1'")
        .get() as Record<string, unknown>;
      expect(assignmentRow).toBeDefined();
      expect(assignmentRow.status).toBe("dispatched");
      expect(assignmentRow.agent_id).toBe("ag-1");

      // Verify Task status updated to 'running'
      const taskRow = db
        .prepare("SELECT * FROM tasks WHERE id = 'task-1'")
        .get() as Record<string, unknown>;
      expect(taskRow.status).toBe("running");

      // Verify Gateway received payload
      expect(lastDispatchedPayload).toBeDefined();
      expect(
        (lastDispatchedPayload as Record<string, unknown>).assignmentId,
      ).toBe(result.assignmentId);
    });

    it("handles Agent rejection gracefully by marking assignment failed", async () => {
      gatewayShouldReject = true;

      const result = await dispatchTaskAssignment(env, {
        workspaceId: "ws-1",
        runId: "run-1",
        taskId: "task-1",
        task: {
          id: "task-1",
          role: "implementer",
          objective: "Build feature X",
        },
      });

      expect(result.status).toBe("failed");
      expect(result.accepted).toBe(false);
      expect(result.error).toContain("Agent at capacity");

      // Verify assignment marked failed in D1
      const assignmentRow = db
        .prepare("SELECT * FROM worker_assignments WHERE task_id = 'task-1'")
        .get() as Record<string, unknown>;
      expect(assignmentRow.status).toBe("failed");
    });

    it("fails closed when no Host Gateway is configured", async () => {
      const result = await dispatchTaskAssignment(
        { ...env, CONCLAVE_HOST_GATEWAY: undefined },
        {
          workspaceId: "ws-1",
          runId: "run-1",
          taskId: "task-1",
          task: {
            id: "task-1",
            role: "implementer",
            objective: "Build feature X",
          },
        },
      );

      expect(result.status).toBe("failed");
      expect(result.accepted).toBe(false);
      expect(result.error).toContain("Host Gateway is not configured");
      const assignmentRow = db
        .prepare(
          "SELECT status FROM worker_assignments WHERE task_id = 'task-1'",
        )
        .get() as { status: string };
      expect(assignmentRow.status).toBe("failed");
    });
  });

  describe("recordAssignmentResult & recordAssignmentError", () => {
    it("transitions assignment, attempt, and task to completed on result", async () => {
      const dispatchResult = await dispatchTaskAssignment(env, {
        workspaceId: "ws-1",
        runId: "run-1",
        taskId: "task-1",
        task: {
          id: "task-1",
          role: "implementer",
          objective: "Build feature X",
        },
      });

      await recordAssignmentResult(d1, dispatchResult.assignmentId, {
        status: "completed",
        output: { result: "Success" },
        artifactIds: ["art-1", "art-2"],
        summary: "Feature X implemented successfully",
      });

      const assignmentRow = db
        .prepare("SELECT * FROM worker_assignments WHERE id = ?")
        .get(dispatchResult.assignmentId) as Record<string, unknown>;
      expect(assignmentRow.status).toBe("completed");

      const attemptRow = db
        .prepare("SELECT * FROM attempts WHERE id = ?")
        .get(dispatchResult.attemptId) as Record<string, unknown>;
      expect(attemptRow.status).toBe("completed");
      expect(attemptRow.finished_at).not.toBeNull();
      expect(String(attemptRow.output_artifact_ids_json)).toContain("art-1");

      const taskRow = db
        .prepare("SELECT * FROM tasks WHERE id = 'task-1'")
        .get() as Record<string, unknown>;
      expect(taskRow.status).toBe("completed");

      await recordAssignmentResult(d1, dispatchResult.assignmentId, {
        status: "completed",
        output: { result: "late replacement" },
        artifactIds: ["late-artifact"],
        summary: "Late duplicate",
      });
      const stableAssignment = db
        .prepare("SELECT output_json FROM worker_assignments WHERE id = ?")
        .get(dispatchResult.assignmentId) as { output_json: string };
      expect(stableAssignment.output_json).toContain("Feature X implemented");

      await recordAssignmentError(d1, dispatchResult.assignmentId, {
        status: "failed",
        error: {
          code: "LATE_ERROR",
          message: "must not regress completed state",
          retryable: false,
        },
      });
      expect(
        (
          db
            .prepare("SELECT status FROM worker_assignments WHERE id = ?")
            .get(dispatchResult.assignmentId) as { status: string }
        ).status,
      ).toBe("completed");
    });

    it("transitions assignment, attempt, and task to failed on error", async () => {
      const dispatchResult = await dispatchTaskAssignment(env, {
        workspaceId: "ws-1",
        runId: "run-1",
        taskId: "task-1",
        task: {
          id: "task-1",
          role: "implementer",
          objective: "Build feature X",
        },
      });

      await recordAssignmentError(d1, dispatchResult.assignmentId, {
        status: "failed",
        error: {
          code: "TEST_FAILED",
          message: "Unit test failed on line 42",
          retryable: false,
        },
      });

      const assignmentRow = db
        .prepare("SELECT * FROM worker_assignments WHERE id = ?")
        .get(dispatchResult.assignmentId) as Record<string, unknown>;
      expect(assignmentRow.status).toBe("failed");

      const attemptRow = db
        .prepare("SELECT * FROM attempts WHERE id = ?")
        .get(dispatchResult.attemptId) as Record<string, unknown>;
      expect(attemptRow.status).toBe("failed");
      expect(attemptRow.failure_class).toBe("TEST_FAILED");

      const taskRow = db
        .prepare("SELECT * FROM tasks WHERE id = 'task-1'")
        .get() as Record<string, unknown>;
      expect(taskRow.status).toBe("failed");
    });
  });

  describe("cancelTaskAssignment", () => {
    it("cancels running assignment and informs Host Gateway", async () => {
      const dispatchResult = await dispatchTaskAssignment(env, {
        workspaceId: "ws-1",
        runId: "run-1",
        taskId: "task-1",
        task: {
          id: "task-1",
          role: "implementer",
          objective: "Build feature X",
        },
      });

      const cancelResult = await cancelTaskAssignment(
        env,
        "ws-1",
        dispatchResult.assignmentId,
        "User cancelled run",
      );

      expect(cancelResult.cancelled).toBe(true);

      const assignmentRow = db
        .prepare("SELECT * FROM worker_assignments WHERE id = ?")
        .get(dispatchResult.assignmentId) as Record<string, unknown>;
      expect(assignmentRow.status).toBe("cancelled");

      const taskRow = db
        .prepare("SELECT * FROM tasks WHERE id = 'task-1'")
        .get() as Record<string, unknown>;
      expect(taskRow.status).toBe("cancelled");

      expect(lastCancelledPayload).toBeDefined();
      expect(
        (lastCancelledPayload as Record<string, unknown>).assignmentId,
      ).toBe(dispatchResult.assignmentId);
    });
  });

  describe("REST Endpoints (/api/v2/workspaces/:ws/tasks/:id/dispatch & cancel)", () => {
    it("dispatches task via REST POST endpoint", async () => {
      const res = await worker.fetch(
        new Request(
          "https://conclave.local/api/v2/workspaces/ws-1/tasks/task-1/dispatch",
          {
            method: "POST",
            headers: {
              Authorization: `Bearer ${adminToken}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              capabilities: ["test_echo"],
            }),
          },
        ),
        env as unknown as Env,
      );

      expect(res.status).toBe(200);
      const body = (await res.json()) as {
        assignment: { status: string; workerId: string };
      };
      expect(body.assignment.status).toBe("dispatched");
      expect(body.assignment.workerId).toBe("worker-implementer");
    });

    it("does not dispatch a task belonging to another workspace", async () => {
      const now = new Date().toISOString();
      db.prepare(
        `INSERT INTO workspaces (id, name, slug, status, created_at, updated_at)
         VALUES ('ws-other', 'Other Workspace', 'other-ws', 'active', ?, ?)`,
      ).run(now, now);
      db.prepare(
        `INSERT INTO projects (id, workspace_id, name, description, created_at, updated_at)
         VALUES ('proj-other', 'ws-other', 'Other Project', '', ?, ?)`,
      ).run(now, now);
      db.prepare(
        `INSERT INTO goals (id, workspace_id, project_id, original_message, objective, status, created_at, updated_at)
         VALUES ('goal-other', 'ws-other', 'proj-other', 'Other', 'Other', 'running', ?, ?)`,
      ).run(now, now);
      db.prepare(
        `INSERT INTO runs (id, workspace_id, project_id, goal_id, policy_snapshot_json, status, created_at, updated_at)
         VALUES ('run-other', 'ws-other', 'proj-other', 'goal-other', '{}', 'running', ?, ?)`,
      ).run(now, now);
      db.prepare(
        `INSERT INTO phases (id, run_id, name, purpose, sequence, status, created_at, updated_at)
         VALUES ('phase-other', 'run-other', 'Other', 'Other', 0, 'running', ?, ?)`,
      ).run(now, now);
      db.prepare(
        `INSERT INTO tasks (id, phase_id, role, objective, capabilities_json, status, created_at, updated_at)
         VALUES ('task-other', 'phase-other', 'implementer', 'Other', '["test_echo"]', 'ready', ?, ?)`,
      ).run(now, now);

      const response = await worker.fetch(
        new Request(
          "https://conclave.local/api/v2/workspaces/ws-other/tasks/task-other/dispatch",
          {
            method: "POST",
            headers: {
              Authorization: `Bearer ${adminToken}`,
              "Content-Type": "application/json",
            },
          },
        ),
        env as unknown as Env,
      );

      expect(response.status).toBe(404);
      expect(
        db
          .prepare(
            "SELECT COUNT(*) AS count FROM attempts WHERE task_id = 'task-other'",
          )
          .get() as { count: number },
      ).toEqual({ count: 0 });
    });

    it("cancels assignment via REST POST endpoint", async () => {
      // First dispatch
      const dispatchRes = await worker.fetch(
        new Request(
          "https://conclave.local/api/v2/workspaces/ws-1/tasks/task-1/dispatch",
          {
            method: "POST",
            headers: {
              Authorization: `Bearer ${adminToken}`,
              "Content-Type": "application/json",
            },
          },
        ),
        env as unknown as Env,
      );
      const { assignment } = (await dispatchRes.json()) as {
        assignment: { assignmentId: string };
      };

      const wrongWorkspaceRes = await worker.fetch(
        new Request(
          `https://conclave.local/api/v2/workspaces/ws-other/assignments/${assignment.assignmentId}/cancel`,
          {
            method: "POST",
            headers: {
              Authorization: `Bearer ${adminToken}`,
              "Content-Type": "application/json",
            },
          },
        ),
        env as unknown as Env,
      );
      expect(wrongWorkspaceRes.status).toBe(404);
      expect(
        (
          db
            .prepare("SELECT status FROM worker_assignments WHERE id = ?")
            .get(assignment.assignmentId) as { status: string }
        ).status,
      ).not.toBe("cancelled");

      // Cancel
      const cancelRes = await worker.fetch(
        new Request(
          `https://conclave.local/api/v2/workspaces/ws-1/assignments/${assignment.assignmentId}/cancel`,
          {
            method: "POST",
            headers: {
              Authorization: `Bearer ${adminToken}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ reason: "Manual abort" }),
          },
        ),
        env as unknown as Env,
      );

      expect(cancelRes.status).toBe(200);
      const cancelBody = (await cancelRes.json()) as { cancelled: boolean };
      expect(cancelBody.cancelled).toBe(true);
    });
  });
});
