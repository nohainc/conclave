import {
  AGENT_PROTOCOL_NAME,
  AGENT_PROTOCOL_VERSION,
  parseAgentMessage,
  serializeAgentMessage,
  type AgentProtocolMessage,
  type AgentHelloPayload,
  type AgentHeartbeatPayload,
  type AgentSyncRequestPayload,
  type DesiredWorker,
  type DesiredPlugin,
  type AssignmentStartPayload,
  type AssignmentCancelPayload,
  type AssignmentResultPayload,
  type AssignmentFailurePayload,
  type AssignmentCancelledPayload,
} from "@conclave/agent-protocol";
import {
  recordAssignmentResult,
  recordAssignmentError,
  recordAssignmentCancelled,
} from "./assignment-dispatcher.js";
import {
  extractAuthToken,
  hashToken,
} from "../../../packages/security/src/index.js";

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
}

export interface AssignmentCorrelation {
  workspaceId: string;
  agentId: string;
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
    message.agentId === String(row.agent_id) &&
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

export class AgentGateway implements DurableObject {
  private socket: WebSocket | null = null;
  private agentId: string | null = null;
  private workspaceId: string | null = null;
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

    // 1. WebSocket Upgrade from Agent
    if (request.headers.get("Upgrade")?.toLowerCase() === "websocket") {
      return this.handleWebSocketConnect(request, url);
    }

