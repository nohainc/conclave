import {
  isDurableRealtimeEventType,
  parseRealtimeEvent,
  type RealtimeEventEnvelope,
} from "@conclave/protocol";
import {
  identityService,
  type AuthenticatedIdentity,
  type BetterAuthRuntimeEnv,
} from "./auth/index.js";
import {
  BoundedRealtimeQueue,
  type RealtimeQueueEnqueueResult,
} from "./realtime-queue.js";

export interface RealtimeScope {
  workspaceId: string;
  projectId?: string;
  chatId?: string;
  runId?: string;
}

export type RealtimeClientMessage =
  | { type: "realtime.hello"; lastDurableSequence?: number }
  | { type: "subscribe"; scope: RealtimeScope }
  | { type: "unsubscribe"; scope: RealtimeScope }
  | { type: "ping" };

export interface RealtimeGatewayEnv extends BetterAuthRuntimeEnv {
  readonly CONCLAVE_DB: D1Database;
}

interface ConnectedClient {
  readonly socket: WebSocket;
  readonly identity: AuthenticatedIdentity;
  readonly subscriptions: Map<string, RealtimeScope>;
  lastDurableSequence: number | null;
  readonly queue: BoundedRealtimeQueue;
  flushScheduled: boolean;
}

export interface RealtimeGatewayMetrics {
  activeAppSockets: number;
  publishedEvents: number;
  ephemeralDropped: number;
  ephemeralCoalesced: number;
  reconnects: number;
  durableResyncs: number;
  maxQueueDepth: number;
  eventToUiLatencyMs: number;
}

const MAX_SOCKET_BUFFERED_BYTES = 256 * 1024;

const scopeFields = ["workspaceId", "projectId", "chatId", "runId"] as const;

export function scopeKey(scope: RealtimeScope): string {
  return scopeFields.map((field) => `${field}=${scope[field] ?? ""}`).join("&");
}

export function parseRealtimeClientMessage(
  input: unknown,
): RealtimeClientMessage {
  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    throw new Error("Realtime client message must be an object");
  }
  const value = input as Record<string, unknown>;
  if (typeof value.type !== "string") {
    throw new Error("Realtime client message type is required");
  }
  if (value.type === "realtime.hello" || value.type === "ping") {
    if (value.type === "ping") return { type: "ping" };
    const sequence = value.lastDurableSequence;
    if (
      sequence !== undefined &&
      (typeof sequence !== "number" ||
        !Number.isInteger(sequence) ||
        sequence < 0)
    ) {
      throw new Error("lastDurableSequence must be a non-negative integer");
    }
    return {
      type: "realtime.hello",
      ...(sequence === undefined || typeof sequence !== "number"
        ? {}
        : { lastDurableSequence: sequence }),
    };
  }
  if (value.type !== "subscribe" && value.type !== "unsubscribe") {
    throw new Error(`Unsupported realtime client message: ${value.type}`);
  }
  const rawScope = value.scope;
  if (
    rawScope === null ||
    typeof rawScope !== "object" ||
    Array.isArray(rawScope)
  ) {
    throw new Error("Realtime subscription scope is required");
  }
  const scope = rawScope as Record<string, unknown>;
  if (typeof scope.workspaceId !== "string" || scope.workspaceId.length === 0) {
    throw new Error("Realtime subscription workspaceId is required");
  }
  for (const field of scopeFields.slice(1)) {
    if (scope[field] !== undefined && typeof scope[field] !== "string") {
      throw new Error(`Realtime subscription ${field} must be a string`);
    }
  }
  return {
    type: value.type,
    scope: {
      workspaceId: scope.workspaceId,
      ...(typeof scope.projectId === "string"
        ? { projectId: scope.projectId }
        : {}),
      ...(typeof scope.chatId === "string" ? { chatId: scope.chatId } : {}),
      ...(typeof scope.runId === "string" ? { runId: scope.runId } : {}),
    },
  };
}

