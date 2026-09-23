import {
  AGENT_PROTOCOL_NAME,
  AGENT_PROTOCOL_VERSION,
  parseAgentMessage,
  serializeAgentMessage,
  type AgentProtocolMessage,
  type AssignmentStartPayload,
  type AssignmentCancelPayload,
  type AssignmentResultPayload,
  type AssignmentFailurePayload,
  type AssignmentCancelledPayload,
} from "@conclave/host-protocol";

type DesiredWorker = Record<string, unknown>;
type DesiredPlugin = Record<string, unknown>;
import {
  recordAssignmentResult,
  recordAssignmentError,
  recordAssignmentCancelled,
} from "./assignment-dispatcher.js";
import {
  extractBearerToken,
  hashToken,
} from "../../../packages/security/src/index.js";
import { createEventPublisher } from "./event-publisher.js";

function parseJsonArray(value: unknown): string[] {
  if (typeof value !== "string") return [];
  try {
    const parsed: unknown = JSON.parse(value);
    return Array.isArray(parsed)
      ? parsed.filter((item): item is string => typeof item === "string")
      : [];
  } catch {
    return [];
  }
}

function parseJsonObjectKeys(value: unknown): string[] {
  if (typeof value !== "string") return [];
  try {
    const parsed: unknown = JSON.parse(value);
    return parsed !== null &&
      typeof parsed === "object" &&
      !Array.isArray(parsed)
      ? Object.keys(parsed)
      : [];
  } catch {
    return [];
  }
}

export interface GatewayEnv {
  CONCLAVE_DB: D1Database;
  CONCLAVE_ENVIRONMENT?: string;
  CONCLAVE_REALTIME_GATEWAY?: DurableObjectNamespace;
}

export interface AssignmentCorrelation {
  workspaceId: string;
  hostId: string;
  workerId: string;
  runId: string;
  taskId: string;
  attemptId: string;
  assignmentId: string;
  idempotencyKey: string;
}

export function assignmentContextMatches(
  message: AssignmentCorrelation,
  row: Record<string, unknown>,
): boolean {
  return (
    message.workspaceId === String(row.workspace_id) &&
    message.hostId === String(row.host_id) &&
    message.workerId === String(row.worker_id) &&
    message.runId === String(row.run_id) &&
    message.taskId === String(row.task_id) &&
    message.attemptId === String(row.attempt_id) &&
    message.assignmentId === String(row.id) &&
    message.idempotencyKey === String(row.idempotency_key)
  );
}

export function assignmentIsActive(row: Record<string, unknown>): boolean {
  return !["completed", "failed", "cancelled", "timed_out"].includes(
    String(row.status),
  );
}

export function activeAssignmentIds(
  states: readonly { assignmentId: string; status: string }[],
): string[] {
  return states
    .filter(({ status }) => assignmentIsActive({ status }))
    .map(({ assignmentId }) => assignmentId);
}

