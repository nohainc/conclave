import {
  parseWorkspaceRuntimeMessage,
  serializeWorkspaceRuntimeMessage,
  WORKSPACE_RUNTIME_PROTOCOL_NAME,
  WORKSPACE_RUNTIME_PROTOCOL_VERSION,
  type WorkspaceRuntimeMessage,
} from "@conclave/host-protocol";
import {
  recordAssignmentCancelled,
  recordAssignmentError,
  recordAssignmentResult,
} from "./assignment-dispatcher.js";
import { extractBearerToken, hashToken } from "../../../packages/security/src/index.js";

const jsonArray = (value: unknown): string[] => {
  if (typeof value !== "string") return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed.filter((item): item is string => typeof item === "string") : [];
  } catch {
    return [];
  }
};

export function normalizeWorkspaceWorkerInstallationStatus(status: string):
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
    message.workerId === String(row.worker_id) &&
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
    if (!isCurrentWorkspaceSocket(this.socket, this.sessionId, socket, sessionId)) {
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
      this.sendError(error instanceof Error ? error.message : "Invalid Workspace protocol message");
      return;
    }
    if (
      message.workspaceRuntimeId &&
      message.workspaceRuntimeId !== this.workspaceRuntimeId
    ) {
      this.socket?.close(1008, "Workspace runtime identity mismatch");
      return;
    }
    if (message.executionWorkspaceId && message.executionWorkspaceId !== this.executionWorkspaceId) {
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
      case "assignment.result":
        await recordAssignmentResult(this.env.CONCLAVE_DB, message.assignmentId!, message.payload as never);
        return;
      case "assignment.error":
        await recordAssignmentError(this.env.CONCLAVE_DB, message.assignmentId!, message.payload as never);
        return;
      case "assignment.cancelled":
        await recordAssignmentCancelled(this.env.CONCLAVE_DB, message.assignmentId!, message.payload as never);
        return;
      default:
        return;
    }
  }

  private async syncWorkspace(correlationId: string): Promise<void> {
    const workspaceId = this.executionWorkspaceId;
    if (!workspaceId) return;
    const desiredRows = await this.env.CONCLAVE_DB.prepare(
      `SELECT d.worker_id, d.version_policy, d.enabled,
              w.publisher, wv.version, wv.protocol_version,
              wv.supported_os_json, wv.supported_arch_json,
              wv.capabilities_json, wv.permissions_json, wv.package_digest,
              wv.package_r2_key, wv.signature, wv.entrypoint
       FROM workspace_worker_desired_state d
       JOIN workers w ON w.id = d.worker_id AND w.status = 'active'
       JOIN worker_versions wv ON wv.worker_id = d.worker_id
        AND wv.is_revoked = 0
        AND (d.version_policy = 'latest' OR wv.version = d.version_policy)
       WHERE d.workspace_id = ?1 AND d.enabled = 1
       ORDER BY d.worker_id, wv.created_at DESC`,
    )
      .bind(workspaceId)
      .all<Record<string, unknown>>();
    const seen = new Set<string>();
    const desiredWorkers = (desiredRows.results ?? [])
      .filter((row) => {
        const workerId = String(row.worker_id);
        if (seen.has(workerId)) return false;
        seen.add(workerId);
        return true;
      })
      .map((row) => ({
        workerId: String(row.worker_id),
        version: String(row.version),
        publisher: String(row.publisher),
        protocolVersion: String(row.protocol_version),
        minHostVersion: "0.1.0",
        packageR2Key: String(row.package_r2_key),
        packageDigest: String(row.package_digest),
        signature: String(row.signature),
        entrypoint: String(row.entrypoint),
        permissions: jsonArray(row.permissions_json),
        supportedPlatforms: [
          ...jsonArray(row.supported_os_json),
          ...jsonArray(row.supported_arch_json),
        ],
        secretEnvironmentVariables: [],
      }));
    const installationRows = await this.env.CONCLAVE_DB.prepare(
      `SELECT worker_id, resolved_version, status, error, installed_at, updated_at
       FROM workspace_worker_installations WHERE workspace_id = ?1
       ORDER BY worker_id`,
    )
      .bind(workspaceId)
      .all<Record<string, unknown>>();
    const installedWorkers = (installationRows.results ?? []).map((row) => ({
      workerId: String(row.worker_id),
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
        credentialSetupIntents: [],
        activeAssignmentIds: (assignments.results ?? []).map((row) => String(row.assignment_id)),
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
      const versionRow = await this.env.CONCLAVE_DB.prepare(
        `SELECT id FROM worker_versions
         WHERE worker_id = ?1 AND version = ?2 AND is_revoked = 0`,
      )
        .bind(workerId, version)
        .first<{ id: string }>();
      if (!versionRow) continue;
      const normalized = normalizeWorkspaceWorkerInstallationStatus(status);
      const now = new Date().toISOString();
      await this.env.CONCLAVE_DB.prepare(
        `INSERT INTO workspace_worker_installations
           (id, workspace_id, worker_id, worker_version_id, resolved_version,
            status, error, installed_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8)
         ON CONFLICT(workspace_id, worker_id) DO UPDATE SET
           worker_version_id = excluded.worker_version_id,
           resolved_version = excluded.resolved_version,
           status = excluded.status,
           error = excluded.error,
           installed_at = COALESCE(workspace_worker_installations.installed_at, excluded.installed_at),
           updated_at = excluded.updated_at`,
      )
        .bind(
          `installation-${workspaceId}-${workerId}`,
          workspaceId,
          workerId,
          versionRow.id,
          version,
          normalized,
          typeof item.error === "string" ? item.error : null,
          normalized === "ready" ? now : null,
        )
        .run();
    }
  }

  private async dispatchAssignment(request: Request): Promise<Response> {
    if (!this.socket) return Response.json({ error: "Workspace is offline" }, { status: 503 });
    const body = (await request.json()) as WorkspaceAssignmentCorrelation & { payload: unknown };
    const row = await this.env.CONCLAVE_DB.prepare(
      `SELECT wa.id, wa.execution_workspace_id, wa.runtime_identity_id,
              wa.worker_id, wa.run_id, wa.task_id, wa.attempt_id,
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
    if (!row || !workspaceAssignmentContextMatches(body, row) || !workspaceAssignmentIsActive(row)) {
      return Response.json({ error: "Assignment is not valid for this Workspace runtime" }, { status: 409 });
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
    if (!this.socket) return Response.json({ error: "Workspace is offline" }, { status: 503 });
    const body = (await request.json()) as WorkspaceAssignmentCorrelation & { payload: unknown };
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