export function reconnectDelayMs(
  attempt: number,
  random = Math.random(),
): number {
  const boundedAttempt = Math.max(0, Math.min(Math.floor(attempt), 8));
  const base = Math.min(30_000, 500 * 2 ** boundedAttempt);
  return Math.floor(base * (0.75 + Math.max(0, Math.min(1, random)) * 0.5));
}

export function realtimeAuthenticationError(
  identity: AuthenticatedIdentity | null,
  userStatus?: string | null,
): string | null {
  if (!identity) return "Authentication required";
  if (userStatus && userStatus !== "active") return "User account is suspended";
  return null;
}

export function eventMatchesScope(
  event: RealtimeEventEnvelope,
  scope: RealtimeScope,
): boolean {
  return (
    event.workspaceId === scope.workspaceId &&
    (!scope.projectId || event.projectId === scope.projectId) &&
    (!scope.chatId || event.chatId === scope.chatId) &&
    (!scope.runId || event.runId === scope.runId)
  );
}

export function requiresRealtimeReconnect(
  lastDurableSequence: number | null,
  nextDurableSequence: number,
): boolean {
  return (
    lastDurableSequence !== null &&
    nextDurableSequence > lastDurableSequence + 1
  );
}

export async function authorizeRealtimeScope(
  db: Pick<D1Database, "prepare">,
  userId: string,
  scope: RealtimeScope,
): Promise<{ allowed: true } | { allowed: false; reason: string }> {
  const membership = await db
    .prepare(
      "SELECT 1 AS member FROM workspace_memberships WHERE workspace_id = ?1 AND user_id = ?2 AND status = 'active'",
    )
    .bind(scope.workspaceId, userId)
    .first<{ member: number }>();
  if (!membership) return { allowed: false, reason: "workspace_access_denied" };

  if (scope.projectId) {
    const project = await db
      .prepare("SELECT workspace_id FROM projects WHERE id = ?1")
      .bind(scope.projectId)
      .first<{ workspace_id: string }>();
    if (!project || project.workspace_id !== scope.workspaceId) {
      return { allowed: false, reason: "project_access_denied" };
    }
  }
  if (scope.chatId) {
    const chat = await db
      .prepare("SELECT project_id FROM chats WHERE id = ?1")
      .bind(scope.chatId)
      .first<{ project_id: string }>();
    if (!chat) return { allowed: false, reason: "chat_access_denied" };
    const project = await db
      .prepare("SELECT workspace_id FROM projects WHERE id = ?1")
      .bind(chat.project_id)
      .first<{ workspace_id: string }>();
    if (!project || project.workspace_id !== scope.workspaceId) {
      return { allowed: false, reason: "chat_access_denied" };
    }
  }
  if (scope.runId) {
    const run = await db
      .prepare("SELECT workspace_id FROM runs WHERE id = ?1")
      .bind(scope.runId)
      .first<{ workspace_id: string }>();
    if (!run || run.workspace_id !== scope.workspaceId) {
      return { allowed: false, reason: "run_access_denied" };
    }
  }
  return { allowed: true };
}

export class RealtimeGateway implements DurableObject {
  private readonly clients = new Map<string, ConnectedClient>();
  private readonly metrics: RealtimeGatewayMetrics = {
    activeAppSockets: 0,
    publishedEvents: 0,
    ephemeralDropped: 0,
    ephemeralCoalesced: 0,
    reconnects: 0,
    durableResyncs: 0,
    maxQueueDepth: 0,
    eventToUiLatencyMs: 0,
  };