export function isCurrentSocketSession(
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

export function isWorkspaceAuthorized(
  authorizedWorkspaceIds: ReadonlySet<string>,
  workspaceId: string,
): boolean {
  return authorizedWorkspaceIds.has(workspaceId);
}

export class HostGateway implements DurableObject {
  private socket: WebSocket | null = null;
  private hostId: string | null = null;
  private workspaceId: string | null = null;
  private authorizedWorkspaceIds = new Set<string>();
  private sessionId: string | null = null;
  private readonly pendingAcks = new Map<
    string,
    {
      resolve: (value: unknown) => void;
      reject: (error: Error) => void;
      timer: ReturnType<typeof setTimeout>;
    }
  >();

  constructor(
    private readonly state: DurableObjectState,
    private readonly env: GatewayEnv,
  ) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    // 1. WebSocket Upgrade from Host
    if (request.headers.get("Upgrade")?.toLowerCase() === "websocket") {
      return this.handleWebSocketConnect(request, url);
    }

    // 2. Internal DO RPC: Query live status
    if (request.method === "GET" && url.pathname === "/status") {
      return Response.json({
        online: this.socket !== null,
        hostId: this.hostId,
        workspaceId: this.workspaceId,
        authorizedWorkspaceIds: [...this.authorizedWorkspaceIds].sort(),
        sessionId: this.sessionId,
        pendingAcksCount: this.pendingAcks.size,
      });
    }

    // 3. Internal DO RPC: Dispatch assignment
    if (request.method === "POST" && url.pathname === "/dispatch-assignment") {
      return this.handleDispatchAssignment(request);
    }

    // 4. Internal DO RPC: Cancel assignment
    if (request.method === "POST" && url.pathname === "/cancel-assignment") {
      return this.handleCancelAssignment(request);
    }

    // 5. Internal DO RPC: Post generic message envelope
    if (request.method === "POST" && url.pathname === "/post-message") {
      return this.handlePostMessage(request);
    }

    return Response.json({ error: "Not found" }, { status: 404 });
  }

  /**
   * Handles incoming WebSocket connection upgrade from an enrolled Conclave Host.
   */
  private async handleWebSocketConnect(
    request: Request,
    url: URL,
  ): Promise<Response> {
    const hostId = url.searchParams.get("hostId");
    const workspaceId = url.searchParams.get("workspaceId");

    if (!hostId || !workspaceId) {
      return Response.json(
        { error: "hostId and workspaceId query parameters are required" },
        { status: 400 },
      );
    }

    const token = extractBearerToken(request.headers);
    if (!token) {
      return Response.json(
        { error: "Host authentication required" },
        { status: 401 },
      );
    }
    const tokenHash = await hashToken(token);
    const enrolledAgent = await this.env.CONCLAVE_DB.prepare(
      `SELECT h.id FROM hosts h
       JOIN host_workspace_bindings b ON b.host_id = h.id
       WHERE h.id = ?1 AND b.workspace_id = ?2 AND b.status = 'active'
         AND h.auth_token_hash = ?3 AND h.revoked_at IS NULL`,
    )
      .bind(hostId, workspaceId, tokenHash)
      .first<{ id: string }>();
    if (!enrolledAgent) {
      return Response.json(
        { error: "Invalid or revoked Host credential" },
        { status: 401 },
      );
    }
    const bindings = await this.env.CONCLAVE_DB.prepare(
      `SELECT workspace_id FROM host_workspace_bindings
       WHERE host_id = ?1 AND status = 'active'`,
    )
      .bind(hostId)
      .all<{ workspace_id: string }>();

    // Close any previous stale socket for this host instance
    if (this.socket) {
      try {
        this.socket.close(1000, "Superceded by new connection");
      } catch {
        // ignore
      }
      this.socket = null;
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];

    server.accept();
    this.socket = server;
    this.hostId = hostId;
    this.workspaceId = workspaceId;
    this.authorizedWorkspaceIds = new Set(
      (bindings.results ?? []).map((row) => String(row.workspace_id)),
    );
    this.sessionId = `sess-${crypto.randomUUID()}`;

    const now = new Date().toISOString();

    // Update D1 database
    try {
      await this.env.CONCLAVE_DB.prepare(
        `UPDATE hosts SET status = 'online', last_heartbeat_at = ?1, updated_at = ?1 WHERE id = ?2`,
      )
        .bind(now, hostId)
        .run();

      await this.env.CONCLAVE_DB.prepare(
        `INSERT INTO host_sessions (id, host_id, client_version, protocol_version, ip_address, connected_at, last_heartbeat_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)`,
      )
        .bind(
          this.sessionId,
          hostId,
          "0.2.0",
          AGENT_PROTOCOL_VERSION,
          request.headers.get("CF-Connecting-IP") || "127.0.0.1",
          now,
        )
        .run();
    } catch (err) {
      console.error("Failed to record host session in D1", err);
    }

    server.addEventListener("message", (event) => {
      void this.handleIncomingMessage(event.data);
    });

    const connectedSessionId = this.sessionId;
    server.addEventListener("close", () => {
      this.handleSocketClose(server, connectedSessionId);
    });

    server.addEventListener("error", (err) => {
      console.error("Host Gateway WebSocket error", err);
      this.handleSocketClose(server, connectedSessionId);
    });

    return new Response(null, { status: 101, webSocket: client });
  }

  /**
   * Cleans up state on socket close.
   */
  private handleSocketClose(
    socket?: WebSocket,
    sessionId?: string | null,
  ): void {
    // A replaced socket may deliver its close event after the new session is
    // installed. It must not tear down the current session or mark the Host
    // offline in D1.
    if (!isCurrentSocketSession(this.socket, this.sessionId, socket, sessionId))
      return;
    if (!this.socket) return;
    this.socket = null;
    const now = new Date().toISOString();

    if (this.hostId && this.sessionId) {
      void this.env.CONCLAVE_DB.prepare(
        `UPDATE hosts SET status = 'offline', updated_at = ?1 WHERE id = ?2`,
      )
        .bind(now, this.hostId)
        .run();

      void this.env.CONCLAVE_DB.prepare(
        `UPDATE host_sessions SET disconnected_at = ?1 WHERE id = ?2`,
      )
        .bind(now, this.sessionId)
        .run();
    }

    for (const [key, pending] of this.pendingAcks.entries()) {
      clearTimeout(pending.timer);
      pending.reject(
        new Error("Host WebSocket closed during pending operation"),
      );
      this.pendingAcks.delete(key);
    }
  }

  /**
   * Processes messages incoming over the Host WebSocket.
   */
  private async handleIncomingMessage(data: unknown): Promise<void> {
    let parsedJson: unknown;
    try {
      const text =
        typeof data === "string"
          ? data
          : new TextDecoder().decode(data as ArrayBuffer);
      parsedJson = JSON.parse(text);
    } catch {
      this.sendError("Malformed JSON payload received");
      return;
    }

    let message: AgentProtocolMessage;
    try {
      message = parseAgentMessage(parsedJson);
    } catch (err) {
      this.sendError(
        err instanceof Error ? err.message : "Invalid host protocol message",
      );
      return;
    }

    const now = new Date().toISOString();

    if (message.type.startsWith("assignment.")) {
      const assignmentMessage = message as unknown as AssignmentCorrelation;
      const assignment = await this.env.CONCLAVE_DB.prepare(
        `SELECT id, workspace_id, host_id, worker_id, run_id, task_id,
                attempt_id, idempotency_key
         FROM worker_assignments WHERE id = ?1`,
      )
        .bind(assignmentMessage.assignmentId)
        .first<Record<string, unknown>>();
      if (
        !assignment ||
        !assignmentContextMatches(assignmentMessage, assignment)
      ) {
        this.sendError("Assignment correlation does not match persisted state");
        return;
      }
    }

    switch (message.type) {
      case "agent.hello": {
        const payload = message.payload as Record<string, unknown>;
        if (
          payload.agentId !== this.hostId ||
          !isWorkspaceAuthorized(
            this.authorizedWorkspaceIds,
            String(payload.workspaceId),
          )
        ) {
          this.sendError(
            "Host hello identity does not match the authenticated socket",
          );
          this.socket?.close(1008, "Host identity mismatch");
          return;
        }
        // Update host record with hostname, version and capabilities
        try {
          await this.env.CONCLAVE_DB.prepare(
            `UPDATE hosts SET hostname = ?1, version = ?2, capabilities_json = ?3, last_heartbeat_at = ?4, updated_at = ?4 WHERE id = ?5`,
          )
            .bind(
              payload.hostname,
              payload.agentVersion,
              JSON.stringify(payload.capabilities),
              now,
              this.hostId,
            )
            .run();
        } catch (err) {
          console.error("Failed to update host info on hello", err);
        }

        this.sendProtocolMessage({
          protocol: AGENT_PROTOCOL_NAME,
          protocolVersion: AGENT_PROTOCOL_VERSION,
          messageId: `msg-${Date.now()}`,
          correlationId: message.messageId,
          timestamp: now,
          type: "agent.hello.ack",
          payload: {
            sessionId: this.sessionId ?? `sess-${Date.now()}`,
            heartbeatIntervalMs: 15000,
            serverTime: now,
            serverVersion: "2.0.0",
            activeWorkspaceBindings: [...this.authorizedWorkspaceIds].sort(),
          },
        });
        break;
      }

      case "agent.heartbeat": {
        const payload = message.payload as Record<string, unknown>;
        if (
          payload.agentId !== this.hostId ||
          !isWorkspaceAuthorized(
            this.authorizedWorkspaceIds,
            String(payload.workspaceId),
          ) ||
          payload.sessionId !== this.sessionId
        ) {
          this.sendError(
            "Host heartbeat identity does not match the authenticated session",
          );
          this.socket?.close(1008, "Host session mismatch");
          return;
        }
        try {
          await this.env.CONCLAVE_DB.prepare(
            `UPDATE hosts SET status = ?1, last_heartbeat_at = ?2, updated_at = ?2 WHERE id = ?3`,
          )
            .bind(payload.status, now, this.hostId)
            .run();

          if (this.sessionId) {
            await this.env.CONCLAVE_DB.prepare(
              `UPDATE host_sessions SET last_heartbeat_at = ?1 WHERE id = ?2`,
            )
              .bind(now, this.sessionId)
              .run();
          }
        } catch (err) {
          console.error("Failed to update host heartbeat", err);
        }

        this.sendProtocolMessage({
          protocol: AGENT_PROTOCOL_NAME,
          protocolVersion: AGENT_PROTOCOL_VERSION,
          messageId: `msg-${Date.now()}`,
          correlationId: message.messageId,
          timestamp: now,
          type: "agent.heartbeat.ack",
          payload: {
            acknowledged: true,
            serverTime: now,
          },
        });
        break;
      }

      case "agent.sync.request": {
        const payload = message.payload as Record<string, unknown>;
        // Fetch desired workers from D1
        let desiredWorkers: DesiredWorker[] = [];
        let desiredPlugins: DesiredPlugin[] = [];
        let assignmentStates: Array<{
          assignmentId: string;
          attemptId: string;
          idempotencyKey: string;
          status: string;
        }> = [];

        try {
          const workerRows = await this.env.CONCLAVE_DB.prepare(
            `SELECT dw.worker_id, dw.required_version, w.display_name,
                    wv.protocol_version, wv.min_host_version,
                    wv.supported_os_json, wv.supported_arch_json,
                    wv.capabilities_json, wv.permissions_json,
                    wv.credential_requirements_json, wv.package_digest,
                    wv.package_r2_key, wv.signature, wv.entrypoint
             FROM host_desired_workers dw
             JOIN workers w ON w.id = dw.worker_id AND w.status = 'active'
             JOIN worker_versions wv
               ON wv.worker_id = dw.worker_id AND wv.version = dw.required_version
             WHERE dw.host_id = ?1 AND wv.is_revoked = 0
             ORDER BY dw.worker_id ASC`,
          )
            .bind(payload.agentId)
            .all<Record<string, unknown>>();

          desiredWorkers = (workerRows.results || []).map((row) => ({
            workerId: String(row.worker_id),
            version: String(row.required_version),
            publisher: "conclave",
            protocolVersion: String(row.protocol_version),
            minHostVersion: String(row.min_host_version),
            packageR2Key: String(row.package_r2_key),
            packageDigest: String(row.package_digest),
            signature: String(row.signature),
            entrypoint: String(row.entrypoint),
            permissions: JSON.parse(String(row.permissions_json || "[]")),
            supportedPlatforms: parseJsonArray(row.supported_os_json).flatMap(
              (os) =>
                parseJsonArray(row.supported_arch_json).map(
                  (arch) => `${os}-${arch}`,
                ),
            ),
            secretEnvironmentVariables: parseJsonObjectKeys(
              row.credential_requirements_json,
            ),
          }));
          // The v4 Worker package is the installable unit. Keep the legacy
          // plugin collection empty so a Host cannot accidentally reinstall
          // removed v3 plugin packages.
          desiredPlugins = [];

          const assignmentIds = Array.isArray(payload.unreconciledAssignmentIds)
            ? payload.unreconciledAssignmentIds.filter(
                (value): value is string => typeof value === "string",
              )
            : [];
          if (assignmentIds.length > 0) {
            const placeholders = assignmentIds
              .map((_: unknown, index: number) => `?${index + 2}`)
              .join(",");
            const assignmentRows = await this.env.CONCLAVE_DB.prepare(
              `SELECT id, attempt_id, idempotency_key, status
               FROM worker_assignments
               WHERE host_id = ?1 AND id IN (${placeholders})`,
            )
              .bind(payload.agentId, ...assignmentIds)
              .all<Record<string, unknown>>();
            assignmentStates = (assignmentRows.results ?? []).map((row) => ({
              assignmentId: String(row.id),
              attemptId: String(row.attempt_id),
              idempotencyKey: String(row.idempotency_key),
              status: String(row.status),
            }));
          }
        } catch (err) {
          console.error("Failed to query desired fleet config from D1", err);
        }

        this.sendProtocolMessage({
          protocol: AGENT_PROTOCOL_NAME,
          protocolVersion: AGENT_PROTOCOL_VERSION,
          messageId: `msg-${Date.now()}`,
          correlationId: message.messageId,
          timestamp: now,
          type: "host.sync.response",
          payload: {
            desiredPlugins,
            desiredWorkers,
            activeAssignmentIds: activeAssignmentIds(assignmentStates),
            assignmentStates,
          },
        });
        break;
      }

      case "worker.status": {
        const payload = message.payload as Record<string, unknown>;
        try {
          const statuses = Array.isArray(payload.workers)
            ? payload.workers
            : [payload];
          if (
            statuses.some(
              (status: Record<string, unknown>) =>
                status.hostId !== undefined && status.hostId !== this.hostId,
            )
          ) {
            this.sendError("Worker status identity does not match the session");
            break;
          }
          for (const status of statuses) {
            if (
              typeof status?.workerId !== "string" ||
              typeof status?.version !== "string" ||
              typeof status?.status !== "string"
            ) {
              continue;
            }
            const desired = await this.env.CONCLAVE_DB.prepare(
              `SELECT worker_id FROM host_desired_workers
               WHERE host_id = ?1 AND worker_id = ?2 AND required_version = ?3`,
            )
              .bind(this.hostId, status.workerId, status.version)
              .first<{ worker_id: string }>();
            if (!desired) continue;
            const installationStatus = [
              "active",
              "installed",
              "error",
            ].includes(status.status)
              ? status.status
              : "error";
            await this.env.CONCLAVE_DB.prepare(
              `INSERT INTO host_worker_installations
               (id, host_id, worker_id, worker_version_id, status, error,
                installed_at, updated_at)
               SELECT ?1, ?2, ?3, wv.id, ?4, ?5,
                      CASE WHEN ?4 IN ('active', 'installed') THEN COALESCE(?6, ?7) ELSE NULL END,
                      ?7
               FROM worker_versions wv
               WHERE wv.worker_id = ?3 AND wv.version = ?8
               ON CONFLICT(host_id, worker_id, worker_version_id) DO UPDATE SET
                 status = excluded.status,
                 error = excluded.error,
                 installed_at = COALESCE(excluded.installed_at, host_worker_installations.installed_at),
                 updated_at = excluded.updated_at`,
            )
              .bind(
                `installation-${this.hostId}-${status.workerId}-${status.version}`,
                this.hostId,
                status.workerId,
                installationStatus,
                typeof status.error === "string" ? status.error : null,
                typeof status.installedAt === "string"
                  ? status.installedAt
                  : null,
                now,
                status.version,
              )
              .run();
          }
        } catch (err) {
          console.error("Failed to update worker status", err);
        }
        break;
      }

      case "assignment.ack": {
        const pending = this.pendingAcks.get(message.assignmentId);
        if (pending) {
          clearTimeout(pending.timer);
          pending.resolve(message.payload);
          this.pendingAcks.delete(message.assignmentId);
        }

        try {
          const ackPayload = message.payload as unknown as {
            accepted?: boolean;
            status?: string;
          };
          const accepted =
            ackPayload.accepted ?? ackPayload.status === "accepted";
          const status = accepted ? "acknowledged" : "failed";
          await this.env.CONCLAVE_DB.prepare(
            `UPDATE worker_assignments SET status = ?1, updated_at = ?2 WHERE id = ?3`,
          )
            .bind(status, now, message.assignmentId)
            .run();
        } catch (err) {
          console.error("Failed to update assignment ack in D1", err);
        }
        break;
      }

      case "assignment.progress": {
        const payload = message.payload as Record<string, unknown>;
        try {
          await createEventPublisher(this.env).publish({
            type: "assignment.progress",
            durable: false,
            workspaceId: this.workspaceId ?? String(message.workspaceId),
            hostId: this.hostId ?? String(message.agentId),
            runId: String(message.runId),
            taskId: String(message.taskId),
            attemptId: String(message.attemptId),
            assignmentId: message.assignmentId,
            idempotencyKey: `assignment-progress:${message.messageId}`,
            payload: {
              entityId: message.assignmentId,
              workerId: String(message.workerId),
              percentage:
                typeof payload.percentage === "number" ? payload.percentage : 0,
              message:
                typeof payload.message === "string" ? payload.message : "",
              ...(typeof payload.metrics === "object" &&
              payload.metrics !== null &&
              !Array.isArray(payload.metrics)
                ? {
                    summary: JSON.stringify(payload.metrics).slice(0, 32768),
                  }
                : {}),
            },
          });
        } catch (err) {
          console.error("Failed to publish assignment.progress", err);
        }
        break;
      }

      case "assignment.result": {
        try {
          await recordAssignmentResult(
            this.env.CONCLAVE_DB,
            message.assignmentId,
            message.payload as unknown as AssignmentResultPayload,
          );
        } catch (err) {
          console.error("Failed to record assignment result in D1", err);
        }
        break;
      }

      case "assignment.error": {
        try {
          await recordAssignmentError(
            this.env.CONCLAVE_DB,
            message.assignmentId,
            message.payload as AssignmentFailurePayload,
          );
        } catch (err) {
          console.error("Failed to record assignment failure in D1", err);
        }
        break;
      }

      case "assignment.cancelled": {
        try {
          await recordAssignmentCancelled(
            this.env.CONCLAVE_DB,
            message.assignmentId,
            {
              status: "cancelled",
              reason: String(
                (message.payload as AssignmentCancelledPayload).reason ??
                  "Cancelled by Host",
              ),
            },
          );
        } catch (err) {
          console.error("Failed to record assignment cancellation in D1", err);
        }
        break;
      }

      case "assignment.cancel.ack": {
        const pending = this.pendingAcks.get(`cancel:${message.assignmentId}`);
        if (pending) {
          clearTimeout(pending.timer);
          pending.resolve(message.payload);
          this.pendingAcks.delete(`cancel:${message.assignmentId}`);
        }
        break;
      }

      default:
        break;
    }
  }

  /**
   * Internal DO RPC: Dispatches an assignment to the connected Host.
   */
  private async handleDispatchAssignment(request: Request): Promise<Response> {
    if (!this.socket) {
      return Response.json(
        { error: "Host is currently offline" },
        { status: 503 },
      );
    }

    const body = (await request.json()) as {
      workspaceId: string;
      hostId: string;
      workerId: string;
      runId: string;
      taskId: string;
      attemptId: string;
      assignmentId: string;
      idempotencyKey: string;
      payload: AssignmentStartPayload;
    };

    const validation = await this.validateInternalAssignment(body);
    if (validation) return validation;

    const envelope: Record<string, unknown> = {
      protocol: AGENT_PROTOCOL_NAME,
      protocolVersion: AGENT_PROTOCOL_VERSION,
      messageId: `msg-${Date.now()}`,
      timestamp: new Date().toISOString(),
      workspaceId: body.workspaceId,
      hostId: body.hostId,
      workerId: body.workerId,
      runId: body.runId,
      taskId: body.taskId,
      attemptId: body.attemptId,
      assignmentId: body.assignmentId,
      idempotencyKey: body.idempotencyKey,
      type: "assignment.start",
      payload: body.payload,
    };

    // Await ack from host
    const ackPromise = new Promise<{ accepted: boolean; reason?: string }>(
      (resolve, reject) => {
        const timer = setTimeout(() => {
          this.pendingAcks.delete(body.assignmentId);
          reject(
            new Error("Timeout waiting for host assignment acknowledgment"),
          );
        }, 10000);

        this.pendingAcks.set(body.assignmentId, {
          resolve: resolve as (value: unknown) => void,
          reject,
          timer,
        });
      },
    );

    this.sendProtocolMessage(envelope);

    try {
      const ack = await ackPromise;
      return Response.json(ack);
    } catch (err) {
      return Response.json(
        { error: err instanceof Error ? err.message : String(err) },
        { status: 504 },
      );
    }
  }

  /**
   * Internal DO RPC: Cancels a running assignment on the Host.
   */
  private async handleCancelAssignment(request: Request): Promise<Response> {
    if (!this.socket) {
      return Response.json(
        { error: "Host is currently offline" },
        { status: 503 },
      );
    }

    const body = (await request.json()) as {
      workspaceId: string;
      hostId: string;
      workerId: string;
      runId: string;
      taskId: string;
      attemptId: string;
      assignmentId: string;
      idempotencyKey: string;
      payload: AssignmentCancelPayload;
    };

    const validation = await this.validateInternalAssignment(body);
    if (validation) return validation;

    const envelope: Record<string, unknown> = {
      protocol: AGENT_PROTOCOL_NAME,
      protocolVersion: AGENT_PROTOCOL_VERSION,
      messageId: `msg-${Date.now()}`,
      timestamp: new Date().toISOString(),
      workspaceId: body.workspaceId,
      hostId: body.hostId,
      workerId: body.workerId,
      runId: body.runId,
      taskId: body.taskId,
      attemptId: body.attemptId,
      assignmentId: body.assignmentId,
      idempotencyKey: body.idempotencyKey,
      type: "assignment.cancel",
      payload: body.payload,
    };

    const cancelKey = `cancel:${body.assignmentId}`;
    const ackPromise = new Promise<{ cancelled: boolean }>(
      (resolve, reject) => {
        const timer = setTimeout(() => {
          this.pendingAcks.delete(cancelKey);
          reject(new Error("Timeout waiting for host cancel acknowledgment"));
        }, 10000);

        this.pendingAcks.set(cancelKey, {
          resolve: resolve as (value: unknown) => void,
          reject,
          timer,
        });
      },
    );

    this.sendProtocolMessage(envelope);

    try {
      const ack = await ackPromise;
      return Response.json(ack);
    } catch (err) {
      return Response.json(
        { error: err instanceof Error ? err.message : String(err) },
        { status: 504 },
      );
    }
  }

  /**
   * Internal DO RPC: Sends an arbitrary protocol envelope.
   */
  private async handlePostMessage(request: Request): Promise<Response> {
    if (!this.socket) {
      return Response.json(
        { error: "Host is currently offline" },
        { status: 503 },
      );
    }

    const body = (await request.json()) as AgentProtocolMessage;
    const valid = parseAgentMessage(body);
    this.sendProtocolMessage(valid);
    return Response.json({ delivered: true });
  }

  private async validateInternalAssignment(
    body: AssignmentCorrelation,
  ): Promise<Response | null> {
    const assignment = await this.env.CONCLAVE_DB.prepare(
      `SELECT id, workspace_id, host_id, worker_id, run_id, task_id,
              attempt_id, idempotency_key, status
       FROM worker_assignments WHERE id = ?1`,
    )
      .bind(body.assignmentId)
      .first<Record<string, unknown>>();

    if (!assignment || !assignmentContextMatches(body, assignment)) {
      return Response.json(
        { error: "Assignment correlation does not match persisted state" },
        { status: 409 },
      );
    }

    if (!assignmentIsActive(assignment)) {
      return Response.json(
        { error: "Assignment is already terminal" },
        { status: 409 },
      );
    }

    return null;
  }

  private sendProtocolMessage(message: unknown): void {
    if (!this.socket) return;
    try {
      const serialized = serializeAgentMessage(message as AgentProtocolMessage);
      this.socket.send(serialized);
    } catch (err) {
      console.error("Failed to send protocol message over WebSocket", err);
    }
  }

  private sendError(error: string): void {
    if (!this.socket) return;
    try {
      this.socket.send(JSON.stringify({ error }));
    } catch {
      // ignore
    }
  }
}