    // 2. Internal DO RPC: Query live status
    if (request.method === "GET" && url.pathname === "/status") {
      return Response.json({
        online: this.socket !== null,
        agentId: this.agentId,
        workspaceId: this.workspaceId,
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
   * Handles incoming WebSocket connection upgrade from an enrolled Conclave Agent.
   */
  private async handleWebSocketConnect(
    request: Request,
    url: URL,
  ): Promise<Response> {
    const agentId = url.searchParams.get("agentId");
    const workspaceId = url.searchParams.get("workspaceId");

    if (!agentId || !workspaceId) {
      return Response.json(
        { error: "agentId and workspaceId query parameters are required" },
        { status: 400 },
      );
    }

    const token = extractAuthToken(request.headers);
    if (!token) {
      return Response.json(
        { error: "Agent authentication required" },
        { status: 401 },
      );
    }
    const tokenHash = await hashToken(token);
    const enrolledAgent = await this.env.CONCLAVE_DB.prepare(
      `SELECT id, workspace_id FROM agents
       WHERE id = ?1 AND workspace_id = ?2 AND auth_token_hash = ?3 AND revoked_at IS NULL`,
    )
      .bind(agentId, workspaceId, tokenHash)
      .first<{ id: string; workspace_id: string }>();
    if (!enrolledAgent) {
      return Response.json(
        { error: "Invalid or revoked Agent credential" },
        { status: 401 },
      );
    }

    // Close any previous stale socket for this agent instance
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
    this.agentId = agentId;
    this.workspaceId = workspaceId;
    this.sessionId = `sess-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;

    const now = new Date().toISOString();

    // Update D1 database
    try {
      await this.env.CONCLAVE_DB.prepare(
        `UPDATE agents SET status = 'online', last_heartbeat_at = ?1, updated_at = ?1 WHERE id = ?2`,
      )
        .bind(now, agentId)
        .run();

      await this.env.CONCLAVE_DB.prepare(
        `INSERT INTO agent_sessions (id, agent_id, workspace_id, client_version, protocol_version, ip_address, connected_at, last_heartbeat_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)`,
      )
        .bind(
          this.sessionId,
          agentId,
          workspaceId,
          "0.2.0",
          AGENT_PROTOCOL_VERSION,
          request.headers.get("CF-Connecting-IP") || "127.0.0.1",
          now,
        )
        .run();
    } catch (err) {
      console.error("Failed to record agent session in D1", err);
    }

    server.addEventListener("message", (event) => {
      void this.handleIncomingMessage(event.data);
    });

    const connectedSessionId = this.sessionId;
    server.addEventListener("close", () => {
      this.handleSocketClose(server, connectedSessionId);
    });

    server.addEventListener("error", (err) => {
      console.error("Agent Gateway WebSocket error", err);
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
    // installed. It must not tear down the current session or mark the Agent
    // offline in D1.
    if (!isCurrentSocketSession(this.socket, this.sessionId, socket, sessionId))
      return;
    if (!this.socket) return;
    this.socket = null;
    const now = new Date().toISOString();

    if (this.agentId && this.sessionId) {
      void this.env.CONCLAVE_DB.prepare(
        `UPDATE agents SET status = 'offline', updated_at = ?1 WHERE id = ?2`,
      )
        .bind(now, this.agentId)
        .run();

      void this.env.CONCLAVE_DB.prepare(
        `UPDATE agent_sessions SET disconnected_at = ?1 WHERE id = ?2`,
      )
        .bind(now, this.sessionId)
        .run();
    }

    for (const [key, pending] of this.pendingAcks.entries()) {
      clearTimeout(pending.timer);
      pending.reject(
        new Error("Agent WebSocket closed during pending operation"),
      );
      this.pendingAcks.delete(key);
    }
  }

  /**
   * Processes messages incoming over the Agent WebSocket.
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
        err instanceof Error ? err.message : "Invalid agent protocol message",
      );
      return;
    }

    const now = new Date().toISOString();

    if (message.type.startsWith("assignment.")) {
      const assignmentMessage = message as unknown as AssignmentCorrelation;
      const assignment = await this.env.CONCLAVE_DB.prepare(
        `SELECT id, workspace_id, agent_id, worker_id, run_id, task_id,
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
        const payload = message.payload as AgentHelloPayload;
        if (
          payload.agentId !== this.agentId ||
          payload.workspaceId !== this.workspaceId
        ) {
          this.sendError(
            "Agent hello identity does not match the authenticated socket",
          );
          this.socket?.close(1008, "Agent identity mismatch");
          return;
        }
        // Update agent record with hostname, version and capabilities
        try {
          await this.env.CONCLAVE_DB.prepare(
            `UPDATE agents SET hostname = ?1, version = ?2, capabilities_json = ?3, last_heartbeat_at = ?4, updated_at = ?4 WHERE id = ?5`,
          )
            .bind(
              payload.hostname,
              payload.agentVersion,
              JSON.stringify(payload.capabilities),
              now,
              this.agentId,
            )
            .run();
        } catch (err) {
          console.error("Failed to update agent info on hello", err);
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
          },
        });
        break;
      }

      case "agent.heartbeat": {
        const payload = message.payload as AgentHeartbeatPayload;
        if (
          payload.agentId !== this.agentId ||
          payload.workspaceId !== this.workspaceId ||
          payload.sessionId !== this.sessionId
        ) {
          this.sendError(
            "Agent heartbeat identity does not match the authenticated session",
          );
          this.socket?.close(1008, "Agent session mismatch");
          return;
        }
        try {
          await this.env.CONCLAVE_DB.prepare(
            `UPDATE agents SET status = ?1, last_heartbeat_at = ?2, updated_at = ?2 WHERE id = ?3`,
          )
            .bind(payload.status, now, this.agentId)
            .run();

          if (this.sessionId) {
            await this.env.CONCLAVE_DB.prepare(
              `UPDATE agent_sessions SET last_heartbeat_at = ?1 WHERE id = ?2`,
            )
              .bind(now, this.sessionId)
              .run();
          }
        } catch (err) {
          console.error("Failed to update agent heartbeat", err);
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
        const payload = message.payload as AgentSyncRequestPayload;
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
            `SELECT * FROM workers
             WHERE agent_id = ?1 AND workspace_id = ?2 AND enabled = 1`,
          )
            .bind(payload.agentId, payload.workspaceId)
            .all<Record<string, unknown>>();

          desiredWorkers = (workerRows.results || []).map((row) => ({
            id: String(row.id),
            workerId: String(row.id),
            workspaceId: String(row.workspace_id || payload.workspaceId),
            agentId: String(row.agent_id || payload.agentId),
            pluginId: String(row.plugin_id),
            pluginVersionPolicy: String(row.plugin_version_policy || "latest"),
            name: String(row.name),
            roles: JSON.parse(String(row.roles_json || "[]")),
            capabilities: JSON.parse(String(row.capabilities_json || "[]")),
            config: JSON.parse(String(row.config_json || "{}")),
            secretRefs: JSON.parse(String(row.secret_refs_json || "[]")),
            billingMode: row.billing_mode as DesiredWorker["billingMode"],
            costMetadata: JSON.parse(String(row.cost_metadata_json || "{}")),
            independenceKey: String(row.independence_key),
            concurrencyLimit: Number(row.concurrency_limit || 1),
            sessionPolicy:
              (row.session_policy as DesiredWorker["sessionPolicy"]) ||
              "stateless",
            availability:
              (row.status as DesiredWorker["availability"]) || "available",
            enabled: Number(row.enabled) === 1,
          }));

          const pluginRows = await this.env.CONCLAVE_DB.prepare(
            `SELECT pv.*, p.id as plugin_id, p.publisher as publisher FROM worker_plugin_versions pv
             JOIN worker_plugins p ON p.id = pv.plugin_id
             JOIN workers w ON w.plugin_id = p.id
             WHERE p.status = 'active'
               AND w.agent_id = ?1 AND w.workspace_id = ?2 AND w.enabled = 1
             GROUP BY pv.id`,
          )
            .bind(payload.agentId, payload.workspaceId)
            .all<Record<string, unknown>>();

          desiredPlugins = (pluginRows.results || []).map((row) => ({
            pluginId: String(row.plugin_id),
            version: String(row.version),
            publisher: String(row.publisher),
            protocolVersion: String(row.protocol_version),
            minAgentVersion: String(row.min_agent_version),
            supportedPlatforms: [
              ...parseJsonArray(row.supported_os_json),
            ].flatMap((os) =>
              parseJsonArray(row.supported_arch_json).map(
                (arch) => `${os}-${arch}`,
              ),
            ),
            packageR2Key: String(row.package_r2_key),
            packageDigest: String(row.package_digest),
            signature: String(row.signature),
            permissions: JSON.parse(String(row.permissions_json || "[]")),
            secretEnvironmentVariables: parseJsonObjectKeys(
              row.secret_schema_json,
            ),
          }));

          const assignmentIds = payload.unreconciledAssignmentIds ?? [];
          if (assignmentIds.length > 0) {
            const placeholders = assignmentIds
              .map((_, index) => `?${index + 3}`)
              .join(",");
            const assignmentRows = await this.env.CONCLAVE_DB.prepare(
              `SELECT id, attempt_id, idempotency_key, status
               FROM worker_assignments
               WHERE agent_id = ?1 AND workspace_id = ?2 AND id IN (${placeholders})`,
            )
              .bind(payload.agentId, payload.workspaceId, ...assignmentIds)
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
          type: "agent.sync.response",
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
        const payload = message.payload as {
          workerId: string;
          agentId: string;
          status: string;
        };
        try {
          if (payload.agentId !== this.agentId) {
            this.sendError("Worker status identity does not match the session");
            break;
          }
          await this.env.CONCLAVE_DB.prepare(
            `UPDATE workers SET status = ?1, updated_at = ?2
             WHERE id = ?3 AND agent_id = ?4 AND workspace_id = ?5`,
          )
            .bind(
              payload.status,
              now,
              payload.workerId,
              this.agentId,
              this.workspaceId,
            )
            .run();
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
          const accepted = (message.payload as { accepted: boolean }).accepted;
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
        // Can be routed to persistent event logs or websocket subscribers
        break;
      }

      case "assignment.result": {
        try {
          await recordAssignmentResult(
            this.env.CONCLAVE_DB,
            message.assignmentId,
            message.payload as AssignmentResultPayload,
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
            message.payload as AssignmentCancelledPayload,
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
   * Internal DO RPC: Dispatches an assignment to the connected Agent.
   */
  private async handleDispatchAssignment(request: Request): Promise<Response> {
    if (!this.socket) {
      return Response.json(
        { error: "Agent is currently offline" },
        { status: 503 },
      );
    }

    const body = (await request.json()) as {
      workspaceId: string;
      agentId: string;
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

    const envelope: AgentProtocolMessage = {
      protocol: AGENT_PROTOCOL_NAME,
      protocolVersion: AGENT_PROTOCOL_VERSION,
      messageId: `msg-${Date.now()}`,
      timestamp: new Date().toISOString(),
      workspaceId: body.workspaceId,
      agentId: body.agentId,
      workerId: body.workerId,
      runId: body.runId,
      taskId: body.taskId,
      attemptId: body.attemptId,
      assignmentId: body.assignmentId,
      idempotencyKey: body.idempotencyKey,
      type: "assignment.start",
      payload: body.payload,
    };

    // Await ack from agent
    const ackPromise = new Promise<{ accepted: boolean; reason?: string }>(
      (resolve, reject) => {
        const timer = setTimeout(() => {
          this.pendingAcks.delete(body.assignmentId);
          reject(
            new Error("Timeout waiting for agent assignment acknowledgment"),
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
   * Internal DO RPC: Cancels a running assignment on the Agent.
   */
  private async handleCancelAssignment(request: Request): Promise<Response> {
    if (!this.socket) {
      return Response.json(
        { error: "Agent is currently offline" },
        { status: 503 },
      );
    }

    const body = (await request.json()) as {
      workspaceId: string;
      agentId: string;
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

    const envelope: AgentProtocolMessage = {
      protocol: AGENT_PROTOCOL_NAME,
      protocolVersion: AGENT_PROTOCOL_VERSION,
      messageId: `msg-${Date.now()}`,
      timestamp: new Date().toISOString(),
      workspaceId: body.workspaceId,
      agentId: body.agentId,
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
          reject(new Error("Timeout waiting for agent cancel acknowledgment"));
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
        { error: "Agent is currently offline" },
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
      `SELECT id, workspace_id, agent_id, worker_id, run_id, task_id,
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

  private sendProtocolMessage(message: AgentProtocolMessage): void {
    if (!this.socket) return;
    try {
      const serialized = serializeAgentMessage(message);
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
