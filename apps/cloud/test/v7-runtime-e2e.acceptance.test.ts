import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { createServer, type Server } from "node:http";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createInterface } from "node:readline";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it, vi } from "vitest";
import { dispatchTaskAssignment } from "../src/assignment-dispatcher.js";
import { handleV7WorkerScheduling } from "../src/routes/handlers.js";
import { WorkspaceGateway } from "../src/workspace-gateway.js";
import { hashToken } from "../../../packages/security/src/index.js";

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
  "0029_workspace_sessions.sql",
  "0024_v7_worker_scheduling.sql",
  "0025_v7_assignment_runtime.sql",
  "0033_durable_worker_sessions.sql",
  "0031_worker_readiness_state.sql",
  "0032_worker_inventory_safe_projection.sql",
  "0033_workstream_worker_usage_policy.sql",
  "0034_worker_setup_readiness.sql",
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
  let fallbackServer: Server | undefined;
  afterEach(async () => {
    vi.restoreAllMocks();
    if (child && child.exitCode === null) {
      child.stdin.write('{"bridge":"close"}\n');
      child.stdin.end();
      await Promise.race([
        new Promise<void>((resolve) => child?.once("exit", () => resolve())),
        new Promise<void>((resolve) => setTimeout(resolve, 5000)),
      ]);
      if (child?.exitCode === null) child.kill("SIGKILL");
    }
    if (scratch) rmSync(scratch, { recursive: true, force: true });
    if (fallbackServer?.listening) {
      await new Promise<void>((resolve, reject) =>
        fallbackServer?.close((error) => (error ? reject(error) : resolve())),
      );
    }
    child = undefined;
    scratch = undefined;
    fallbackServer = undefined;
  });

  const scenarios = [
    ...(
      ["websocket", "http_long_poll", "http_long_poll_handover"] as const
    ).map((transportMode) => ({
      label: `${transportMode} fixture adapter`,
      transportMode,
      firstPartyAdapter: null,
      realProvider: false,
    })),
    {
      label: "Codex adapter with a fake CLI",
      transportMode: "websocket" as const,
      firstPartyAdapter: "codex",
      realProvider: false,
    },
    {
      label: "Antigravity adapter with a fake CLI",
      transportMode: "websocket" as const,
      firstPartyAdapter: "antigravity",
      realProvider: false,
    },
    ...(process.env.CONCLAVE_TEST_REAL_CLOUD_CODEX === "1"
      ? [
          {
            label: "Codex Worker Package with the real Codex CLI (opt-in)",
            transportMode: "websocket" as const,
            firstPartyAdapter: "codex" as const,
            realProvider: true,
          },
        ]
      : []),
    ...(process.env.CONCLAVE_TEST_REAL_CLOUD_AGY === "1"
      ? [
          {
            label: "Antigravity Worker Package with the real agy CLI (opt-in)",
            transportMode: "websocket" as const,
            firstPartyAdapter: "antigravity" as const,
            realProvider: true,
          },
        ]
      : []),
  ] as const;

  it.each(scenarios)(
    "executes Cloud assignment through Workspace for $label and persists the result",
    async ({ transportMode, firstPartyAdapter, realProvider = false }) => {
      const workerTypeId =
        firstPartyAdapter === "codex"
          ? "chatgpt"
          : firstPartyAdapter === "antigravity"
            ? "gemini"
            : "fixture-worker";
      const modelId = realProvider ? null : "fixture-model";
      const assignmentTimeoutMs = realProvider ? 180_000 : 30_000;
      const sqlite = new DatabaseSync(":memory:");
      const gatewayLogs: string[] = [];
      vi.spyOn(console, "log").mockImplementation((record) => {
        gatewayLogs.push(String(record));
      });
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
      const runtimeCredential = "v7-e2e-runtime-credential-do-not-log";
      const runtimeCredentialHash = await hashToken(runtimeCredential);
      sqlite.exec(`
      INSERT INTO users (id, email, display_name, status, created_at, updated_at) VALUES ('owner', 'owner@example.test', 'Owner', 'active', '${now}', '${now}');
      INSERT INTO execution_workspaces VALUES ('workspace-v7-e2e', 'owner', 'Test Workspace', 'online', '${now}', '${now}');
      INSERT INTO workspace_runtime_identities (id, workspace_id, credential_key_ref, credential_token_hash, created_at) VALUES ('runtime-v7-e2e', 'workspace-v7-e2e', 'secure-store-ref', '${runtimeCredentialHash}', '${now}');
      INSERT INTO workspace_sessions (id, workspace_id, runtime_identity_id, client_version, protocol_version, connected_at, last_heartbeat_at) VALUES ('session-v7-e2e', 'workspace-v7-e2e', 'runtime-v7-e2e', '1.0.0', '5.1', '${now}', '${now}');
      INSERT INTO workers VALUES ('${workerTypeId}', '${workerTypeId}', 'active', '${now}', '${now}');
      INSERT INTO projects (id, owner_user_id, name, description, created_at, updated_at) VALUES ('project-e2e', 'owner', 'Display Project Name', NULL, '${now}', '${now}');
      INSERT INTO project_memberships VALUES ('membership-e2e', 'project-e2e', 'owner', 'owner', '${now}', '${now}');
      INSERT INTO workspace_project_grants (id, project_id, workspace_id, granted_by_user_id, status, scope, allowed_permissions_json, allowed_worker_capabilities_json, concurrency_json, created_at, updated_at)
        VALUES ('grant-e2e', 'project-e2e', 'workspace-v7-e2e', 'owner', 'active', 'project_repository', '["repository:read","repository:write"]', '["code"]', '{"maxConcurrentAssignments":1}', '${now}', '${now}');
      INSERT INTO workstreams VALUES ('workstream-e2e', 'project-e2e', 'Display Workstream Name', 'active', '{}', 'owner', '${now}', '${now}');
      INSERT INTO workstream_worker_usage_policies (workstream_id, policy_json, updated_by_user_id, updated_at)
        VALUES ('workstream-e2e', '${JSON.stringify({ version: 1, fallbackPolicy: "configured_only", roles: { implementer: { workerId: "worker-local-v7-e2e", ...(modelId ? { model: modelId } : {}) } } })}', 'owner', '${now}');
      INSERT INTO workstream_execution_policies (workstream_id, mode, primary_workspace_id, require_checkout, max_concurrent_work_requests, allowed_configured_worker_ids_json, allowed_worker_type_ids_json, allowed_providers_json, allowed_models_json)
        VALUES ('workstream-e2e', 'stateless', NULL, 0, 1, '[]', '["${workerTypeId}"]', '[]', '${JSON.stringify(modelId ? [modelId] : [])}');
      INSERT INTO runs (id, project_id, workstream_id, status, created_at, updated_at)
        VALUES ('run-e2e', 'project-e2e', 'workstream-e2e', 'created', '${now}', '${now}');
      INSERT INTO workflow_definitions (id, project_id, name, description, current_version_id, created_by_user_id, created_at, updated_at)
        VALUES ('workflow-e2e', 'project-e2e', 'E2E workflow', '', NULL, 'owner', '${now}', '${now}');
      INSERT INTO workflow_versions (id, workflow_definition_id, version, created_by_user_id, created_at)
        VALUES ('workflow-version-e2e', 'workflow-e2e', 1, 'owner', '${now}');
      INSERT INTO work_requests (id, workstream_id, requested_by_user_id, mode, workflow_definition_id, workflow_version_id, workflow_snapshot_json, status, input_json, created_at, updated_at)
        VALUES ('request-e2e', 'workstream-e2e', 'owner', 'stateless', 'workflow-e2e', 'workflow-version-e2e', '{}', 'running', '{}', '${now}', '${now}');
      INSERT INTO workflow_steps (id, workflow_version_id, name, role, required_capabilities_json, execution_class, step_order, independent_from_json, approval, timeout_ms, output_contract_json)
        VALUES ('step-e2e', 'workflow-version-e2e', 'Fixture execution', 'implementer', '["code"]', 'stateless_read', 0, '[]', 'none', ${assignmentTimeoutMs}, '{}');
      INSERT INTO workflow_tasks (id, work_request_id, workflow_version_id, workflow_step_id, execution_class, role, required_capabilities_json, approval, timeout_ms, output_contract_json, status, attempt, created_at, updated_at)
        VALUES ('task-e2e', 'request-e2e', 'workflow-version-e2e', 'step-e2e', 'stateless_read', 'implementer', '["code"]', 'none', ${assignmentTimeoutMs}, '{}', 'queued', 0, '${now}', '${now}');
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
      const gatewayStorage = new Map<string, unknown>();
      const gatewayState = {
        id: { name: "workspace-v7-e2e" },
        storage: {
          get: async (key: string) => gatewayStorage.get(key),
          put: async (key: string, value: unknown) => {
            gatewayStorage.set(key, value);
          },
          delete: async (key: string) => gatewayStorage.delete(key),
        },
      };
      const gateway = new WorkspaceGateway(
        gatewayState as never,
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
      const deliveredAssignmentIds: string[] = [];
      const fallbackRequests: string[] = [];
      const gatewaySocket = {
        send(data: string) {
          gatewayOutbound.push(data);
          const message = JSON.parse(data) as Record<string, unknown>;
          if (message.type === "assignment.start")
            deliveredAssignmentIds.push(String(message.assignmentId));
          hostBridge.current?.send(data);
        },
        close() {},
      };
      const privateGateway = gateway as unknown as {
        socket: WebSocket | null;
        executionWorkspaceId: string | null;
        workspaceRuntimeId: string | null;
        sessionId: string | null;
        correlationId: string | null;
        handleMessage(data: unknown, sessionId: string): Promise<void>;
      };
      if (transportMode === "websocket") {
        Object.assign(privateGateway, {
          socket: gatewaySocket as never,
          executionWorkspaceId: "workspace-v7-e2e",
          workspaceRuntimeId: "runtime-v7-e2e",
          sessionId: gatewaySession,
          correlationId: "v7-e2e-request-ray",
        });
      } else {
        fallbackServer = createServer(async (request, response) => {
          fallbackRequests.push(`${request.method} ${request.url}`);
          const chunks: Buffer[] = [];
          for await (const chunk of request) chunks.push(Buffer.from(chunk));
          const body = Buffer.concat(chunks);
          try {
            const publicPath = request.url ?? "/";
            const internalPath = publicPath.replace(
              /^\/api\/workspace-runtime\//,
              "/runtime/",
            );
            const headers = new Headers(request.headers as HeadersInit);
            headers.set("x-request-id", "v7-e2e-request-ray");
            const gatewayResponse = await gateway.fetch(
              new Request(`https://gateway.internal${internalPath}`, {
                method: request.method,
                headers,
                ...(request.method === "GET" || request.method === "HEAD"
                  ? {}
                  : { body }),
              }),
            );
            const responseText = await gatewayResponse.text();
            if (!gatewayResponse.ok) {
              rejectHarness(
                new Error(
                  `Fallback Gateway returned HTTP ${gatewayResponse.status}: ${responseText}`,
                ),
              );
            }
            if (internalPath.endsWith("/runtime/poll")) {
              const polled = JSON.parse(responseText) as {
                events?: Array<{ message?: Record<string, unknown> }>;
              };
              for (const event of polled.events ?? []) {
                if (event.message?.type === "assignment.start") {
                  deliveredAssignmentIds.push(
                    String(event.message.assignmentId),
                  );
                }
              }
            }
            if (internalPath.endsWith("/runtime/events")) {
              const posted = JSON.parse(body.toString("utf8")) as {
                events?: Array<{ message?: Record<string, unknown> }>;
              };
              for (const event of posted.events ?? []) {
                const message = event.message;
                if (!message) continue;
                hostMessages.push(message);
                if (message.type === "worker.inventory") resolveInventory();
                if (message.type === "assignment.result")
                  resolveResult(message);
              }
            }
            response.writeHead(gatewayResponse.status, {
              "content-type": "application/json",
            });
            response.end(responseText);
          } catch (error) {
            rejectHarness(
              error instanceof Error ? error : new Error(String(error)),
            );
            response.writeHead(500);
            response.end(JSON.stringify({ error: String(error) }));
          }
        });
        await new Promise<void>((resolve) =>
          fallbackServer?.listen(0, "127.0.0.1", resolve),
        );
      }

      scratch = mkdtempSync(join(tmpdir(), "conclave-v7-e2e-"));
      let workspaceEnvironment = process.env;
      if (firstPartyAdapter && !realProvider) {
        const providerBin = join(scratch, "provider-bin");
        mkdirSync(providerBin, { recursive: true });
        const cliName = firstPartyAdapter === "codex" ? "codex" : "agy";
        const fakeCli = join(providerBin, cliName);
        writeFileSync(
          fakeCli,
          firstPartyAdapter === "codex"
            ? `#!/bin/sh
if [ "$1" = "--version" ]; then echo 'codex 1.2.3'; exit 0; fi
if [ "$1" = "login" ] && [ "$2" = "status" ]; then echo 'Logged in'; exit 0; fi
cat >/dev/null
printf '%s\\n' 'fake Codex execution' > "$PWD/first-party-cli.txt"
printf '%s\\n' '{"type":"turn.started"}'
printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"fake Codex execution completed"}}'
printf '%s\\n' '{"type":"turn.completed"}'
`
            : `#!/bin/sh
if [ "$1" = "--version" ]; then echo 'agy 4.5.6'; exit 0; fi
cat >/dev/null
printf '%s\\n' 'fake Antigravity execution' > "$PWD/first-party-cli.txt"
printf '%s\\n' '{"event":"init","conversation_id":"fixture","init":{"cwd":"."}}'
printf '%s\\n' '{"event":"step_update","step_update":{"state":"RUNNING"}}'
printf '%s\\n' '{"event":"result","result":{"status":"SUCCESS","response":"fake Antigravity execution completed"}}'
`,
          { mode: 0o700 },
        );
        chmodSync(fakeCli, 0o700);
        workspaceEnvironment = {
          ...process.env,
          PATH: `${providerBin}${delimiter}${process.env.PATH ?? ""}`,
        };
      }
      child = spawn(
        process.env.DART_EXECUTABLE ?? "dart",
        [
          "run",
          "bin/v7_runtime_e2e_bridge.dart",
          scratch,
          transportMode,
          transportMode !== "websocket"
            ? `http://127.0.0.1:${
                (fallbackServer?.address() as { port: number }).port
              }`
            : "",
          transportMode !== "websocket" ? runtimeCredential : "",
          firstPartyAdapter ?? "",
          realProvider ? "real" : "fake",
        ],
        {
          cwd: fileURLToPath(new URL("../../host/", import.meta.url)),
          stdio: ["pipe", "pipe", "pipe"],
          env: workspaceEnvironment,
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
      const transportStatuses: string[] = [];
      lineReader.on("line", (line) => {
        if (line.startsWith("@transport=")) {
          transportStatuses.push(line.slice("@transport=".length));
          return;
        }
        hostMessageChain = hostMessageChain
          .then(async () => {
            const message = JSON.parse(line) as Record<string, unknown>;
            if (
              transportMode === "http_long_poll_handover" &&
              message.type === "workspace.hello" &&
              privateGateway.socket === null
            ) {
              Object.assign(privateGateway, {
                socket: gatewaySocket as never,
                executionWorkspaceId: "workspace-v7-e2e",
                workspaceRuntimeId: "runtime-v7-e2e",
                sessionId: gatewaySession,
                correlationId: "v7-e2e-request-ray",
              });
            }
            hostMessages.push(message);
            await privateGateway.handleMessage(message, gatewaySession);
            if (message.type === "worker.inventory") resolveInventory();
            if (message.type === "assignment.result") resolveResult(message);
            if (message.type === "assignment.error") {
              const payload = message.payload as
                { error?: { code?: unknown; message?: unknown } } | undefined;
              const error = payload?.error as
                { code?: unknown; message?: unknown } | undefined;
              rejectHarness(
                new Error(
                  `Workspace reported assignment.error: ${String(error?.code ?? "unknown")}: ${String(error?.message ?? "no message")}`,
                ),
              );
            }
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
            reject(
              new Error(`Workspace bridge exited ${code}: ${childStderr}`),
            );
        }),
      );
      const wait = <T>(promise: Promise<T>) =>
        Promise.race([
          promise,
          messageError,
          childFailure,
          harnessFailed,
          new Promise<never>((_, reject) =>
            setTimeout(
              () =>
                reject(
                  new Error(
                    `Acceptance stalled; host messages: ${hostMessages.map((message) => message.type).join(",")}; fallback requests: ${fallbackRequests.join(",")}`,
                  ),
                ),
              realProvider ? 240000 : 45000,
            ),
          ),
        ]);
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
        .prepare(
          "SELECT * FROM workspace_worker_inventory WHERE worker_id = ?1",
        )
        .bind("worker-local-v7-e2e")
        .first<Record<string, unknown>>();
      expect(inventory).toMatchObject({
        workspace_id: "workspace-v7-e2e",
        worker_type_id: workerTypeId,
        status: "ready",
        credential_status: "not_required",
      });
      const liveStatus = await gateway.fetch(
        new Request("https://gateway.internal/status"),
      );
      expect(await liveStatus.json()).toMatchObject({
        online: true,
        activeTransport:
          transportMode === "websocket" ? "websocket" : "http_long_poll",
        workspaceRuntimeId: "runtime-v7-e2e",
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
      expect(await schedulingResponse.json()).toMatchObject({
        state: "enabled",
      });

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
            objective: realProvider
              ? "Reply with exactly OK. Do not use tools."
              : "execute fixture",
            capabilities: ["code"],
            projectId: "project-e2e",
            requestedByUserId: "owner",
            ...(modelId ? { model: modelId } : {}),
            workstreamId: "workstream-e2e",
            executionClass: "stateless_read",
            input: realProvider ? {} : { objective: "acceptance" },
            timeoutMs: assignmentTimeoutMs,
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
      if (transportMode !== "websocket") {
        expect(gatewayOutbound).toHaveLength(0);
        const status = await gateway.fetch(
          new Request("https://gateway.internal/status"),
        );
        expect(await status.json()).toMatchObject({
          online: true,
          activeTransport: "http_long_poll",
        });
      }
      await waitForMessage("assignment.ack");
      const hostResult = await wait(resultSeen);
      await hostMessageChain;
      expect(
        hostMessages.some((message) => message.type === "assignment.progress"),
      ).toBe(true);
      expect(hostResult.assignmentId).toBe(dispatched.assignmentId);
      expect(
        deliveredAssignmentIds.filter((id) => id === dispatched.assignmentId),
      ).toHaveLength(1);
      if (transportMode === "http_long_poll_handover") {
        await wait(
          new Promise<void>((resolve) => {
            const check = setInterval(() => {
              if (transportStatuses.includes("websocket")) {
                clearInterval(check);
                resolve();
              }
            }, 10);
          }),
        );
        await hostMessageChain;
        const upgradedStatus = await gateway.fetch(
          new Request("https://gateway.internal/status"),
        );
        expect(await upgradedStatus.json()).toMatchObject({
          online: true,
          activeTransport: "websocket",
        });
        expect(
          hostMessages.filter(
            (message) => message.type === "workspace.sync.request",
          ),
        ).toHaveLength(2);
        expect(
          deliveredAssignmentIds.filter((id) => id === dispatched.assignmentId),
        ).toHaveLength(1);
      }
      const protocolLogs = gatewayLogs
        .map(
          (record) =>
            JSON.parse(record) as {
              message: string;
              correlation?: { requestId?: string };
            },
        )
        .filter((record) => record.message.startsWith("GW-1"));
      expect(protocolLogs.map((record) => record.message)).toEqual(
        expect.arrayContaining([
          "GW-10 workspace_hello_received",
          "GW-11 workspace_hello_ack_sent",
          "GW-12 workspace_sync_completed",
        ]),
      );
      expect(
        protocolLogs.every(
          (record) => record.correlation?.requestId === "v7-e2e-request-ray",
        ),
      ).toBe(true);

      const assignment = await db
        .prepare(
          "SELECT status, output_json, worker_id, workspace_worker_id, configured_worker_id, execution_workspace_id FROM worker_assignments WHERE id = ?1",
        )
        .bind(dispatched.assignmentId)
        .first<Record<string, unknown>>();
      expect(assignment).toMatchObject({
        status: "completed",
        worker_id: workerTypeId,
        workspace_worker_id: "worker-local-v7-e2e",
        configured_worker_id: null,
        execution_workspace_id: "workspace-v7-e2e",
      });
      const persisted = JSON.parse(String(assignment?.output_json)) as {
        output?: { text?: string };
      };
      const expectedCwd = join(
        realpathSync(scratch),
        "work-root",
        "project-e2e",
        "workstream-e2e",
      );
      if (firstPartyAdapter === null) {
        const output = JSON.parse(String(persisted.output?.text)) as {
          cwd: string;
          file: string;
        };
        expect(output.cwd).toBe(expectedCwd);
        expect(output.file).toBe("written-by-real-adapter-process");
        expect(
          readFileSync(join(output.cwd, "v7-e2e-output.txt"), "utf8"),
        ).toBe(output.file);
      } else if (realProvider) {
        expect(persisted.output?.text).toMatch(/\bOK\b/i);
        expect(persisted.output?.text?.trim().length).toBeGreaterThan(0);
      } else {
        const expectedOutput =
          firstPartyAdapter === "codex"
            ? "fake Codex execution completed"
            : "fake Antigravity execution completed";
        expect(persisted.output?.text).toBe(expectedOutput);
        expect(
          readFileSync(join(expectedCwd, "first-party-cli.txt"), "utf8").trim(),
        ).toBe(
          firstPartyAdapter === "codex"
            ? "fake Codex execution"
            : "fake Antigravity execution",
        );
      }
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
        workerTypeId,
        workspaceId: "workspace-v7-e2e",
      });
      const task = await db
        .prepare("SELECT status, output_json FROM workflow_tasks WHERE id = ?1")
        .bind("task-e2e")
        .first<Record<string, unknown>>();
      expect(task?.status).toBe("completed");
      expect(String(task?.output_json)).toContain(
        firstPartyAdapter === null
          ? "written-by-real-adapter-process"
          : realProvider
            ? "OK"
            : `fake ${firstPartyAdapter === "codex" ? "Codex" : "Antigravity"} execution completed`,
      );
      if (realProvider) {
        for (const name of [
          "OPENAI_API_KEY",
          "CODEX_API_KEY",
          "GEMINI_API_KEY",
          "GOOGLE_API_KEY",
          "GOOGLE_APPLICATION_CREDENTIALS",
        ]) {
          const value = process.env[name];
          if (value) {
            expect(String(assignment?.output_json)).not.toContain(value);
            expect(JSON.stringify(gatewayOutbound)).not.toContain(value);
          }
        }
      }
    },
    300000,
  );
});
