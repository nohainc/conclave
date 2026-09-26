import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createInterface } from "node:readline";
import { mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { dispatchTaskAssignment } from "../src/assignment-dispatcher.js";
import { handleV7WorkerScheduling } from "../src/routes/handlers.js";
import { WorkspaceGateway } from "../src/workspace-gateway.js";

const migrationFiles = [
  "0001_conclave_v6.sql",
  "0002_workstream_integrations.sql",
  "0003_usage_audit_observability.sql",
  "0004_chat_workstream_mapping.sql",
  "0005_execution_foundation.sql",
  "0006_auth_foundation.sql",
  "0007_project_settings.sql",
  "0008_workspace_enrollments.sql",
  "0009_workspace_audit_log.sql",
  "0010_workspace_project_grant_policy.sql",
  "0011_project_invitations.sql",
  "0012_remove_project_repository.sql",
  "0013_configured_workers.sql",
  "0014_configured_worker_runtime_state.sql",
  "0015_configured_worker_assignments.sql",
  "0016_worker_first_execution_policy.sql",
  "0017_configured_worker_observability.sql",
  "0018_migrate_legacy_ai_accounts.sql",
  "0019_worker_assignment_requester.sql",
  "0020_workspace_runtime_facts.sql",
  "0021_workspace_worker_inventory.sql",
  "0022_v7_adapter_releases.sql",
  "0023_workspace_runtime_credentials.sql",
  "0024_v7_worker_scheduling.sql",
  "0025_v7_assignment_runtime.sql",
];

class LocalD1Statement {
  constructor(
    private readonly db: DatabaseSync,
    private readonly sql: string,
    private readonly values: unknown[] = [],
  ) {}
  bind(...values: unknown[]): LocalD1Statement {
    return new LocalD1Statement(this.db, this.sql, values);
  }
  async first<T>(): Promise<T | null> {
    return (
      (this.db.prepare(this.sql).get(...(this.values as SQLInputValue[])) as
        T | undefined) ?? null
    );
  }
  async all<T>(): Promise<{ results: T[] }> {
    return {
      results: this.db
        .prepare(this.sql)
        .all(...(this.values as SQLInputValue[])) as T[],
    };
  }
  async run(): Promise<{ success: true }> {
    this.db.prepare(this.sql).run(...(this.values as SQLInputValue[]));
    return { success: true };
  }
}

class LocalD1 {
  readonly queries: string[] = [];
  constructor(readonly sqlite: DatabaseSync) {}
  prepare(sql: string): LocalD1Statement {
    this.queries.push(sql);
    return new LocalD1Statement(this.sqlite, sql);
  }
  async batch(statements: readonly LocalD1Statement[]): Promise<unknown[]> {
    this.sqlite.exec("BEGIN");
    try {
      const result = [];
      for (const statement of statements) result.push(await statement.run());
      this.sqlite.exec("COMMIT");
      return result;
    } catch (error) {
      this.sqlite.exec("ROLLBACK");
      throw error;
    }
  }
}

class BridgeSocket {
  constructor(private readonly child: ChildProcessWithoutNullStreams) {}
  send(message: string): void {
    this.child.stdin.write(`${message}\n`);
  }
  close(): void {
    this.child.stdin.end();
  }
}

describe("V7 runtime assignment acceptance", () => {
  let child: ChildProcessWithoutNullStreams | undefined;
  let scratch: string | undefined;
  afterEach(async () => {
    if (child && child.exitCode === null) {
      child.stdin.write('{"bridge":"close"}\n');
      child.stdin.end();
      await new Promise<void>((resolve) =>
        child?.once("exit", () => resolve()),
      );
    }
    if (scratch) rmSync(scratch, { recursive: true, force: true });
    child = undefined;
    scratch = undefined;
  });

  it("dispatches V7-only work through Cloud Gateway and the real Workspace child adapter, then persists the result", async () => {
    const sqlite = new DatabaseSync(":memory:");
    sqlite.exec("PRAGMA foreign_keys = ON");
    for (const file of migrationFiles) {
      sqlite.exec(
        readFileSync(
          fileURLToPath(new URL(`../migrations-v6/${file}`, import.meta.url)),
          "utf8",
        ),
      );
    }
    const db = new LocalD1(sqlite);
    const now = new Date().toISOString();
    sqlite.exec(`
      INSERT INTO users (id, email, display_name, status, created_at, updated_at) VALUES ('owner', 'owner@example.test', 'Owner', 'active', '${now}', '${now}');
      INSERT INTO execution_workspaces VALUES ('workspace-v7-e2e', 'owner', 'Test Workspace', 'online', '${now}', '${now}');
      INSERT INTO workspace_runtime_identities (id, workspace_id, credential_key_ref, created_at) VALUES ('runtime-v7-e2e', 'workspace-v7-e2e', 'secure-store-ref', '${now}');
      INSERT INTO workers VALUES ('fixture-worker', 'Fixture Worker Type', 'active', '${now}', '${now}');
      INSERT INTO projects (id, owner_user_id, name, description, created_at, updated_at) VALUES ('project-e2e', 'owner', 'Display Project Name', NULL, '${now}', '${now}');
      INSERT INTO project_memberships VALUES ('membership-e2e', 'project-e2e', 'owner', 'owner', '${now}', '${now}');
      INSERT INTO workspace_project_grants (id, project_id, workspace_id, granted_by_user_id, status, scope, allowed_permissions_json, allowed_worker_capabilities_json, concurrency_json, created_at, updated_at)
        VALUES ('grant-e2e', 'project-e2e', 'workspace-v7-e2e', 'owner', 'active', 'project_repository', '["repository:read","repository:write"]', '["code"]', '{"maxConcurrentAssignments":1}', '${now}', '${now}');
      INSERT INTO workstreams VALUES ('workstream-e2e', 'project-e2e', 'Display Workstream Name', 'active', '{}', 'owner', '${now}', '${now}');
      INSERT INTO workstream_execution_policies (workstream_id, mode, primary_workspace_id, require_checkout, max_concurrent_work_requests, allowed_configured_worker_ids_json, allowed_worker_type_ids_json, allowed_providers_json, allowed_models_json)
        VALUES ('workstream-e2e', 'stateless', NULL, 0, 1, '[]', '["fixture-worker"]', '[]', '["fixture-model"]');
      INSERT INTO runs (id, project_id, workstream_id, status, created_at, updated_at)
        VALUES ('run-e2e', 'project-e2e', 'workstream-e2e', 'created', '${now}', '${now}');
      INSERT INTO workflow_definitions (id, project_id, name, description, current_version_id, created_by_user_id, created_at, updated_at)
        VALUES ('workflow-e2e', 'project-e2e', 'E2E workflow', '', NULL, 'owner', '${now}', '${now}');
      INSERT INTO workflow_versions (id, workflow_definition_id, version, created_by_user_id, created_at)
        VALUES ('workflow-version-e2e', 'workflow-e2e', 1, 'owner', '${now}');
      INSERT INTO work_requests (id, workstream_id, requested_by_user_id, mode, workflow_definition_id, workflow_version_id, workflow_snapshot_json, status, input_json, created_at, updated_at)
        VALUES ('request-e2e', 'workstream-e2e', 'owner', 'stateless', 'workflow-e2e', 'workflow-version-e2e', '{}', 'running', '{}', '${now}', '${now}');
      INSERT INTO workflow_steps (id, workflow_version_id, name, role, required_capabilities_json, execution_class, step_order, independent_from_json, approval, timeout_ms, output_contract_json)
        VALUES ('step-e2e', 'workflow-version-e2e', 'Fixture execution', 'implementer', '["code"]', 'stateless_read', 0, '[]', 'none', 30000, '{}');
      INSERT INTO workflow_tasks (id, work_request_id, workflow_version_id, workflow_step_id, execution_class, role, required_capabilities_json, approval, timeout_ms, output_contract_json, status, attempt, created_at, updated_at)
        VALUES ('task-e2e', 'request-e2e', 'workflow-version-e2e', 'step-e2e', 'stateless_read', 'implementer', '["code"]', 'none', 30000, '{}', 'queued', 0, '${now}', '${now}');
    `);

    const env = {
      CONCLAVE_ENVIRONMENT: "development",
      CONCLAVE_DB: db,
      TEST_AUTHENTICATION: async () => ({
        userId: "owner",
        user: {
          id: "owner",
          email: "owner@example.test",
          displayName: "owner",
          status: "active",
        },
        workspaceId: "",
        workspaceRole: "viewer",
        roles: ["viewer"],
        authorizedProjectIds: [],
        projectRoles: {},
        sessionId: "session-owner",
        clientType: "web",
        organizationId: "",
        organizationRoles: ["viewer"],
        authorizationModel: "v5",
        ownedWorkspaceIds: ["workspace-v7-e2e"],
        ownedAccountIds: [],
      }),
    } as never;
    const gateway = new WorkspaceGateway(
      {} as never,
      { CONCLAVE_DB: db } as never,
    );
    const hostMessages: Record<string, unknown>[] = [];
    let resolveInventory!: () => void;
    let resolveResult!: (message: Record<string, unknown>) => void;
    let rejectHarness!: (error: Error) => void;
    const inventorySeen = new Promise<void>((resolve) => {
      resolveInventory = resolve;
    });
    const resultSeen = new Promise<Record<string, unknown>>((resolve) => {
      resolveResult = resolve;
    });
    const harnessFailed = new Promise<never>((_, reject) => {
      rejectHarness = reject;
    });
    const gatewaySession = "session-v7-e2e";
    const hostBridge: { current: BridgeSocket | null } = { current: null };
    const gatewayOutbound: string[] = [];
    const gatewaySocket = {
      send(data: string) {
        gatewayOutbound.push(data);
        hostBridge.current?.send(data);
      },
      close() {},
    };
    const privateGateway = gateway as unknown as {
      socket: WebSocket | null;
      executionWorkspaceId: string | null;
      workspaceRuntimeId: string | null;
      sessionId: string | null;
      handleMessage(data: unknown, sessionId: string): Promise<void>;
    };
    Object.assign(privateGateway, {
      socket: gatewaySocket as never,
      executionWorkspaceId: "workspace-v7-e2e",
      workspaceRuntimeId: "runtime-v7-e2e",
      sessionId: gatewaySession,
    });

    scratch = mkdtempSync(join(tmpdir(), "conclave-v7-e2e-"));
    child = spawn(
      process.env.DART_EXECUTABLE ?? "dart",
      ["run", "bin/v7_runtime_e2e_bridge.dart", scratch],
      {
        cwd: fileURLToPath(new URL("../../host/", import.meta.url)),
        stdio: ["pipe", "pipe", "pipe"],
        env: process.env,
      },
    );
    hostBridge.current = new BridgeSocket(child);
    let childStderr = "";
    child.stderr.setEncoding("utf8").on("data", (chunk: string) => {
      childStderr += chunk;
    });
    const lineReader = createInterface({ input: child.stdout });
    const messageError = new Promise<never>((_, reject) =>
      child?.once("error", reject),
    );
    let hostMessageChain = Promise.resolve();
    lineReader.on("line", (line) => {
      hostMessageChain = hostMessageChain
        .then(async () => {
          const message = JSON.parse(line) as Record<string, unknown>;
          hostMessages.push(message);
          await privateGateway.handleMessage(message, gatewaySession);
          if (message.type === "worker.inventory") resolveInventory();
          if (message.type === "assignment.result") resolveResult(message);
        })
        .catch((error: unknown) => {
          rejectHarness(
            error instanceof Error ? error : new Error(String(error)),
          );
        });
    });
    const childFailure = new Promise<never>((_, reject) =>
      child?.once("exit", (code) => {
        if (code !== 0)
          reject(new Error(`Workspace bridge exited ${code}: ${childStderr}`));
      }),
    );
    const wait = <T>(promise: Promise<T>) =>
      Promise.race([promise, messageError, childFailure, harnessFailed]);
    const waitForMessage = async (type: string) =>
      wait(
        new Promise<void>((resolve, reject) => {
          const check = setInterval(() => {
            if (hostMessages.some((message) => message.type === type)) {
              clearInterval(check);
              resolve();
            } else if (child?.exitCode !== null) {
              clearInterval(check);
              reject(new Error(`Workspace bridge exited: ${childStderr}`));
            }
          }, 10);
        }),
      );

    await waitForMessage("workspace.hello");
    await wait(inventorySeen);
    await hostMessageChain;
    const inventory = await db
      .prepare("SELECT * FROM workspace_worker_inventory WHERE worker_id = ?1")
      .bind("worker-local-v7-e2e")
      .first<Record<string, unknown>>();
    expect(inventory).toMatchObject({
      workspace_id: "workspace-v7-e2e",
      worker_type_id: "fixture-worker",
      status: "ready",
      credential_status: "not_required",
    });
    expect(JSON.stringify(inventory)).not.toMatch(
      /credentialRef|secure-store-ref|apiKey|cookie|work-root|\/Users\//i,
    );
    expect(
      await db
        .prepare("SELECT COUNT(*) AS count FROM configured_workers")
        .first<{ count: number }>(),
    ).toMatchObject({ count: 0 });
    expect(
      await db
        .prepare(
          "SELECT COUNT(*) AS count FROM worker_workspace_bindings WHERE workspace_id = ?1",
        )
        .bind("workspace-v7-e2e")
        .first<{ count: number }>(),
    ).toMatchObject({ count: 0 });

    const schedulingResponse = await handleV7WorkerScheduling(
      new Request("https://conclave.test/", { method: "POST" }),
      env,
      "worker-local-v7-e2e",
      "enable",
    );
    expect(schedulingResponse.status).toBe(200);
    expect(await schedulingResponse.json()).toMatchObject({ state: "enabled" });

    const namespace = {
      idFromName: (id: string) => id,
      get: () => ({
        fetch: async (input: RequestInfo | URL, init?: RequestInit) => {
          const response = await gateway.fetch(
            input instanceof Request ? input : new Request(input, init),
          );
          return response;
        },
      }),
    };
    const schedulerQueryStart = db.queries.length;
    const dispatched = await dispatchTaskAssignment(
      {
        CONCLAVE_DB: db as unknown as D1Database,
        CONCLAVE_WORKSPACE_GATEWAY: namespace as never,
      },
      {
        workspaceId: "workspace-v7-e2e",
        runId: "run-e2e",
        taskId: "task-e2e",
        task: {
          id: "task-e2e",
          role: "implementer",
          objective: "execute fixture",
          capabilities: ["code"],
          projectId: "project-e2e",
          requestedByUserId: "owner",
          model: "fixture-model",
          workstreamId: "workstream-e2e",
          executionClass: "stateless_read",
          input: { objective: "acceptance" },
          timeoutMs: 30000,
        },
      },
    );
    expect(
      db.queries
        .slice(schedulerQueryStart)
        .some((sql) => sql.includes("worker_workspace_bindings")),
    ).toBe(false);
    expect(dispatched).toMatchObject({
      workerId: "worker-local-v7-e2e",
      status: "dispatched",
      accepted: true,
    });
    await waitForMessage("assignment.ack");
    const hostResult = await wait(resultSeen);
    await hostMessageChain;
    expect(
      hostMessages.some((message) => message.type === "assignment.progress"),
    ).toBe(true);
    expect(hostResult.assignmentId).toBe(dispatched.assignmentId);

    const assignment = await db
      .prepare(
        "SELECT status, output_json, worker_id, workspace_worker_id, configured_worker_id, execution_workspace_id FROM worker_assignments WHERE id = ?1",
      )
      .bind(dispatched.assignmentId)
      .first<Record<string, unknown>>();
    expect(assignment).toMatchObject({
      status: "completed",
      worker_id: "fixture-worker",
      workspace_worker_id: "worker-local-v7-e2e",
      configured_worker_id: null,
      execution_workspace_id: "workspace-v7-e2e",
    });
    const persisted = JSON.parse(String(assignment?.output_json)) as {
      output?: { text?: string };
    };
    const output = JSON.parse(String(persisted.output?.text)) as {
      cwd: string;
      file: string;
    };
    expect(output.cwd).toBe(
      join(realpathSync(scratch), "work-root", "project-e2e", "workstream-e2e"),
    );
    expect(output.file).toBe("written-by-real-adapter-process");
    expect(readFileSync(join(output.cwd, "v7-e2e-output.txt"), "utf8")).toBe(
      output.file,
    );
    expect(String(assignment?.output_json)).not.toMatch(
      /test-only-adapter-signing-secret|secure-store-ref|apiKey|cookie/i,
    );
    expect(JSON.stringify(gatewayOutbound)).not.toMatch(
      /test-only-adapter-signing-secret|secure-store-ref|credentialRef|apiKey|cookie/i,
    );
    const permissionSnapshot = JSON.parse(
      String(
        await db
          .prepare(
            "SELECT permission_snapshot_json FROM worker_assignments WHERE id = ?1",
          )
          .bind(dispatched.assignmentId)
          .first<{ permission_snapshot_json: string }>()
          .then((row) => row?.permission_snapshot_json),
      ),
    ) as Record<string, unknown>;
    expect(permissionSnapshot).toMatchObject({
      configuredWorkerId: "worker-local-v7-e2e",
      workerTypeId: "fixture-worker",
      workspaceId: "workspace-v7-e2e",
    });
    const task = await db
      .prepare("SELECT status, output_json FROM workflow_tasks WHERE id = ?1")
      .bind("task-e2e")
      .first<Record<string, unknown>>();
    expect(task?.status).toBe("completed");
    expect(String(task?.output_json)).toContain(
      "written-by-real-adapter-process",
    );
  }, 60000);
});
