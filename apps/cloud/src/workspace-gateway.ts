import {
  parseWorkspaceRuntimeMessage,
  serializeWorkspaceRuntimeMessage,
  WORKSPACE_RUNTIME_PROTOCOL_NAME,
  WORKSPACE_RUNTIME_PROTOCOL_VERSION,
  type WorkspaceRuntimeMessage,
} from "@conclave/host-protocol";
import { createEventPublisher } from "./event-publisher.js";
import {
  recordAssignmentCancelled,
  recordAssignmentError,
  recordAssignmentResult,
} from "./assignment-dispatcher.js";
import {
  extractBearerToken,
  hashToken,
} from "../../../packages/security/src/index.js";

const jsonArray = (value: unknown): string[] => {
  if (typeof value !== "string") return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed)
      ? parsed.filter((item): item is string => typeof item === "string")
      : [];
  } catch {
    return [];
  }
};

export function normalizeWorkspaceWorkerInstallationStatus(
  status: string,
):
  | "absent"
  | "requested"
  | "installing"
  | "ready"
  | "updating"
  | "degraded"
  | "failed"
  | "removing" {
  switch (status) {
    case "installed":
    case "active":
    case "ready":
      return "ready";
    case "requested":
      return "requested";
    case "downloading":
    case "verifying":
    case "installing":
      return "installing";
    case "updating":
      return "updating";
    case "removing":
      return "removing";
    case "absent":
      return "absent";
    case "degraded":
      return "degraded";
    case "failed":
      return "failed";
    default:
      return "failed";
  }
}

export interface WorkspaceGatewayEnv {
  CONCLAVE_DB: D1Database;
  CONCLAVE_REALTIME_GATEWAY?: DurableObjectNamespace;
}

export interface WorkspaceAssignmentCorrelation {
  executionWorkspaceId: string;
  workspaceRuntimeId: string;
  workerId: string;
  runId: string;
  taskId: string;
  attemptId: string;
  assignmentId: string;
  idempotencyKey: string;
}

export function workspaceAssignmentContextMatches(
  message: WorkspaceAssignmentCorrelation,
  row: Record<string, unknown>,
): boolean {
  return (
    message.executionWorkspaceId === String(row.execution_workspace_id) &&
    message.workspaceRuntimeId === String(row.runtime_identity_id) &&
    message.workerId === String(row.configured_worker_id ?? row.worker_id) &&
    message.runId === String(row.run_id) &&
    message.taskId === String(row.task_id) &&
    message.attemptId === String(row.attempt_id) &&
    message.assignmentId === String(row.id) &&
    message.idempotencyKey === String(row.idempotency_key)
  );
}

export function isCurrentWorkspaceSocket(
  currentSocket: WebSocket | null,
  currentSessionId: string | null,
  socket?: WebSocket,
  sessionId?: string | null,
): boolean {
  return (
    (!socket || currentSocket === socket) &&
    (!sessionId || currentSessionId === sessionId)
  );
}

export function workspaceAssignmentIsActive(
  row: Record<string, unknown>,
): boolean {
  return !["completed", "failed", "cancelled", "timed_out"].includes(
    String(row.status),
  );
}

export async function isWorkspaceRuntimeAuthorized(
  db: Pick<D1Database, "prepare">,
  workspaceRuntimeId: string,
  tokenHash: string,
): Promise<{ executionWorkspaceId: string } | null> {
  const row = await db
    .prepare(
      `SELECT wri.workspace_id AS executionWorkspaceId
       FROM workspace_runtime_identities wri
       JOIN execution_workspaces ew ON ew.id = wri.workspace_id
       WHERE wri.id = ?1
         AND wri.credential_token_hash = ?2
         AND wri.revoked_at IS NULL
         AND ew.status <> 'revoked'`,
    )
    .bind(workspaceRuntimeId, tokenHash)
    .first<{ executionWorkspaceId: string }>();
  return row ?? null;
}

export class WorkspaceGateway implements DurableObject {
  private socket: WebSocket | null = null;
  private executionWorkspaceId: string | null = null;
  private workspaceRuntimeId: string | null = null;
  private sessionId: string | null = null;