  constructor(
    private readonly state: DurableObjectState,
    private readonly env: RealtimeGatewayEnv,
  ) {
    void state;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/publish") {
      return this.publish(request);
    }
    if (request.method === "GET" && url.pathname === "/metrics") {
      return Response.json({
        ...this.metrics,
        activeAppSockets: this.clients.size,
        queueDepth: [...this.clients.values()].reduce(
          (total, client) => total + client.queue.depth,
          0,
        ),
      });
    }
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return Response.json(
        { error: "Expected WebSocket upgrade" },
        { status: 426 },
      );
    }

    const identity = await identityService.resolve(request, this.env);
    if (!identity) {
      return Response.json(
        { error: "Authentication required" },
        { status: 401 },
      );
    }
    const user = await this.env.CONCLAVE_DB.prepare(
      "SELECT status FROM users WHERE id = ?1",
    )
      .bind(identity.userId)
      .first<{ status?: string | null }>();
    const accountError = realtimeAuthenticationError(identity, user?.status);
    if (accountError) {
      return Response.json({ error: accountError }, { status: 403 });
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    const connectionId = crypto.randomUUID();
    const connected: ConnectedClient = {
      socket: server,
      identity,
      subscriptions: new Map(),
      lastDurableSequence: null,
      queue: new BoundedRealtimeQueue(),
      flushScheduled: false,
    };
    this.clients.set(connectionId, connected);
    this.metrics.activeAppSockets = this.clients.size;
    server.accept();
    this.sendRaw(server, {
      type: "realtime.ready",
      connectionId,
      eventVersion: "1.0",
    });
    server.addEventListener("message", (event) => {
      void this.handleClientMessage(connectionId, event.data);
    });
    const remove = () => {
      this.clients.delete(connectionId);
      this.metrics.activeAppSockets = this.clients.size;
    };
    server.addEventListener("close", remove);
    server.addEventListener("error", remove);
    return new Response(null, { status: 101, webSocket: client });
  }

  private async handleClientMessage(
    connectionId: string,
    data: unknown,
  ): Promise<void> {
    const connected = this.clients.get(connectionId);
    if (!connected) return;
    try {
      const input = JSON.parse(
        typeof data === "string"
          ? data
          : new TextDecoder().decode(data as ArrayBuffer),
      );
      const message = parseRealtimeClientMessage(input);
      if (message.type === "ping") {
        this.sendRaw(connected.socket, { type: "realtime.pong" });
        return;
      }
      if (message.type === "realtime.hello") {
        connected.lastDurableSequence = message.lastDurableSequence ?? null;
        this.sendRaw(connected.socket, {
          type: "realtime.ready",
          connectionId,
          eventVersion: "1.0",
          ...(connected.lastDurableSequence === null
            ? {}
            : { lastDurableSequence: connected.lastDurableSequence }),
        });
        return;
      }
      const result = await authorizeRealtimeScope(
        this.env.CONCLAVE_DB,
        connected.identity.userId,
        message.scope,
      );
      if (!result.allowed) {
        this.sendRaw(connected.socket, {
          type: "subscription.denied",
          scope: message.scope,
          reason: result.reason,
        });
        return;
      }
      const key = scopeKey(message.scope);
      if (message.type === "subscribe") {
        connected.subscriptions.set(key, message.scope);
        this.sendRaw(connected.socket, {
          type: "subscription.confirmed",
          scope: message.scope,
        });
      } else {
        connected.subscriptions.delete(key);
        this.sendRaw(connected.socket, {
          type: "subscription.confirmed",
          scope: message.scope,
          subscribed: false,
        });
      }
    } catch (error) {
      this.sendRaw(connected.socket, {
        type: "subscription.denied",
        reason:
          error instanceof Error ? error.message : "Malformed realtime message",
      });
    }
  }

  private async publish(request: Request): Promise<Response> {
    try {
      const event = parseRealtimeEvent(await request.json());
      this.metrics.publishedEvents += 1;
      for (const connected of this.clients.values()) {
        const matches = [...connected.subscriptions.values()].some((scope) =>
          eventMatchesScope(event, scope),
        );
        if (!matches) continue;
        if (
          isDurableRealtimeEventType(event.type) &&
          requiresRealtimeReconnect(
            connected.lastDurableSequence,
            event.sequence,
          )
        ) {
          this.metrics.reconnects += 1;
          this.sendRaw(connected.socket, {
            type: "reconnect.required",
            reason: "durable_event_gap",
            lastDurableSequence: connected.lastDurableSequence,
            nextSequence: event.sequence,
          });
          continue;
        }
        const result = this.enqueueEvent(connected, event);
        this.recordQueueResult(result);
        if (isDurableRealtimeEventType(event.type)) {
          connected.lastDurableSequence = event.sequence;
        }
      }
      return Response.json({ delivered: true });
    } catch (error) {
      return Response.json(
        {
          error:
            error instanceof Error ? error.message : "Invalid realtime event",
        },
        { status: 400 },
      );
    }
  }

  private enqueueEvent(
    connected: ConnectedClient,
    event: RealtimeEventEnvelope,
  ): RealtimeQueueEnqueueResult {
    const durable = isDurableRealtimeEventType(event.type);
    const coalesceKey = durable
      ? undefined
      : `${event.type}:${event.workspaceId}:${event.projectId ?? ""}:${event.runId ?? ""}:${event.assignmentId ?? ""}`;
    const frame = JSON.stringify({ type: "event", event });
    if (
      connected.queue.depth === 0 &&
      (connected.socket as WebSocket & { bufferedAmount?: number })
        .bufferedAmount !== undefined &&
      Number(
        (connected.socket as WebSocket & { bufferedAmount?: number })
          .bufferedAmount,
      ) < MAX_SOCKET_BUFFERED_BYTES
    ) {
      this.sendRaw(connected.socket, { type: "event", event });
      this.recordLatency(event);
      return "queued";
    }
    const result = connected.queue.enqueue({ frame, durable, coalesceKey });
    this.metrics.maxQueueDepth = Math.max(
      this.metrics.maxQueueDepth,
      connected.queue.depth,
    );
    if (result === "resync-required") {
      this.metrics.durableResyncs += 1;
      connected.queue.clear();
      this.sendRaw(connected.socket, {
        type: "reconnect.required",
        reason: "connection_queue_limit",
        nextSequence: event.sequence,
      });
      return result;
    }
    this.scheduleFlush(connected);
    return result;
  }

  private scheduleFlush(connected: ConnectedClient): void {
    if (connected.flushScheduled || connected.queue.depth === 0) return;
    connected.flushScheduled = true;
    setTimeout(() => {
      connected.flushScheduled = false;
      this.flush(connected);
    }, 25);
  }

  private flush(connected: ConnectedClient): void {
    if (connected.socket.readyState !== WebSocket.OPEN) return;
    const socket = connected.socket as WebSocket & { bufferedAmount?: number };
    if (Number(socket.bufferedAmount ?? 0) >= MAX_SOCKET_BUFFERED_BYTES) {
      this.scheduleFlush(connected);
      return;
    }
    let item: ReturnType<BoundedRealtimeQueue["take"]>;
    while ((item = connected.queue.take())) {
      this.sendSerialized(connected.socket, item.frame);
      if (Number(socket.bufferedAmount ?? 0) >= MAX_SOCKET_BUFFERED_BYTES) {
        break;
      }
    }
    if (connected.queue.depth > 0) this.scheduleFlush(connected);
  }

  private recordQueueResult(result: RealtimeQueueEnqueueResult): void {
    if (result === "dropped") this.metrics.ephemeralDropped += 1;
    if (result === "coalesced") this.metrics.ephemeralCoalesced += 1;
  }

  private recordLatency(event: RealtimeEventEnvelope): void {
    const timestamp = Date.parse(event.timestamp);
    if (!Number.isNaN(timestamp)) {
      this.metrics.eventToUiLatencyMs = Math.max(0, Date.now() - timestamp);
    }
  }

  private sendRaw(socket: WebSocket, message: unknown): void {
    this.sendSerialized(socket, JSON.stringify(message));
  }

  private sendSerialized(socket: WebSocket, serialized: string): void {
    try {
      socket.send(serialized);
    } catch {
      // Close handlers remove dead sockets; delivery is best effort.
    }
  }
}
