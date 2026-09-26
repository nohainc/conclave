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

function runtimeFacts(payload: unknown): {
  platform: string | null;
  architecture: string | null;
  hostname: string | null;
  appVersion: string | null;
  capabilities: string[];
} {
  if (!payload || typeof payload !== "object") {
    return {
      platform: null,
      architecture: null,
      hostname: null,
      appVersion: null,
      capabilities: [],
    };
  }
  const value = payload as Record<string, unknown>;
  const rawCapabilities =
    value.capabilities && typeof value.capabilities === "object"
      ? (value.capabilities as Record<string, unknown>)
      : {};
  const text = (candidate: unknown): string | null => {
    if (typeof candidate !== "string") return null;
    const normalized = candidate.trim();
    return normalized.length > 0 && normalized.length <= 200
      ? normalized
      : null;
  };
  const capabilities = Array.isArray(value.runtimeCapabilities)
    ? value.runtimeCapabilities
        .filter((item): item is string => typeof item === "string")
        .slice(0, 100)
    : [
        ...jsonArray(JSON.stringify(rawCapabilities.supportedRuntimes)),
        ...jsonArray(JSON.stringify(rawCapabilities.customCapabilities)),
      ];
  return {
    platform: text(value.platform ?? rawCapabilities.os),
    architecture: text(value.architecture ?? rawCapabilities.arch),
    hostname: text(value.hostname),
    appVersion: text(
      value.appVersion ?? value.hostVersion ?? rawCapabilities.version,
    ),
    capabilities: [
      ...new Set(capabilities.map((item) => item.trim()).filter(Boolean)),
    ],
  };
}

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
    message.workerId === String(row.workspace_worker_id ?? row.worker_id) &&
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
    // This event carries no Worker configuration. AX rereads the owner-scoped
    // inventory endpoint after each complete snapshot.
    if (this.executionWorkspaceId) {
      await createEventPublisher(this.env).publish({
        type: "worker.inventory.updated",
        workspaceId: this.executionWorkspaceId,
        payload: { status: "updated" },
        durable: false,
      });
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
        {
          const facts = runtimeFacts(message.payload);
          await this.env.CONCLAVE_DB.prepare(
            `INSERT INTO workspace_runtime_facts
             (workspace_id, platform, architecture, hostname, app_version,
              runtime_capabilities_json, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(workspace_id) DO UPDATE SET
               platform = excluded.platform,
               architecture = excluded.architecture,
               hostname = excluded.hostname,
               app_version = excluded.app_version,
               runtime_capabilities_json = excluded.runtime_capabilities_json,
               updated_at = excluded.updated_at`,
          )
            .bind(
              this.executionWorkspaceId,
              facts.platform,
              facts.architecture,
              facts.hostname,
              facts.appVersion,
              JSON.stringify(facts.capabilities),
              now,
            )
            .run();
        }
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
      case "worker.inventory":
        await this.recordWorkerInventory(message.payload);
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

  private async recordWorkerInventory(payload: unknown): Promise<void> {
    const workspaceId = this.executionWorkspaceId;
    if (!workspaceId || !payload || typeof payload !== "object") return;
    const reports = (payload as Record<string, unknown>).workers;
    if (!Array.isArray(reports) || reports.length > 500) return;
    const owner = await this.env.CONCLAVE_DB.prepare(
      "SELECT owner_user_id FROM execution_workspaces WHERE id = ?1 AND status != 'revoked'",
    )
      .bind(workspaceId)
      .first<{ owner_user_id: string }>();
    if (!owner) return;
    const now = new Date().toISOString();
    const fullSnapshot =
      (payload as Record<string, unknown>).fullSnapshot === true;
    const reportedWorkerIds = new Set<string>();
    for (const raw of reports) {
      if (!raw || typeof raw !== "object") continue;
      const item = raw as Record<string, unknown>;
      const workerId = item.workerId;
      const workerTypeId = item.workerTypeId;
      const name = item.name;
      const status = item.status;
      const revision = item.revision;
      const concurrency = item.localConcurrencyLimit;
      if (
        typeof workerId !== "string" ||
        typeof workerTypeId !== "string" ||
        typeof name !== "string" ||
        typeof status !== "string" ||
        !Number.isSafeInteger(revision) ||
        (revision as number) < 1 ||
        !Number.isInteger(concurrency) ||
        (concurrency as number) < 1
      ) {
        continue;
      }
      // Only structurally valid entries count as reported by an authoritative
      // snapshot. Malformed items must not keep omitted Workers alive.
      reportedWorkerIds.add(workerId);
      const previous = await this.env.CONCLAVE_DB.prepare(
        "SELECT workspace_id, revision, removed_by_snapshot FROM workspace_worker_inventory WHERE worker_id = ?1",
      )
        .bind(workerId)
        .first<{
          workspace_id: string;
          revision: number;
          removed_by_snapshot: number;
        }>();
      // A Worker ID is permanently owned by the Workspace that first synced
      // it. Revisions only move forward, including removal tombstones.
      if (
        (previous && previous.workspace_id !== workspaceId) ||
        (previous &&
          Number(previous.revision) >= (revision as number) &&
          !(
            Number(previous.removed_by_snapshot) === 1 &&
            status !== "removed" &&
            Number(previous.revision) === revision
          ))
      ) {
        continue;
      }
      const arrayJson = (value: unknown, max: number): string =>
        JSON.stringify(
          Array.isArray(value)
            ? value
                .filter((entry): entry is string => typeof entry === "string")
                .map((entry) => entry.trim())
                .filter(Boolean)
                .slice(0, max)
            : [],
        );
      const nullableText = (value: unknown, max: number): string | null =>
        typeof value === "string" && value.trim().length <= max
          ? value.trim() || null
          : null;
      const authStrategy = [
        "none",
        "browser_auth",
        "api_key",
        "local_endpoint",
      ].includes(String(item.authStrategy))
        ? String(item.authStrategy)
        : "none";
      const credentialStatus = [
        "not_required",
        "ready",
        "needs_authentication",
        "expired",
        "error",
      ].includes(String(item.credentialStatus))
        ? String(item.credentialStatus)
        : "error";
      await this.env.CONCLAVE_DB.prepare(
        `INSERT INTO workspace_worker_inventory
          (worker_id, workspace_id, owner_user_id, worker_type_id, name,
           status, auth_strategy, default_model, allowed_models_json,
           capabilities_json, local_permissions_summary_json,
           local_concurrency_limit, adapter_version, credential_status,
           revision, created_at, updated_at, last_seen_at, removed_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)
         ON CONFLICT(worker_id) DO UPDATE SET
           worker_type_id = excluded.worker_type_id,
           name = excluded.name,
           status = excluded.status,
           auth_strategy = excluded.auth_strategy,
           default_model = excluded.default_model,
           allowed_models_json = excluded.allowed_models_json,
           capabilities_json = excluded.capabilities_json,
           local_permissions_summary_json = excluded.local_permissions_summary_json,
           local_concurrency_limit = excluded.local_concurrency_limit,
           adapter_version = excluded.adapter_version,
           credential_status = excluded.credential_status,
           revision = excluded.revision,
           updated_at = excluded.updated_at,
           last_seen_at = excluded.last_seen_at,
           removed_at = excluded.removed_at,
           removed_by_snapshot = 0
         WHERE workspace_worker_inventory.workspace_id = excluded.workspace_id
           AND (workspace_worker_inventory.revision < excluded.revision OR
             (workspace_worker_inventory.removed_by_snapshot = 1 AND excluded.status != 'removed' AND workspace_worker_inventory.revision = excluded.revision))`,
      )
        .bind(
          workerId,
          workspaceId,
          owner.owner_user_id,
          workerTypeId,
          name.trim().slice(0, 200),
          ["ready", "needs_attention", "disabled", "removed"].includes(status)
            ? status
            : "needs_attention",
          authStrategy,
          nullableText(item.defaultModel, 256),
          arrayJson(item.allowedModels, 128),
          arrayJson(item.capabilities, 128),
          arrayJson(item.localPermissionsSummary, 64),
          Math.min(1024, concurrency as number),
          nullableText(item.adapterVersion, 128),
          credentialStatus,
          revision,
          nullableText(item.createdAt, 40) ?? now,
          now,
          nullableText(item.lastSeenAt, 40) ?? now,
          status === "removed" ? now : null,
        )
        .run();
      await this.env.CONCLAVE_DB.prepare(
        `INSERT OR IGNORE INTO v7_worker_scheduling (worker_id, state, updated_at)
         SELECT worker_id, 'disabled', ?2 FROM workspace_worker_inventory WHERE worker_id = ?1`,
      )
        .bind(workerId, now)
        .run();
    }
    // Full snapshots are authoritative. Omission marks a tombstone without
    // inventing a source revision; replaying the same snapshot is idempotent.
    if (fullSnapshot) {
      const existing = await this.env.CONCLAVE_DB.prepare(
        `SELECT worker_id FROM workspace_worker_inventory
          WHERE workspace_id = ?1 AND status != 'removed'`,
      )
        .bind(workspaceId)
        .all<{ worker_id: string }>();
      for (const row of existing.results ?? []) {
        if (reportedWorkerIds.has(row.worker_id)) continue;
        await this.env.CONCLAVE_DB.prepare(
          `UPDATE workspace_worker_inventory SET status = 'removed', removed_at = ?2, removed_by_snapshot = 1,
             updated_at = ?2 WHERE worker_id = ?1 AND workspace_id = ?3 AND status != 'removed'`,
        )
          .bind(row.worker_id, now, workspaceId)
          .run();
        await this.env.CONCLAVE_DB.prepare(
          `UPDATE v7_worker_scheduling SET state = 'disabled', updated_at = ?2
            WHERE worker_id = ?1 AND state != 'disabled'`,
        )
          .bind(row.worker_id, now)
          .run();
      }
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
              wa.worker_id, wa.workspace_worker_id,
              wa.run_id, wa.task_id, wa.attempt_id,
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