  constructor(
    private readonly state: DurableObjectState,
    private readonly env: WorkspaceGatewayEnv,
  ) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.headers.get("Upgrade")?.toLowerCase() === "websocket") {
      return this.connectSocket(request, url);
    }
    if (request.method === "GET" && url.pathname === "/status") {
      return Response.json({
        online: this.socket !== null,
        executionWorkspaceId: this.executionWorkspaceId,
        workspaceRuntimeId: this.workspaceRuntimeId,
        sessionId: this.sessionId,
      });
    }
    if (request.method === "POST" && url.pathname === "/dispatch-assignment") {
      return this.dispatchAssignment(request);
    }
    if (request.method === "POST" && url.pathname === "/cancel-assignment") {
      return this.cancelAssignment(request);
    }
    if (request.method === "POST" && url.pathname === "/provision-checkout") {
      return this.provisionCheckout(request);
    }
    if (request.method === "POST" && url.pathname === "/recover-checkout") {
      return this.sendCheckoutCommand(request, "checkout.recover");
    }
    if (request.method === "POST" && url.pathname === "/archive-checkout") {
      return this.sendCheckoutCommand(request, "checkout.archive");
    }
    if (request.method === "POST" && url.pathname === "/finalize-checkout") {
      return this.sendCheckoutCommand(request, "checkout.finalize");
    }
    return Response.json({ error: "Not found" }, { status: 404 });
  }

  private async connectSocket(request: Request, url: URL): Promise<Response> {
    const workspaceRuntimeId = url.searchParams.get("workspaceRuntimeId");
    const token = extractBearerToken(request.headers);
    if (!workspaceRuntimeId || !token) {
      return Response.json(
        { error: "workspaceRuntimeId and runtime credential are required" },
        { status: 401 },
      );
    }
    const authorized = await isWorkspaceRuntimeAuthorized(
      this.env.CONCLAVE_DB,
      workspaceRuntimeId,
      await hashToken(token),
    );
    if (!authorized) {
      return Response.json(
        { error: "Invalid or revoked Workspace runtime credential" },
        { status: 401 },
      );
    }

    if (this.socket) {
      try {
        this.socket.close(1000, "Superseded by new connection");
      } catch {
        // The stale socket is fenced by session id below.
      }
    }
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    const sessionId = `session-${crypto.randomUUID()}`;
    server.serializeAttachment({
      sessionId,
      executionWorkspaceId: authorized.executionWorkspaceId,
      workspaceRuntimeId,
    });
    this.state.acceptWebSocket(server);
    this.socket = server;
    this.executionWorkspaceId = authorized.executionWorkspaceId;
    this.workspaceRuntimeId = workspaceRuntimeId;
    this.sessionId = sessionId;

    const now = new Date().toISOString();
    await this.env.CONCLAVE_DB.prepare(
      `INSERT INTO workspace_sessions
       (id, workspace_id, runtime_identity_id, client_version, protocol_version,
        ip_address, connected_at, last_heartbeat_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)`,
    )
      .bind(
        sessionId,
        authorized.executionWorkspaceId,
        workspaceRuntimeId,
        "0.1.0",
        WORKSPACE_RUNTIME_PROTOCOL_VERSION,
        request.headers.get("CF-Connecting-IP") ?? "127.0.0.1",
        now,
      )
      .run();
    await this.env.CONCLAVE_DB.prepare(
      "UPDATE execution_workspaces SET status = 'online', updated_at = ?1 WHERE id = ?2",
    )
      .bind(now, authorized.executionWorkspaceId)
      .run();

    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(socket: WebSocket, data: string | ArrayBuffer): void {
    const attachment = socket.deserializeAttachment() as {
      sessionId: string;
      executionWorkspaceId: string;
      workspaceRuntimeId: string;
    } | null;
    if (!attachment) return;
    this.socket = socket;
    this.sessionId = attachment.sessionId;
    this.executionWorkspaceId = attachment.executionWorkspaceId;
    this.workspaceRuntimeId = attachment.workspaceRuntimeId;
    void this.handleMessage(data, attachment.sessionId);
  }

  webSocketClose(socket: WebSocket): void {
    const attachment = socket.deserializeAttachment() as {
      sessionId: string;
    } | null;
    if (attachment) void this.close(socket, attachment.sessionId);
  }

  webSocketError(socket: WebSocket): void {
    const attachment = socket.deserializeAttachment() as {
      sessionId: string;
    } | null;
    if (attachment) void this.close(socket, attachment.sessionId);
  }

  private async close(socket: WebSocket, sessionId: string): Promise<void> {
    if (
      !isCurrentWorkspaceSocket(this.socket, this.sessionId, socket, sessionId)
    ) {
      return;
    }
    this.socket = null;
    const now = new Date().toISOString();
    await this.env.CONCLAVE_DB.prepare(
      "UPDATE workspace_sessions SET disconnected_at = ?1 WHERE id = ?2",
    )
      .bind(now, sessionId)
      .run();
    if (this.executionWorkspaceId) {
      await this.env.CONCLAVE_DB.prepare(
        "UPDATE execution_workspaces SET status = 'offline', updated_at = ?1 WHERE id = ?2",
      )
        .bind(now, this.executionWorkspaceId)
        .run();
    }
  }

  private async handleMessage(data: unknown, sessionId: string): Promise<void> {
    let message: WorkspaceRuntimeMessage;
    try {
      const raw = typeof data === "string" ? JSON.parse(data) : data;
      message = parseWorkspaceRuntimeMessage(raw);
    } catch (error) {
      this.sendError(
        error instanceof Error
          ? error.message
          : "Invalid Workspace protocol message",
      );
      return;
    }
    if (
      message.workspaceRuntimeId &&
      message.workspaceRuntimeId !== this.workspaceRuntimeId
    ) {
      this.socket?.close(1008, "Workspace runtime identity mismatch");
      return;
    }
    if (
      message.executionWorkspaceId &&
      message.executionWorkspaceId !== this.executionWorkspaceId
    ) {
      this.socket?.close(1008, "Execution Workspace mismatch");
      return;
    }
    const now = new Date().toISOString();
    switch (message.type) {
      case "workspace.hello":
        this.send({
          protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
          protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
          messageId: `message-${crypto.randomUUID()}`,
          correlationId: message.messageId,
          timestamp: now,
          type: "workspace.hello.ack",
          executionWorkspaceId: this.executionWorkspaceId ?? undefined,
          workspaceRuntimeId: this.workspaceRuntimeId ?? undefined,
          payload: { sessionId, heartbeatIntervalMs: 15000, serverTime: now },
        });
        return;
      case "workspace.heartbeat":
        if (message.payload && typeof message.payload === "object") {
          await this.env.CONCLAVE_DB.prepare(
            "UPDATE workspace_sessions SET last_heartbeat_at = ?1 WHERE id = ?2",
          )
            .bind(now, sessionId)
            .run();
        }
        this.send({
          protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
          protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
          messageId: `message-${crypto.randomUUID()}`,
          correlationId: message.messageId,
          timestamp: now,
          type: "workspace.heartbeat.ack",
          executionWorkspaceId: this.executionWorkspaceId ?? undefined,
          workspaceRuntimeId: this.workspaceRuntimeId ?? undefined,
          payload: { acknowledged: true, serverTime: now },
        });
        return;
      case "workspace.sync.request":
        await this.syncWorkspace(message.messageId);
        return;
      case "worker.status":
        await this.recordWorkerStatus(message.payload);
        return;
      case "credential.status":
        await this.recordCredentialStatus(message.payload);
        return;
      case "workstream.status":
        // Runtime readiness is logical-only. Never persist or relay a local
        // absolute path, repository clone path, or checkout path.
        return;
      case "checkout.status":
        await this.recordCheckoutStatus(message.payload);
        return;
      case "assignment.result":
        await recordAssignmentResult(
          this.env.CONCLAVE_DB,
          message.assignmentId!,
          message.payload as never,
        );
        return;
      case "assignment.error":
        await recordAssignmentError(
          this.env.CONCLAVE_DB,
          message.assignmentId!,
          message.payload as never,
        );
        return;
      case "assignment.cancelled":
        await recordAssignmentCancelled(
          this.env.CONCLAVE_DB,
          message.assignmentId!,
          message.payload as never,
        );
        return;
      default:
        return;
    }
  }

  private async syncWorkspace(correlationId: string): Promise<void> {
    const workspaceId = this.executionWorkspaceId;
    if (!workspaceId) return;
    const desiredRows = await this.env.CONCLAVE_DB.prepare(
      `SELECT b.worker_id AS configured_worker_id,
              b.desired_version_policy, b.enabled,
              b.package_status, b.credential_status, b.permissions_status,
              cw.worker_type_id,
              wt.display_name, wt.status AS worker_type_status,
              wv.version, wv.protocol_version,
              wv.supported_os_json, wv.supported_arch_json,
              wv.capabilities_json, wv.permissions_json, wv.package_digest,
              wv.package_r2_key, wv.signature, wv.entrypoint,
              wv.publisher
       FROM worker_workspace_bindings b
       JOIN configured_workers cw
         ON cw.id = b.worker_id AND cw.status = 'active'
       JOIN workers wt
         ON wt.id = cw.worker_type_id AND wt.status = 'active'
       LEFT JOIN worker_versions wv ON wv.worker_id = cw.worker_type_id
        AND COALESCE(wv.is_revoked, 0) = 0
        AND (b.desired_version_policy IN ('latest', 'stable')
          OR wv.version = b.desired_version_policy)
       WHERE b.workspace_id = ?1 AND b.enabled = 1
       ORDER BY b.worker_id, wv.created_at DESC`,
    )
      .bind(workspaceId)
      .all<Record<string, unknown>>();
    const seen = new Set<string>();
    const desiredWorkers = (desiredRows.results ?? [])
      .filter((row) => {
        const workerId = String(row.configured_worker_id);
        if (seen.has(workerId)) return false;
        seen.add(workerId);
        return true;
      })
      .map((row) => {
        const packageAvailable =
          typeof row.version === "string" &&
          typeof row.package_r2_key === "string" &&
          typeof row.package_digest === "string" &&
          typeof row.signature === "string" &&
          typeof row.entrypoint === "string";
        return {
          workerId: String(row.configured_worker_id),
          workerTypeId: String(row.worker_type_id),
          packageWorkerId: String(row.worker_type_id),
          version: packageAvailable ? String(row.version) : "unavailable",
          packageAvailable,
          packageError: packageAvailable
            ? undefined
            : "Worker Type package is unavailable",
          publisher: String(row.publisher ?? "conclave"),
          protocolVersion: String(row.protocol_version ?? "5.0"),
          minHostVersion: "0.1.0",
          packageR2Key: String(row.package_r2_key ?? ""),
          packageDigest: String(row.package_digest ?? ""),
          signature: String(row.signature ?? ""),
          entrypoint: String(row.entrypoint ?? "package.bin"),
          permissions: jsonArray(row.permissions_json),
          supportedPlatforms: [
            ...jsonArray(row.supported_os_json),
            ...jsonArray(row.supported_arch_json),
          ],
          secretEnvironmentVariables: [],
          credentialStatus: String(row.credential_status ?? "unknown"),
          permissionsStatus: String(row.permissions_status ?? "unknown"),
        };
      });
    const installationRows = await this.env.CONCLAVE_DB.prepare(
      `SELECT configured_worker_id, resolved_version, status, error, installed_at, updated_at
       FROM configured_worker_installations WHERE workspace_id = ?1
       ORDER BY configured_worker_id`,
    )
      .bind(workspaceId)
      .all<Record<string, unknown>>();
    const installedWorkers = (installationRows.results ?? []).map((row) => ({
      workerId: String(row.configured_worker_id),
      version: String(row.resolved_version),
      status: String(row.status),
      error: row.error == null ? null : String(row.error),
      installedAt: row.installed_at == null ? null : String(row.installed_at),
      updatedAt: String(row.updated_at),
    }));
    const assignments = await this.env.CONCLAVE_DB.prepare(
      `SELECT id AS assignment_id, status
       FROM worker_assignments
       WHERE execution_workspace_id = ?1
         AND status IN ('created', 'dispatched', 'acknowledged', 'running')`,
    )
      .bind(workspaceId)
      .all<Record<string, unknown>>();
    this.send({
      protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
      protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
      messageId: `message-${crypto.randomUUID()}`,
      correlationId,
      timestamp: new Date().toISOString(),
      type: "workspace.sync.result",
      executionWorkspaceId: workspaceId,
      workspaceRuntimeId: this.workspaceRuntimeId ?? undefined,
      payload: {
        desiredWorkers,
        installedWorkers,
        credentialSetupIntents: desiredWorkers
          .filter((worker) => worker.credentialStatus === "setup_required")
          .map((worker) => ({
            workerId: worker.workerId,
            workspaceId,
            status: "requested",
          })),
        activeAssignmentIds: (assignments.results ?? []).map((row) =>
          String(row.assignment_id),
        ),
        assignmentStates: (assignments.results ?? []).map((row) => ({
          assignmentId: String(row.assignment_id),
          status: String(row.status),
        })),
      },
    });
  }

  private async recordWorkerStatus(payload: unknown): Promise<void> {
    const workspaceId = this.executionWorkspaceId;
    if (!workspaceId || !payload || typeof payload !== "object") return;
    const value = payload as Record<string, unknown>;
    const reports = Array.isArray(value.workers) ? value.workers : [value];
    for (const report of reports) {
      if (!report || typeof report !== "object") continue;
      const item = report as Record<string, unknown>;
      const workerId = typeof item.workerId === "string" ? item.workerId : null;
      const version = typeof item.version === "string" ? item.version : null;
      const status = typeof item.status === "string" ? item.status : null;
      if (!workerId || !version || !status) continue;
      const binding = await this.env.CONCLAVE_DB.prepare(
        `SELECT b.worker_id, b.updated_at, cw.worker_type_id
         FROM worker_workspace_bindings b
         JOIN configured_workers cw ON cw.id = b.worker_id
         WHERE b.worker_id = ?1 AND b.workspace_id = ?2
           AND b.enabled = 1 AND cw.status = 'active'`,
      )
        .bind(workerId, workspaceId)
        .first<{
          worker_id: string;
          updated_at: string;
          worker_type_id: string;
        }>();
      if (!binding) continue;
      const workerTypeId = binding.worker_type_id;
      const versionRow = await this.env.CONCLAVE_DB.prepare(
        `SELECT id FROM worker_versions
         WHERE worker_id = ?1 AND version = ?2 AND is_revoked = 0`,
      )
        .bind(workerTypeId, version)
        .first<{ id: string }>();
      if (!versionRow && version !== "unavailable") continue;
      const normalized = normalizeWorkspaceWorkerInstallationStatus(status);
      const now = new Date().toISOString();
      const packageStatus =
        status === "ready"
          ? "ready"
          : status === "failed"
            ? "failed"
            : status === "absent" || status === "removing"
              ? "absent"
              : "installing";
      const credentialStatus =
        typeof item.credentialStatus === "string"
          ? item.credentialStatus
          : null;
      const permissionsStatus =
        typeof item.permissionsStatus === "string"
          ? item.permissionsStatus
          : null;
      const effectiveReadiness =
        typeof item.effectiveReadiness === "string"
          ? item.effectiveReadiness
          : status === "ready" &&
              credentialStatus === "ready" &&
              permissionsStatus === "ready"
            ? "ready"
            : status === "failed"
              ? "failed"
              : "degraded";
      await this.env.CONCLAVE_DB.prepare(
        `INSERT INTO configured_worker_installations
           (id, configured_worker_id, workspace_id, worker_type_id, worker_version_id,
            resolved_version, status, error, installed_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?9)
         ON CONFLICT(workspace_id, configured_worker_id) DO UPDATE SET
           worker_type_id = excluded.worker_type_id,
           worker_version_id = excluded.worker_version_id,
           resolved_version = excluded.resolved_version,
           status = excluded.status,
           error = excluded.error,
           installed_at = COALESCE(configured_worker_installations.installed_at, excluded.installed_at),
           updated_at = excluded.updated_at`,
      )
        .bind(
          `installation-${workspaceId}-${workerId}`,
          workerId,
          workspaceId,
          workerTypeId,
          versionRow?.id ?? null,
          version,
          normalized,
          typeof item.error === "string" ? item.error : null,
          normalized === "ready" ? now : null,
        )
        .run();
      await this.env.CONCLAVE_DB.prepare(
        `UPDATE worker_workspace_bindings
         SET package_status = ?1,
             credential_status = COALESCE(?2, credential_status),
             permissions_status = COALESCE(?3, permissions_status),
             local_readiness = ?4,
             last_seen = ?5,
             updated_at = ?5
         WHERE worker_id = ?6 AND workspace_id = ?7`,
      )
        .bind(
          packageStatus,
          credentialStatus,
          permissionsStatus,
          effectiveReadiness,
          now,
          workerId,
          workspaceId,
        )
        .run();
      const activeAssignments = await this.env.CONCLAVE_DB.prepare(
        `SELECT COUNT(*) AS count FROM worker_assignments
          WHERE execution_workspace_id = ?1
            AND configured_worker_id = ?2
            AND status IN ('created', 'running', 'dispatched')`,
      )
        .bind(workspaceId, workerId)
        .first<{ count: number }>();
      await this.env.CONCLAVE_DB.prepare(
        `INSERT INTO configured_worker_observability_metrics
          (id, configured_worker_id, worker_type_id, workspace_id, ready,
           package_status, credential_status, permissions_status,
           active_assignments, auth_failure, convergence_latency_ms, recorded_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)`,
      )
        .bind(
          `configured-worker-metric-${crypto.randomUUID()}`,
          workerId,
          workerTypeId,
          workspaceId,
          effectiveReadiness === "ready" ? 1 : 0,
          packageStatus,
          credentialStatus ?? "unknown",
          permissionsStatus ?? "unknown",
          Number(activeAssignments?.count ?? 0),
          credentialStatus === "expired" ||
            credentialStatus === "error" ||
            credentialStatus === "setup_required"
            ? 1
            : 0,
          Math.max(0, Date.parse(now) - Date.parse(String(binding.updated_at))),
          now,
        )
        .run();
    }
  }

  private async recordCredentialStatus(payload: unknown): Promise<void> {
    const workspaceId = this.executionWorkspaceId;
    if (!workspaceId || !payload || typeof payload !== "object") return;
    const item = payload as Record<string, unknown>;
    const workerId = typeof item.workerId === "string" ? item.workerId : null;
    const status = typeof item.status === "string" ? item.status : null;
    if (!workerId || !status) return;
    const state =
      status === "ready"
        ? "ready"
        : status === "expired"
          ? "expired"
          : status === "needs_auth"
            ? "setup_required"
            : "error";
    const now = new Date().toISOString();
    const binding = await this.env.CONCLAVE_DB.prepare(
      `SELECT b.credential_status, b.permissions_status, b.package_status,
              b.updated_at, cw.worker_type_id
         FROM worker_workspace_bindings b
         JOIN configured_workers cw ON cw.id = b.worker_id
        WHERE b.worker_id = ?1 AND b.workspace_id = ?2
          AND b.enabled = 1 AND cw.status = 'active'`,
    )
      .bind(workerId, workspaceId)
      .first<{
        credential_status: string;
        permissions_status: string;
        package_status: string;
        updated_at: string;
        worker_type_id: string;
      }>();
    if (!binding) return;
    const readiness =
      state === "ready" &&
      binding.package_status === "ready" &&
      binding.permissions_status === "ready"
        ? "ready"
        : state === "expired" || state === "error"
          ? "degraded"
          : "setup_required";
    const activeAssignments = await this.env.CONCLAVE_DB.prepare(
      `SELECT COUNT(*) AS count FROM worker_assignments
        WHERE execution_workspace_id = ?1
          AND configured_worker_id = ?2
          AND status IN ('created', 'running', 'dispatched')`,
    )
      .bind(workspaceId, workerId)
      .first<{ count: number }>();
    await this.env.CONCLAVE_DB.batch([
      this.env.CONCLAVE_DB.prepare(
        `UPDATE workspace_worker_credentials
            SET state = ?1, updated_at = ?2
          WHERE worker_id = ?3 AND workspace_id = ?4`,
      ).bind(state, now, workerId, workspaceId),
      this.env.CONCLAVE_DB.prepare(
        `UPDATE worker_workspace_bindings
            SET credential_status = ?1, local_readiness = ?2,
                last_seen = ?3, updated_at = ?3
          WHERE worker_id = ?4 AND workspace_id = ?5`,
      ).bind(state, readiness, now, workerId, workspaceId),
      this.env.CONCLAVE_DB.prepare(
        `INSERT INTO configured_worker_observability_metrics
          (id, configured_worker_id, worker_type_id, workspace_id, ready,
           package_status, credential_status, permissions_status,
           active_assignments, auth_failure, convergence_latency_ms, recorded_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)`,
      ).bind(
        `configured-worker-metric-${crypto.randomUUID()}`,
        workerId,
        binding.worker_type_id,
        workspaceId,
        state === "ready" &&
          binding.package_status === "ready" &&
          binding.permissions_status === "ready"
          ? 1
          : 0,
        binding.package_status,
        state,
        binding.permissions_status,
        Number(activeAssignments?.count ?? 0),
        state === "expired" || state === "error" || state === "setup_required"
          ? 1
          : 0,
        Math.max(0, Date.parse(now) - Date.parse(String(binding.updated_at))),
        now,
      ),
    ]);
    if (state === "ready" && binding.credential_status !== "ready") {
      await this.env.CONCLAVE_DB.prepare(
        `INSERT INTO configured_worker_audit_log
          (id, configured_worker_id, workspace_id, actor_type, actor_id,
           action, target_id, details_json, created_at)
         VALUES (?1, ?2, ?3, 'workspace_runtime', ?4, 'worker.credential.ready', ?5, ?6, ?7)`,
      )
        .bind(
          `configured-worker-audit-${crypto.randomUUID()}`,
          workerId,
          workspaceId,
          workspaceId,
          `${workerId}:${workspaceId}`,
          JSON.stringify({ status }),
          now,
        )
        .run();
    }
  }

  private async provisionCheckout(request: Request): Promise<Response> {
    if (!this.socket) {
      return Response.json({ error: "Workspace is offline" }, { status: 503 });
    }
    const body = (await request.json()) as Record<string, unknown>;
    const checkoutId =
      typeof body.checkoutId === "string" ? body.checkoutId : null;
    const workstreamId =
      typeof body.workstreamId === "string" ? body.workstreamId : null;
    if (!checkoutId || !workstreamId) {
      return Response.json(
        { error: "checkoutId and workstreamId are required" },
        { status: 400 },
      );
    }
    const row = await this.env.CONCLAVE_DB.prepare(
      `SELECT c.id, c.status, c.workstream_id AS workstreamId,
              c.workspace_id AS workspaceId, c.repository_id AS repositoryId,
              c.revision, ws.project_id AS projectId, ew.status AS workspaceStatus,
              g.id AS grantId
       FROM workstream_checkouts c
       JOIN workstreams ws ON ws.id = c.workstream_id
       JOIN execution_workspaces ew ON ew.id = c.workspace_id
       LEFT JOIN workspace_project_grants g
         ON g.project_id = ws.project_id AND g.workspace_id = c.workspace_id
        AND g.status = 'active'
        AND (g.expires_at IS NULL OR g.expires_at > ?2)
       WHERE c.id = ?1 AND c.workstream_id = ?3 AND c.workspace_id = ?4`,
    )
      .bind(
        checkoutId,
        new Date().toISOString(),
        workstreamId,
        this.executionWorkspaceId,
      )
      .first<Record<string, unknown>>();
    if (!row)
      return Response.json({ error: "Checkout not found" }, { status: 404 });
    if (!row.grantId) {
      await this.env.CONCLAVE_DB.prepare(
        "UPDATE workstream_checkouts SET status = 'stale', updated_at = ?1 WHERE id = ?2",
      )
        .bind(new Date().toISOString(), checkoutId)
        .run();
      return Response.json(
        { error: "Workspace Project Grant is not active" },
        { status: 409 },
      );
    }
    if (row.workspaceStatus !== "online") {
      return Response.json({ error: "Workspace is offline" }, { status: 503 });
    }
    this.send({
      protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
      protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
      messageId: `message-${crypto.randomUUID()}`,
      correlationId: checkoutId,
      timestamp: new Date().toISOString(),
      type: "checkout.provision",
      executionWorkspaceId: this.executionWorkspaceId ?? undefined,
      workspaceRuntimeId: this.workspaceRuntimeId ?? undefined,
      payload: {
        checkoutId,
        workstreamId,
        repositoryId: String(row.repositoryId),
        revision: String(row.revision),
      },
    });
    return Response.json({ accepted: true, checkoutId, status: row.status });
  }

  private async sendCheckoutCommand(
    request: Request,
    type: "checkout.recover" | "checkout.archive" | "checkout.finalize",
  ): Promise<Response> {
    if (!this.socket)
      return Response.json({ error: "Workspace is offline" }, { status: 503 });
    const body = (await request.json()) as Record<string, unknown>;
    if (
      typeof body.checkoutId !== "string" ||
      body.checkoutId.trim().length === 0
    ) {
      return Response.json(
        { error: "checkoutId is required" },
        { status: 400 },
      );
    }
    this.send({
      protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
      protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
      messageId: `message-${crypto.randomUUID()}`,
      correlationId: body.checkoutId,
      timestamp: new Date().toISOString(),
      type,
      executionWorkspaceId: this.executionWorkspaceId ?? undefined,
      workspaceRuntimeId: this.workspaceRuntimeId ?? undefined,
      payload: body,
    });
    return Response.json({ accepted: true, checkoutId: body.checkoutId });
  }

  private async recordCheckoutStatus(payload: unknown): Promise<void> {
    if (!payload || typeof payload !== "object" || !this.executionWorkspaceId)
      return;
    const value = payload as Record<string, unknown>;
    const checkoutId =
      typeof value.checkoutId === "string" ? value.checkoutId : null;
    const status = typeof value.status === "string" ? value.status : null;
    if (!checkoutId || !status) return;
    const dbStatus = ["checkpointed", "rolled_back"].includes(status)
      ? "ready"
      : status === "recovery_required"
        ? "stale"
        : status;
    if (!["provisioning", "ready", "stale", "deleted"].includes(dbStatus))
      return;
    const checkout = await this.env.CONCLAVE_DB.prepare(
      `SELECT c.id, c.workstream_id AS workstreamId, ws.project_id AS projectId
       FROM workstream_checkouts c JOIN workstreams ws ON ws.id = c.workstream_id
       WHERE c.id = ?1 AND c.workspace_id = ?2`,
    )
      .bind(checkoutId, this.executionWorkspaceId)
      .first<Record<string, unknown>>();
    if (!checkout) return;
    const now = new Date().toISOString();
    await this.env.CONCLAVE_DB.prepare(
      `UPDATE workstream_checkouts
       SET status = ?1, revision = COALESCE(?2, revision), updated_at = ?3
       WHERE id = ?4 AND workspace_id = ?5`,
    )
      .bind(
        dbStatus,
        typeof value.headRevision === "string" ? value.headRevision : null,
        now,
        checkoutId,
        this.executionWorkspaceId,
      )
      .run();
    const changed = value.changed === true;
    const revision =
      typeof value.headRevision === "string" ? value.headRevision : null;
    const workRequestId =
      typeof value.workRequestId === "string" ? value.workRequestId : null;
    if (status === "checkpointed" && changed && revision && workRequestId) {
      const sequence = await this.env.CONCLAVE_DB.prepare(
        "SELECT COALESCE(MAX(sequence), 0) + 1 AS nextSequence FROM workstream_checkpoints WHERE checkout_id = ?1",
      )
        .bind(checkoutId)
        .first<{ nextSequence: number }>();
      const checkpointId = `checkpoint-${crypto.randomUUID()}`;
      await this.env.CONCLAVE_DB.prepare(
        `INSERT INTO workstream_checkpoints
         (id, workstream_id, checkout_id, sequence, revision, summary, created_by_work_request_id, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
      )
        .bind(
          checkpointId,
          String(checkout.workstreamId),
          checkoutId,
          sequence?.nextSequence ?? 1,
          revision,
          changed
            ? "Managed Workstream checkpoint"
            : "No-change Workstream result",
          workRequestId,
          now,
        )
        .run();
      await this.env.CONCLAVE_DB.prepare(
        `INSERT INTO workstream_current_checkpoints (workstream_id, checkpoint_id, updated_at)
         VALUES (?1, ?2, ?3)
         ON CONFLICT(workstream_id) DO UPDATE SET checkpoint_id = excluded.checkpoint_id, updated_at = excluded.updated_at`,
      )
        .bind(String(checkout.workstreamId), checkpointId, now)
        .run();
    }
    if (revision && typeof value.diff === "string" && value.diff.length > 0) {
      await this.env.CONCLAVE_DB.prepare(
        `INSERT INTO workstream_diff_artifacts
         (id, workstream_id, checkout_id, work_request_id, revision, outcome, diff_text, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
      )
        .bind(
          `diff-${crypto.randomUUID()}`,
          String(checkout.workstreamId),
          checkoutId,
          workRequestId,
          revision,
          status === "checkpointed"
            ? "success"
            : status === "rolled_back"
              ? "cancelled"
              : "failure",
          String(value.diff).slice(0, 64 * 1024),
          now,
        )
        .run();
    }
    await createEventPublisher(this.env).publish({
      type: "workstream.checkout.status",
      workspaceId: this.executionWorkspaceId,
      projectId: String(checkout.projectId),
      payload: {
        entityId: checkoutId,
        status: dbStatus,
        summary:
          typeof value.error === "string" ? value.error : `Checkout ${status}`,
      },
      durable: true,
      idempotencyKey: `checkout-status:${checkoutId}:${now}`,
    });
  }

  private async dispatchAssignment(request: Request): Promise<Response> {
    if (!this.socket)
      return Response.json({ error: "Workspace is offline" }, { status: 503 });
    const body = (await request.json()) as WorkspaceAssignmentCorrelation & {
      payload: unknown;
    };
    const row = await this.env.CONCLAVE_DB.prepare(
      `SELECT wa.id, wa.execution_workspace_id, wa.runtime_identity_id,
              wa.worker_id, wa.configured_worker_id, wa.run_id, wa.task_id, wa.attempt_id,
              wa.idempotency_key, wa.status
       FROM worker_assignments wa
       JOIN workspace_project_grants g
         ON g.id = wa.workspace_project_grant_id
        AND g.project_id = wa.project_id
        AND g.workspace_id = wa.execution_workspace_id
        AND g.status = 'active'
        AND (g.expires_at IS NULL OR g.expires_at > ?2)
       WHERE wa.id = ?1`,
    )
      .bind(body.assignmentId, new Date().toISOString())
      .first<Record<string, unknown>>();
    if (
      !row ||
      !workspaceAssignmentContextMatches(body, row) ||
      !workspaceAssignmentIsActive(row)
    ) {
      return Response.json(
        { error: "Assignment is not valid for this Workspace runtime" },
        { status: 409 },
      );
    }
    this.send({
      protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
      protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
      messageId: `message-${crypto.randomUUID()}`,
      timestamp: new Date().toISOString(),
      type: "assignment.start",
      ...body,
      payload: body.payload,
    });
    return Response.json({ delivered: true });
  }

  private async cancelAssignment(request: Request): Promise<Response> {
    if (!this.socket)
      return Response.json({ error: "Workspace is offline" }, { status: 503 });
    const body = (await request.json()) as WorkspaceAssignmentCorrelation & {
      payload: unknown;
    };
    this.send({
      protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
      protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
      messageId: `message-${crypto.randomUUID()}`,
      timestamp: new Date().toISOString(),
      type: "assignment.cancel",
      ...body,
      payload: body.payload,
    });
    return Response.json({ delivered: true });
  }

  private send(message: Record<string, unknown>): void {
    if (!this.socket) return;
    this.socket.send(serializeWorkspaceRuntimeMessage(message as never));
  }

  private sendError(error: string): void {
    this.socket?.send(JSON.stringify({ error }));
  }
}
