import {
  parseWorkspaceRuntimeMessage,
  serializeWorkspaceRuntimeMessage,
  WORKSPACE_RUNTIME_PROTOCOL_NAME,
  WORKSPACE_RUNTIME_PROTOCOL_VERSION,
  type WorkspaceRuntimeMessage,
} from "@conclave/workspace-runtime-protocol";
import {
  RealtimeEventPayloadSchema,
  normalizeActivityPayload,
} from "@conclave/protocol";
import { createEventPublisher } from "./event-publisher.js";
import { assignmentCommandDisposition } from "./assignment-delivery.js";
import { shouldPersistWorkerActivity } from "./worker-activity-history.js";
import {
  recordAssignmentCancelled,
  recordAssignmentError,
  recordAssignmentResult,
} from "./assignment-dispatcher.js";
import { extractBearerToken } from "../../../packages/security/src/index.js";
import {
  tryLogDiagnosticEvent,
  logStructured,
  requestIdFor,
} from "./observability.js";
import { recordWorkspaceWorkerInventory } from "./workspace-gateway/inventory.js";
import { WorkspaceRuntimeAuthenticator } from "./workspace-gateway/runtime-authenticator.js";
import { WorkspaceRuntimeSessionStore } from "./workspace-gateway/session-store.js";

import {
  isCurrentWorkspaceSocket,
  runtimeFacts,
  workspaceAssignmentContextMatches,
  workspaceAssignmentIsActive,
  type WorkspaceAssignmentCorrelation,
  type WorkspaceGatewayEnv,
} from "./workspace-gateway/contracts.js";

/**
 * Bound the fallback transport's pending server-to-Workspace messages. The
 * queue is persisted, so a dropped poll response can still be replayed, but
 * accepting unbounded commands would turn a disconnected runtime into a D1 /
 * Durable Object memory sink. Reaching this limit applies backpressure to
 * the caller; it never silently drops a command or acknowledgement.
 */
export const MAX_WORKSPACE_HTTP_EVENTS = 256;
export {
  isCurrentWorkspaceSocket,
  isWorkspaceRuntimeAuthorized,
  normalizeWorkspaceWorkerInstallationStatus,
  workspaceAssignmentContextMatches,
  workspaceAssignmentIsActive,
  type WorkspaceAssignmentCorrelation,
  type WorkspaceGatewayEnv,
} from "./workspace-gateway/contracts.js";

export class WorkspaceGateway implements DurableObject {
  private readonly runtimeAuthenticator: WorkspaceRuntimeAuthenticator;
  private readonly sessionStore: WorkspaceRuntimeSessionStore;
  private readonly pendingCancelAcks = new Map<
    string,
    {
      resolve: (payload: Record<string, unknown>) => void;
      timer: ReturnType<typeof setTimeout>;
    }
  >();
  private socket: WebSocket | null = null;
  private socketConnectedAt: string | null = null;
  private executionWorkspaceId: string | null = null;
  private workspaceRuntimeId: string | null = null;
  private sessionId: string | null = null;
  private correlationId: string | null = null;
  private projectionWriteChain: Promise<void> = Promise.resolve();
  private httpEvents: Array<{
    cursor: number;
    envelope: Record<string, unknown>;
  }> = [];
  private httpCursor = 0;
  private httpWaiter: (() => void) | null = null;
  private httpEventIds = new Set<string>();
  private httpPersistChain: Promise<void> = Promise.resolve();
  private httpLastActivityAt: string | null = null;

  constructor(
    private readonly state: DurableObjectState,
    private readonly env: WorkspaceGatewayEnv,
  ) {
    this.runtimeAuthenticator = new WorkspaceRuntimeAuthenticator(
      env.CONCLAVE_DB,
    );
    this.sessionStore = new WorkspaceRuntimeSessionStore(env.CONCLAVE_DB);
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    this.restoreAcceptedSocket();
    await this.restoreHttpRuntime();
    if (request.headers.get("Upgrade")?.toLowerCase() === "websocket") {
      return this.connectSocket(request, url);
    }
    if (request.method === "GET" && url.pathname === "/status") {
      const lastActivityAt = await this.lastRuntimeActivityAt();
      const live = this.isActivityRecent(lastActivityAt);
      return Response.json({
        online: live,
        activeTransport: live
          ? this.socket
            ? "websocket"
            : "http_long_poll"
          : null,
        executionWorkspaceId: this.executionWorkspaceId,
        workspaceRuntimeId: this.workspaceRuntimeId,
        sessionId: this.sessionId,
        lastActivityAt,
      });
    }
    if (request.method === "POST" && url.pathname === "/disconnect-runtime") {
      return this.disconnectRuntime(request);
    }
    if (request.method === "POST" && url.pathname === "/dispatch-assignment") {
      return this.dispatchAssignment(request);
    }
    if (request.method === "POST" && url.pathname === "/cancel-assignment") {
      return this.cancelAssignment(request);
    }
    if (request.method === "POST" && url.pathname.startsWith("/runtime/")) {
      return this.handleHttpRuntimeRequest(request, url.pathname);
    }
    return Response.json({ error: "Not found" }, { status: 404 });
  }

  private async handleHttpRuntimeRequest(
    request: Request,
    path: string,
  ): Promise<Response> {
    this.correlationId = requestIdFor(request);
    const body = (await request.json().catch(() => null)) as Record<
      string,
      unknown
    > | null;
    if (!body || typeof body !== "object")
      return Response.json({ error: "Invalid request body" }, { status: 400 });
    const token = extractBearerToken(request.headers);
    const runtimeId =
      path === "/runtime/sessions"
        ? body.workspaceRuntimeId
        : this.workspaceRuntimeId;
    const sessionId =
      typeof body.sessionId === "string" ? body.sessionId : null;
    if (!token || typeof runtimeId !== "string")
      return Response.json(
        { error: "Runtime credential required" },
        { status: 401 },
      );
    const identity = await this.runtimeAuthenticator.authenticateRuntime(
      runtimeId,
      token,
    );
    if (!identity || identity.executionWorkspaceId !== this.state.id.name) {
      return Response.json(
        { error: "Invalid or revoked Workspace runtime credential" },
        { status: 401 },
      );
    }
    if (
      path !== "/runtime/sessions" &&
      (!sessionId ||
        sessionId !== this.sessionId ||
        runtimeId !== this.workspaceRuntimeId)
    ) {
      return Response.json(
        { error: "Runtime session not found" },
        { status: 404 },
      );
    }
    if (path === "/runtime/sessions") {
      if (body.contractVersion !== "1.0")
        return Response.json(
          { error: "Unsupported contract version" },
          { status: 400 },
        );
      if (this.socket) {
        try {
          this.socket.close(1000, "Superseded by HTTP long-poll");
        } catch {
          // A disconnected socket can already be closed by the peer.
        }
      }
      this.socket = null;
      this.socketConnectedAt = null;
      this.executionWorkspaceId = identity.executionWorkspaceId;
      this.workspaceRuntimeId = runtimeId;
      this.sessionId = `session-${crypto.randomUUID()}`;
      this.httpEvents = [];
      this.httpCursor = 0;
      this.httpLastActivityAt = new Date().toISOString();
      const now = new Date().toISOString();
      await this.sessionStore.closeForRuntime(runtimeId, now);
      await this.sessionStore.open({
        sessionId: this.sessionId,
        workspaceId: this.executionWorkspaceId,
        runtimeIdentityId: runtimeId,
        clientVersion: "unknown",
        protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
        connectedAt: now,
      });
      await this.env.CONCLAVE_DB.prepare(
        "UPDATE execution_workspaces SET status = 'online', updated_at = ?1 WHERE id = ?2",
      )
        .bind(now, this.executionWorkspaceId)
        .run();
      await this.persistHttpRuntime();
      return Response.json({
        sessionId: this.sessionId,
        serverTime: now,
        pollTimeoutMs: 25000,
        heartbeatIntervalMs: 15000,
        cursor: "0",
      });
    }
    if (path === "/runtime/events") {
      if (
        !Array.isArray(body.events) ||
        body.events.length < 1 ||
        body.events.length > 100
      )
        return Response.json(
          { error: "events must contain 1 to 100 items" },
          { status: 400 },
        );
      const acceptedEventIds: string[] = [];
      const rejected: Array<{ eventId: string; code: string }> = [];
      for (const raw of body.events) {
        if (!raw || typeof raw !== "object") continue;
        const envelope = raw as Record<string, unknown>;
        if (
          envelope.contract !== "conclave.desktop-auth-transport" ||
          envelope.version !== "1.0" ||
          typeof envelope.eventId !== "string" ||
          !envelope.message
        ) {
          if (typeof envelope.eventId === "string")
            rejected.push({
              eventId: envelope.eventId,
              code: "invalid_event_envelope",
            });
          continue;
        }
        if (this.httpEventIds.has(envelope.eventId)) {
          acceptedEventIds.push(envelope.eventId);
          continue;
        }
        try {
          const message = parseWorkspaceRuntimeMessage(envelope.message);
          await this.handleMessage(JSON.stringify(message), sessionId!);
          this.httpEventIds.add(envelope.eventId);
          acceptedEventIds.push(envelope.eventId);
        } catch {
          rejected.push({
            eventId: envelope.eventId,
            code: "invalid_or_unprocessed_message",
          });
        }
      }
      this.httpLastActivityAt = new Date().toISOString();
      await this.persistHttpRuntime();
      return Response.json({
        acceptedEventIds,
        rejected,
        cursor: String(this.httpCursor),
      });
    }
    if (path === "/runtime/poll") {
      const cursor = Number(body.cursor);
      if (
        !Number.isSafeInteger(cursor) ||
        cursor < 0 ||
        cursor > this.httpCursor ||
        !Number.isInteger(body.waitMs) ||
        (body.waitMs as number) < 0 ||
        (body.waitMs as number) > 60000
      )
        return Response.json(
          { error: "Invalid cursor or waitMs" },
          { status: 400 },
        );
      // The request cursor acknowledges events from the previous successful
      // response. Keep newly returned events queued until that acknowledgement
      // arrives so a dropped poll response can be retried without data loss.
      this.httpEvents = this.httpEvents.filter(
        (entry) => entry.cursor > cursor,
      );
      let events = this.httpEvents
        .filter((entry) => entry.cursor > cursor)
        .slice(0, 100);
      if (!events.length && body.waitMs) {
        if (this.httpWaiter)
          return Response.json(
            { error: "A poll is already active for this session" },
            { status: 409 },
          );
        await new Promise<void>((resolve) => {
          const timer = setTimeout(() => {
            if (this.httpWaiter === wake) this.httpWaiter = null;
            resolve();
          }, body.waitMs as number);
          const wake = () => {
            clearTimeout(timer);
            resolve();
          };
          this.httpWaiter = wake;
        });
        events = this.httpEvents
          .filter((entry) => entry.cursor > cursor)
          .slice(0, 100);
      }
      const nextCursor = events.length
        ? events[events.length - 1]!.cursor
        : cursor;
      this.httpLastActivityAt = new Date().toISOString();
      await this.persistHttpRuntime();
      return Response.json({
        cursor: String(nextCursor),
        events: events.map((entry) => entry.envelope),
        serverTime: new Date().toISOString(),
        timedOut: events.length === 0,
      });
    }
    if (
      path === `/runtime/sessions/${encodeURIComponent(sessionId!)}/close` ||
      path === "/runtime/close"
    ) {
      const now = new Date().toISOString();
      this.queueProjectionWrite(
        () => this.sessionStore.close(sessionId!, now),
        "session_disconnect_update_failed",
        {
          workspaceId: this.executionWorkspaceId ?? undefined,
          runtimeId,
          requestId: this.correlationId ?? undefined,
        },
      );
      if (this.executionWorkspaceId)
        this.queueProjectionWrite(
          () =>
            this.env.CONCLAVE_DB.prepare(
              "UPDATE execution_workspaces SET status = 'offline', updated_at = ?1 WHERE id = ?2",
            )
              .bind(now, this.executionWorkspaceId)
              .run(),
          "workspace_offline_projection_failed",
          { workspaceId: this.executionWorkspaceId, runtimeId },
        );
      this.sessionId = null;
      this.httpLastActivityAt = null;
      await this.state.storage.delete("http-runtime");
      return Response.json({ closed: true, closedAt: now });
    }
    return Response.json({ error: "Not found" }, { status: 404 });
  }

  private async restoreHttpRuntime(): Promise<void> {
    if (this.sessionId || this.socket) return;
    const active = await this.state.storage.get<{
      sessionId: string;
      executionWorkspaceId: string;
      workspaceRuntimeId: string;
      cursor: number;
      events: Array<{ cursor: number; envelope: Record<string, unknown> }>;
      eventIds: string[];
      lastActivityAt?: string;
    }>("http-runtime");
    if (!active) return;
    this.sessionId = active.sessionId;
    this.executionWorkspaceId = active.executionWorkspaceId;
    this.workspaceRuntimeId = active.workspaceRuntimeId;
    this.httpCursor = active.cursor;
    this.httpEvents = active.events;
    this.httpEventIds = new Set(active.eventIds ?? []);
    this.httpLastActivityAt = active.lastActivityAt ?? null;
  }

  private isActivityRecent(lastActivityAt: string | null): boolean {
    const activity = lastActivityAt ? Date.parse(lastActivityAt) : Number.NaN;
    return Number.isFinite(activity) && Date.now() - activity <= 60000;
  }

  private async lastRuntimeActivityAt(): Promise<string | null> {
    if (this.socket && this.sessionId) {
      return (
        (await this.sessionStore.lastHeartbeat(this.sessionId)) ??
        this.socketConnectedAt
      );
    }
    return this.sessionId ? this.httpLastActivityAt : null;
  }

  private async isRuntimeLive(): Promise<boolean> {
    return (
      (this.socket !== null || this.sessionId !== null) &&
      this.isActivityRecent(await this.lastRuntimeActivityAt())
    );
  }

  private persistHttpRuntime(): Promise<void> {
    if (
      !this.sessionId ||
      !this.executionWorkspaceId ||
      !this.workspaceRuntimeId
    )
      return Promise.resolve();
    const snapshot = {
      sessionId: this.sessionId,
      executionWorkspaceId: this.executionWorkspaceId,
      workspaceRuntimeId: this.workspaceRuntimeId,
      cursor: this.httpCursor,
      events: this.httpEvents,
      eventIds: [...this.httpEventIds],
      lastActivityAt: this.httpLastActivityAt,
    };
    this.httpPersistChain = this.httpPersistChain.then(() =>
      this.state.storage.put("http-runtime", snapshot),
    );
    return this.httpPersistChain;
  }

  private restoreAcceptedSocket(): void {
    if (this.socket) return;
    for (const socket of this.state.getWebSockets?.() ?? []) {
      const attachment = socket.deserializeAttachment() as {
        sessionId?: string;
        executionWorkspaceId?: string;
        workspaceRuntimeId?: string;
        correlationId?: string;
        connectedAt?: string;
      } | null;
      if (
        !attachment?.sessionId ||
        !attachment.executionWorkspaceId ||
        !attachment.workspaceRuntimeId ||
        socket.readyState !== WebSocket.OPEN
      ) {
        continue;
      }
      this.socket = socket;
      this.sessionId = attachment.sessionId;
      this.executionWorkspaceId = attachment.executionWorkspaceId;
      this.workspaceRuntimeId = attachment.workspaceRuntimeId;
      this.correlationId = attachment.correlationId ?? null;
      this.socketConnectedAt = attachment.connectedAt ?? null;
      return;
    }
  }

  private async disconnectRuntime(request: Request): Promise<Response> {
    const body = (await request.json()) as Record<string, unknown>;
    const runtimeId =
      typeof body.runtimeId === "string" ? body.runtimeId : null;
    if (!runtimeId) {
      return Response.json({ error: "runtimeId is required" }, { status: 400 });
    }
    if (
      this.workspaceRuntimeId !== runtimeId ||
      (!this.socket && !this.sessionId)
    ) {
      return Response.json({ disconnected: false });
    }
    if (this.socket) {
      try {
        this.socket.close(1000, "Workspace runtime disconnected");
      } catch {
        // The runtime credential is already revoked; a failed close cannot
        // restore authorization or permit future reconnects.
      }
    } else if (this.sessionId) {
      const now = new Date().toISOString();
      await this.sessionStore.close(this.sessionId, now);
      if (this.executionWorkspaceId) {
        await this.env.CONCLAVE_DB.prepare(
          "UPDATE execution_workspaces SET status = 'offline', updated_at = ?1 WHERE id = ?2",
        )
          .bind(now, this.executionWorkspaceId)
          .run();
      }
      this.sessionId = null;
      this.httpLastActivityAt = null;
      await this.state.storage.delete("http-runtime");
      this.httpWaiter?.();
      this.httpWaiter = null;
    }
    return Response.json({ disconnected: true });
  }

  private async connectSocket(request: Request, url: URL): Promise<Response> {
    const correlationId = requestIdFor(request);
    const workspaceRuntimeId = url.searchParams.get("workspaceRuntimeId");
    const token = extractBearerToken(request.headers);
    let runtimeLookupFailed = false;
    let runtimeIdentity: Awaited<
      ReturnType<WorkspaceRuntimeAuthenticator["authenticateRuntime"]>
    > = null;
    if (workspaceRuntimeId) {
      try {
        runtimeIdentity = token
          ? await this.runtimeAuthenticator.authenticateRuntime(
              workspaceRuntimeId,
              token,
            )
          : null;
      } catch {
        runtimeLookupFailed = true;
        runtimeIdentity = null;
      }
    }
    const expectedWorkspaceId = this.state.id.name;
    const runtimeIdMatches = Boolean(
      runtimeIdentity &&
      (!expectedWorkspaceId ||
        runtimeIdentity.executionWorkspaceId === expectedWorkspaceId),
    );
    logStructured(
      "info",
      "GW-05 durable_object_request_received",
      { requestId: correlationId, runtimeId: workspaceRuntimeId ?? undefined },
      {
        upgradeHeaderPresent:
          request.headers.get("Upgrade")?.toLowerCase() === "websocket",
        runtimeIdMatches,
        runtimeLookupFailed,
      },
    );

    if (
      !workspaceRuntimeId ||
      !token ||
      !runtimeIdentity ||
      !runtimeIdMatches
    ) {
      logStructured(
        "warn",
        "GW-06 durable_object_runtime_authentication_failed",
        {
          requestId: correlationId,
          runtimeId: workspaceRuntimeId ?? undefined,
        },
        {
          reason: runtimeLookupFailed
            ? "runtime_identity_lookup_failed"
            : "runtime_identity_mismatch_or_missing_credential",
        },
      );
      return Response.json(
        { error: "workspaceRuntimeId and runtime credential are required" },
        { status: 401 },
      );
    }

    const now = new Date().toISOString();
    logStructured("info", "GW-06 durable_object_runtime_authenticated", {
      requestId: correlationId,
      runtimeId: workspaceRuntimeId,
      workspaceId: runtimeIdentity.executionWorkspaceId,
    });

    if (this.socket) {
      try {
        this.socket.close(1000, "Superseded by new connection");
      } catch {
        // The stale socket is fenced by session id below.
      }
    }
    if (this.sessionId) {
      await this.sessionStore.close(this.sessionId, now);
    }
    await this.state.storage.delete("http-runtime");
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    const sessionId = `session-${crypto.randomUUID()}`;
    server.serializeAttachment({
      sessionId,
      executionWorkspaceId: runtimeIdentity.executionWorkspaceId,
      workspaceRuntimeId,
      correlationId,
      connectedAt: now,
    });
    logStructured("info", "GW-07 websocket_accepting", {
      requestId: correlationId,
      runtimeId: workspaceRuntimeId,
      workspaceId: runtimeIdentity.executionWorkspaceId,
    });
    this.state.acceptWebSocket(server);
    logStructured("info", "GW-08 websocket_accepted", {
      requestId: correlationId,
      runtimeId: workspaceRuntimeId,
      workspaceId: runtimeIdentity.executionWorkspaceId,
    });
    this.socket = server;
    this.socketConnectedAt = now;
    this.executionWorkspaceId = runtimeIdentity.executionWorkspaceId;
    this.workspaceRuntimeId = workspaceRuntimeId;
    this.sessionId = sessionId;
    this.correlationId = correlationId;

    this.queueProjectionWrite(
      () =>
        this.env.CONCLAVE_DB.prepare(
          "UPDATE execution_workspaces SET status = 'online', updated_at = ?1 WHERE id = ?2",
        )
          .bind(now, runtimeIdentity.executionWorkspaceId)
          .run(),
      "workspace_online_projection_failed",
      {
        requestId: correlationId,
        runtimeId: workspaceRuntimeId,
        workspaceId: runtimeIdentity.executionWorkspaceId,
      },
    );
    this.queueProjectionWrite(
      () =>
        this.sessionStore.open({
          sessionId,
          workspaceId: runtimeIdentity.executionWorkspaceId,
          runtimeIdentityId: workspaceRuntimeId,
          clientVersion: "0.1.0",
          protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
          ipAddress: request.headers.get("CF-Connecting-IP") ?? "127.0.0.1",
          connectedAt: now,
        }),
      "session_insert_failed",
      { requestId: correlationId, runtimeId: workspaceRuntimeId },
    );

    logStructured("info", "GW-09 returning_http_101", {
      requestId: correlationId,
      runtimeId: workspaceRuntimeId,
      workspaceId: runtimeIdentity.executionWorkspaceId,
    });
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(socket: WebSocket, data: string | ArrayBuffer): void {
    const attachment = socket.deserializeAttachment() as {
      sessionId: string;
      executionWorkspaceId: string;
      workspaceRuntimeId: string;
      correlationId?: string;
    } | null;
    if (!attachment) return;
    this.socket = socket;
    this.sessionId = attachment.sessionId;
    this.executionWorkspaceId = attachment.executionWorkspaceId;
    this.workspaceRuntimeId = attachment.workspaceRuntimeId;
    this.correlationId = attachment.correlationId ?? this.correlationId;
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
    this.socketConnectedAt = null;
    const now = new Date().toISOString();
    if (this.executionWorkspaceId) {
      this.queueProjectionWrite(
        () =>
          this.env.CONCLAVE_DB.prepare(
            "UPDATE execution_workspaces SET status = 'offline', updated_at = ?1 WHERE id = ?2",
          )
            .bind(now, this.executionWorkspaceId)
            .run(),
        "workspace_offline_projection_failed",
        {
          requestId: this.correlationId ?? undefined,
          runtimeId: this.workspaceRuntimeId ?? undefined,
          workspaceId: this.executionWorkspaceId,
        },
      );
    }
    this.queueProjectionWrite(
      () => this.sessionStore.close(sessionId, now),
      "session_disconnect_update_failed",
      {
        requestId: this.correlationId ?? undefined,
        runtimeId: this.workspaceRuntimeId ?? undefined,
        workspaceId: this.executionWorkspaceId ?? undefined,
      },
    );
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

  private queueProjectionWrite(
    write: () => Promise<unknown>,
    failure: string,
    correlation: {
      requestId?: string;
      runtimeId?: string;
      workspaceId?: string;
    },
  ): void {
    this.projectionWriteChain = this.projectionWriteChain
      .then(() => write())
      .then(() => undefined)
      .catch(() => {
        // Database errors can contain bound values. Emit only a safe category
        // and correlation metadata, never the raw error or credentials.
        logStructured(
          "error",
          "GW-PROJECTION write_failed",
          {
            ...correlation,
          },
          { failure },
        );
      });
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
          const correlation = {
            requestId: this.correlationId ?? undefined,
            runtimeId: this.workspaceRuntimeId ?? undefined,
            workspaceId: this.executionWorkspaceId ?? undefined,
          };
          logStructured("info", "GW-10 workspace_hello_received", correlation, {
            protocolMessageId: message.messageId,
          });
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
        await this.send({
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
        logStructured(
          "info",
          "GW-11 workspace_hello_ack_sent",
          {
            requestId: this.correlationId ?? undefined,
            runtimeId: this.workspaceRuntimeId ?? undefined,
            workspaceId: this.executionWorkspaceId ?? undefined,
          },
          { protocolCorrelationId: message.messageId },
        );
        return;
      case "workspace.heartbeat":
        if (message.payload && typeof message.payload === "object") {
          this.queueProjectionWrite(
            () => this.sessionStore.touch(sessionId, now),
            "session_heartbeat_update_failed",
            {
              requestId: this.correlationId ?? undefined,
              runtimeId: this.workspaceRuntimeId ?? undefined,
              workspaceId: this.executionWorkspaceId ?? undefined,
            },
          );
        }
        await this.send({
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
        logStructured(
          "info",
          "GW-12 workspace_sync_completed",
          {
            requestId: this.correlationId ?? undefined,
            runtimeId: this.workspaceRuntimeId ?? undefined,
            workspaceId: this.executionWorkspaceId ?? undefined,
          },
          { protocolCorrelationId: message.messageId },
        );
        return;
      case "worker.inventory":
        await this.recordWorkerInventory(message.payload);
        return;
      case "assignment.ack": {
        const payload = message.payload as Record<string, unknown>;
        // Terminal acknowledgements are emitted by Cloud for Workspace
        // delivery confirmation. They must never be interpreted as a fresh
        // admission acknowledgement or move a terminal row back to running.
        if (payload.terminal === true) return;
        if (!(await this.assignmentContextMatches(message))) return;
        const accepted = payload.accepted ?? payload.status === "accepted";
        tryLogDiagnosticEvent({
          assignmentId: message.assignmentId,
          workspaceId: message.executionWorkspaceId,
          workspaceRuntimeId: message.workspaceRuntimeId,
          workerId: message.workerId,
          runId: message.runId,
          taskId: message.taskId,
          attemptId: message.attemptId,
          component: "cloud",
          operation: "assignment",
          stage: "admission",
          severity: accepted ? "info" : "warning",
          errorCode: accepted ? undefined : "worker_not_ready",
          retryable: !accepted,
          context: {
            status: accepted ? "accepted" : "rejected",
          },
        });
        if (accepted === true) {
          await this.env.CONCLAVE_DB.prepare(
            `UPDATE worker_assignments SET status = 'acknowledged', updated_at = ?1
             WHERE id = ?2 AND execution_workspace_id = ?3
               AND runtime_identity_id = ?4
               AND status IN ('created', 'dispatched', 'acknowledged', 'running')`,
          )
            .bind(
              now,
              message.assignmentId,
              this.executionWorkspaceId,
              this.workspaceRuntimeId,
            )
            .run();
        } else if (
          message.assignmentId &&
          (await this.terminalAssignmentMatches(message))
        ) {
          await recordAssignmentError(
            this.env.CONCLAVE_DB,
            message.assignmentId,
            {
              error: {
                code: "worker_not_ready",
                message:
                  "The Workspace Worker was not ready to accept the assignment.",
                retryable: true,
              },
              failedAt: now,
            },
          );
        }
        return;
      }
      case "assignment.start.ack": {
        if (!(await this.activeAssignmentMatches(message))) return;
        const transition = await this.env.CONCLAVE_DB.prepare(
          `UPDATE worker_assignments SET status = 'running', updated_at = ?1
             WHERE id = ?2 AND status = 'acknowledged'`,
        )
          .bind(now, message.assignmentId)
          .run();
        if (Number(transition.meta.changes ?? 0) !== 1) return;
        await this.env.CONCLAVE_DB.prepare(
          `UPDATE workflow_tasks SET status = 'running',
                  started_at = COALESCE(started_at, ?1), updated_at = ?1
             WHERE id = ?2 AND status IN ('queued', 'waiting')`,
        )
          .bind(now, message.taskId)
          .run();
        tryLogDiagnosticEvent({
          assignmentId: message.assignmentId,
          workspaceId: message.executionWorkspaceId,
          workspaceRuntimeId: message.workspaceRuntimeId,
          workerId: message.workerId,
          runId: message.runId,
          taskId: message.taskId,
          attemptId: message.attemptId,
          component: "cloud",
          operation: "assignment",
          stage: "provider_execution",
          severity: "info",
          retryable: false,
          context: { status: "running" },
        });
        return;
      }
      case "assignment.activity": {
        const payload = message.payload as Record<string, unknown>;
        const workspaceId =
          this.executionWorkspaceId ?? message.executionWorkspaceId;
        if (!workspaceId) {
          tryLogDiagnosticEvent({
            assignmentId: message.assignmentId,
            workspaceRuntimeId: message.workspaceRuntimeId,
            workerId: message.workerId,
            runId: message.runId,
            taskId: message.taskId,
            attemptId: message.attemptId,
            component: "cloud",
            operation: "assignment.activity",
            stage: "correlation",
            severity: "warning",
            errorCode: "activity_workspace_missing",
            retryable: true,
          });
          return;
        }
        const assignment = await this.env.CONCLAVE_DB.prepare(
          `SELECT id, execution_workspace_id, runtime_identity_id,
                  worker_type_id, workspace_worker_id, run_id, task_id,
                  thread_id,
                  work_request_id, attempt_id, idempotency_key, status,
                  (
                    EXISTS (
                      SELECT 1 FROM workflow_tasks wt
                       WHERE wt.id = worker_assignments.task_id
                         AND wt.work_request_id = worker_assignments.work_request_id
                    ) OR EXISTS (
                      SELECT 1 FROM conversation_turns ct
                       WHERE ct.assignment_id = worker_assignments.id
                         AND ct.work_request_id = worker_assignments.work_request_id
                    )
                  ) AS work_request_binding_valid
           FROM worker_assignments
           WHERE id = ?1`,
        )
          .bind(message.assignmentId)
          .first<Record<string, unknown>>();
        const correlation: WorkspaceAssignmentCorrelation = {
          executionWorkspaceId: message.executionWorkspaceId!,
          workspaceRuntimeId: message.workspaceRuntimeId!,
          workerId: message.workerId!,
          runId: message.runId!,
          taskId: message.taskId!,
          attemptId: message.attemptId!,
          assignmentId: message.assignmentId!,
          idempotencyKey: message.idempotencyKey!,
        };
        if (
          !assignment ||
          !workspaceAssignmentContextMatches(correlation, assignment) ||
          !workspaceAssignmentIsActive(assignment) ||
          Number(assignment.work_request_binding_valid) !== 1 ||
          payload.assignmentId !== message.assignmentId ||
          payload.workerId !== String(assignment.worker_type_id)
        ) {
          tryLogDiagnosticEvent({
            assignmentId: message.assignmentId,
            workspaceId,
            workspaceRuntimeId:
              this.workspaceRuntimeId ?? message.workspaceRuntimeId,
            workerId: message.workerId,
            runId: message.runId,
            taskId: message.taskId,
            attemptId: message.attemptId,
            component: "cloud",
            operation: "assignment.activity",
            stage: "validation",
            severity: "warning",
            errorCode:
              Number(assignment?.work_request_binding_valid) === 1
                ? "activity_correlation_mismatch"
                : "activity_assignment_not_in_work_request",
            retryable: false,
          });
          return;
        }
        const normalized = normalizeActivityPayload({
          title: payload.title,
          status: payload.status,
          activityId: payload.activityId,
          percentage: payload.percentage,
          durationMs: payload.durationMs,
          toolId: payload.toolId,
          toolName: payload.toolName,
          details: payload.details,
        });
        const activityPayload = RealtimeEventPayloadSchema.safeParse({
          entityId: message.assignmentId,
          workerId: payload.workerId,
          sourceEventId: payload.eventId,
          executionId: payload.executionId,
          activityId: payload.activityId,
          activitySequence: payload.sequence,
          activityType: payload.eventType,
          activityStatus: normalized?.status,
          title: normalized?.title,
          percentage: normalized?.percentage,
          durationMs: normalized?.durationMs,
          toolId: normalized?.toolId,
          toolName: normalized?.toolName,
          details: normalized?.details,
        });
        if (!normalized || !activityPayload.success) {
          tryLogDiagnosticEvent({
            assignmentId: message.assignmentId,
            workspaceId,
            workspaceRuntimeId:
              this.workspaceRuntimeId ?? message.workspaceRuntimeId,
            workerId: message.workerId,
            runId: message.runId,
            taskId: message.taskId,
            attemptId: message.attemptId,
            component: "cloud",
            operation: "assignment.activity",
            stage: "validation",
            severity: "warning",
            errorCode: "activity_payload_invalid",
            retryable: false,
          });
          return;
        }
        const replayable = shouldPersistWorkerActivity(activityPayload.data);
        if (replayable) {
          const conflict = await this.env.CONCLAVE_DB.prepare(
            `SELECT source_event_id, provider_sequence
             FROM worker_activity_history
             WHERE assignment_id = ?1 AND attempt_id = ?2
               AND (source_event_id = ?3 OR provider_sequence = ?4)
             LIMIT 1`,
          )
            .bind(
              message.assignmentId,
              message.attemptId,
              activityPayload.data.sourceEventId,
              activityPayload.data.activitySequence,
            )
            .first<{ source_event_id: string; provider_sequence: number }>();
          if (
            conflict &&
            conflict.source_event_id !== activityPayload.data.sourceEventId
          ) {
            tryLogDiagnosticEvent({
              assignmentId: message.assignmentId,
              workspaceId,
              workspaceRuntimeId:
                this.workspaceRuntimeId ?? message.workspaceRuntimeId,
              workerId: message.workerId,
              runId: message.runId,
              taskId: message.taskId,
              attemptId: message.attemptId,
              component: "cloud",
              operation: "assignment.activity",
              stage: "validation",
              severity: "warning",
              errorCode: "activity_sequence_conflict",
              retryable: false,
            });
            return;
          }
        }
        const eventId = `assignment-activity:${message.assignmentId}:${message.attemptId}:${activityPayload.data.sourceEventId}`;
        const historyMutation = replayable
          ? this.env.CONCLAVE_DB.prepare(
              `INSERT OR IGNORE INTO worker_activity_history
               (history_id, assignment_id, workspace_id, attempt_id,
                execution_id, worker_id, source_event_id, provider_sequence,
               event_type, status, activity_id, title, details_json,
                duration_ms, tool_id, tool_name, occurred_at)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                       ?13, ?14, ?15, ?16, ?17)`,
            ).bind(
              eventId,
              message.assignmentId,
              workspaceId,
              message.attemptId,
              activityPayload.data.executionId,
              activityPayload.data.workerId,
              activityPayload.data.sourceEventId,
              activityPayload.data.activitySequence,
              activityPayload.data.activityType,
              activityPayload.data.activityStatus,
              activityPayload.data.activityId ?? null,
              activityPayload.data.title,
              JSON.stringify(activityPayload.data.details ?? {}),
              activityPayload.data.durationMs ?? null,
              activityPayload.data.toolId ?? null,
              activityPayload.data.toolName ?? null,
              new Date().toISOString(),
            )
          : undefined;
        try {
          await createEventPublisher(this.env).publish({
            type: "assignment.activity",
            eventId,
            idempotencyKey: eventId,
            durable: replayable,
            ...(historyMutation ? { mutations: [historyMutation] } : {}),
            workspaceId,
            workspaceRuntimeId:
              this.workspaceRuntimeId ?? message.workspaceRuntimeId,
            runId: message.runId,
            taskId: message.taskId,
            threadId:
              typeof assignment.thread_id === "string"
                ? assignment.thread_id
                : undefined,
            attemptId: message.attemptId,
            assignmentId: message.assignmentId,
            payload: activityPayload.data,
          });
          if (replayable) {
            tryLogDiagnosticEvent({
              assignmentId: message.assignmentId,
              workspaceId,
              workspaceRuntimeId:
                this.workspaceRuntimeId ?? message.workspaceRuntimeId,
              workerId: message.workerId,
              runId: message.runId,
              taskId: message.taskId,
              attemptId: message.attemptId,
              component: "cloud",
              operation: "assignment.activity",
              stage: "activity_forwarding",
              severity: "info",
              retryable: false,
              context: { status: "accepted" },
            });
          }
        } catch {
          tryLogDiagnosticEvent({
            assignmentId: message.assignmentId,
            workspaceId,
            workspaceRuntimeId:
              this.workspaceRuntimeId ?? message.workspaceRuntimeId,
            workerId: message.workerId,
            runId: message.runId,
            taskId: message.taskId,
            attemptId: message.attemptId,
            component: "cloud",
            operation: "assignment.activity",
            stage: "realtime_forwarding",
            severity: "error",
            errorCode: "activity_realtime_publish_failed",
            retryable: true,
          });
        }
        return;
      }
      case "thread.status":
        // Runtime readiness is logical-only. Never persist or relay a local
        // absolute path or repository clone path.
        return;
      case "assignment.result":
        if (!(await this.terminalAssignmentMatches(message))) return;
        tryLogDiagnosticEvent({
          assignmentId: message.assignmentId,
          workspaceId: message.executionWorkspaceId,
          workspaceRuntimeId: message.workspaceRuntimeId,
          workerId: message.workerId,
          runId: message.runId,
          taskId: message.taskId,
          attemptId: message.attemptId,
          component: "cloud",
          operation: "assignment",
          stage: "terminal_recorded",
          severity: "info",
          retryable: false,
          context: { status: "completed" },
        });
        await recordAssignmentResult(
          this.env.CONCLAVE_DB,
          message.assignmentId!,
          message.payload as never,
          message.attemptId,
        );
        await this.sendTerminalAcknowledgement(message, "completed");
        return;
      case "assignment.error":
        {
          if (!(await this.terminalAssignmentMatches(message))) return;
          const payload = message.payload as Record<string, unknown>;
          const error =
            payload.error && typeof payload.error === "object"
              ? (payload.error as Record<string, unknown>)
              : {};
          tryLogDiagnosticEvent({
            assignmentId: message.assignmentId,
            workspaceId: message.executionWorkspaceId,
            workspaceRuntimeId: message.workspaceRuntimeId,
            workerId: message.workerId,
            runId: message.runId,
            taskId: message.taskId,
            attemptId: message.attemptId,
            component: "cloud",
            operation: "assignment",
            stage: "terminal_recorded",
            severity: "error",
            errorCode:
              typeof error.code === "string" ? error.code : "execution_failed",
            retryable: error.retryable === true,
            context: { status: "failed" },
          });
        }
        await recordAssignmentError(
          this.env.CONCLAVE_DB,
          message.assignmentId!,
          message.payload as never,
          message.attemptId,
        );
        await this.sendTerminalAcknowledgement(message, "failed");
        return;
      case "assignment.cancelled":
        if (!(await this.terminalAssignmentMatches(message))) return;
        await recordAssignmentCancelled(
          this.env.CONCLAVE_DB,
          message.assignmentId!,
          message.payload as never,
          message.attemptId,
        );
        tryLogDiagnosticEvent({
          assignmentId: message.assignmentId,
          workspaceId: message.executionWorkspaceId,
          workspaceRuntimeId: message.workspaceRuntimeId,
          workerId: message.workerId,
          runId: message.runId,
          taskId: message.taskId,
          attemptId: message.attemptId,
          component: "cloud",
          operation: "assignment",
          stage: "terminal_recorded",
          severity: "info",
          retryable: false,
          context: { status: "cancelled" },
        });
        await this.sendTerminalAcknowledgement(message, "cancelled");
        return;
      case "assignment.cancel.ack": {
        const payload = message.payload as Record<string, unknown>;
        if (payload.cancelled === true) {
          await recordAssignmentCancelled(
            this.env.CONCLAVE_DB,
            message.assignmentId!,
            {
              status: "cancelled",
              reason:
                typeof payload.reason === "string"
                  ? payload.reason
                  : "Cancelled by Workspace runtime",
            },
          );
        }
        const pending = this.pendingCancelAcks.get(message.assignmentId!);
        if (pending) {
          clearTimeout(pending.timer);
          pending.resolve(payload);
          this.pendingCancelAcks.delete(message.assignmentId!);
        }
        return;
      }
      default:
        return;
    }
  }

  private async syncWorkspace(correlationId: string): Promise<void> {
    const workspaceId = this.executionWorkspaceId;
    if (!workspaceId) return;
    const terminalSince = new Date(
      Date.now() - 24 * 60 * 60 * 1000,
    ).toISOString();
    const assignments = await this.env.CONCLAVE_DB.prepare(
      `SELECT id AS assignment_id, status
       FROM worker_assignments
       WHERE execution_workspace_id = ?1
         AND (
           status IN ('created', 'dispatched', 'acknowledged', 'running')
           OR (status IN ('completed', 'failed', 'cancelled', 'timed_out') AND updated_at >= ?2)
         )
       ORDER BY updated_at DESC
       LIMIT 500`,
    )
      .bind(workspaceId, terminalSince)
      .all<Record<string, unknown>>();
    const activeStatuses = new Set([
      "created",
      "dispatched",
      "acknowledged",
      "running",
    ]);
    const assignmentRows = assignments.results ?? [];
    await this.send({
      protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
      protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
      messageId: `message-${crypto.randomUUID()}`,
      correlationId,
      timestamp: new Date().toISOString(),
      type: "workspace.sync.result",
      executionWorkspaceId: workspaceId,
      workspaceRuntimeId: this.workspaceRuntimeId ?? undefined,
      payload: {
        activeAssignmentIds: assignmentRows
          .filter((row) => activeStatuses.has(String(row.status)))
          .map((row) => String(row.assignment_id)),
        assignmentStates: assignmentRows.map((row) => ({
          assignmentId: String(row.assignment_id),
          status: String(row.status),
        })),
      },
    });
  }

  private async sendTerminalAcknowledgement(
    message: WorkspaceRuntimeMessage,
    status: "completed" | "failed" | "cancelled",
  ): Promise<void> {
    const row = message.assignmentId
      ? await this.env.CONCLAVE_DB.prepare(
          "SELECT status FROM worker_assignments WHERE id = ?1",
        )
          .bind(message.assignmentId)
          .first<{ status: string }>()
      : null;
    // Local Worker Protocol 4.x acknowledges timeout as a failed terminal
    // delivery; Cloud retains the more precise timed_out assignment outcome.
    const authoritativeStatus =
      row?.status === "completed" ||
      row?.status === "failed" ||
      row?.status === "cancelled"
        ? row.status
        : row?.status === "timed_out"
          ? "failed"
          : status;
    tryLogDiagnosticEvent({
      assignmentId: message.assignmentId,
      workspaceId: message.executionWorkspaceId,
      workspaceRuntimeId: message.workspaceRuntimeId,
      workerId: message.workerId,
      runId: message.runId,
      taskId: message.taskId,
      attemptId: message.attemptId,
      component: "cloud",
      operation: "assignment",
      stage: "terminal_acknowledgement",
      severity: "info",
      retryable: false,
      context: { status: authoritativeStatus },
    });
    await this.send({
      protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
      protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
      messageId: `message-${crypto.randomUUID()}`,
      correlationId: message.messageId,
      timestamp: new Date().toISOString(),
      type: "assignment.ack",
      executionWorkspaceId: message.executionWorkspaceId,
      workspaceRuntimeId: message.workspaceRuntimeId,
      workerId: message.workerId,
      runId: message.runId,
      taskId: message.taskId,
      attemptId: message.attemptId,
      assignmentId: message.assignmentId,
      idempotencyKey: message.idempotencyKey,
      payload: {
        accepted: true,
        terminal: true,
        status: authoritativeStatus,
      },
    });
  }

  private async terminalAssignmentMatches(
    message: WorkspaceRuntimeMessage,
  ): Promise<boolean> {
    if (
      !message.assignmentId ||
      !message.executionWorkspaceId ||
      !message.workspaceRuntimeId
    ) {
      return false;
    }
    const assignment = await this.env.CONCLAVE_DB.prepare(
      `SELECT id, execution_workspace_id, runtime_identity_id,
              worker_type_id, workspace_worker_id, run_id, task_id,
              attempt_id, idempotency_key
         FROM worker_assignments WHERE id = ?1`,
    )
      .bind(message.assignmentId)
      .first<Record<string, unknown>>();
    return (
      assignment != null &&
      workspaceAssignmentContextMatches(
        message as unknown as WorkspaceAssignmentCorrelation,
        assignment,
      ) &&
      message.executionWorkspaceId === this.executionWorkspaceId &&
      message.workspaceRuntimeId === this.workspaceRuntimeId
    );
  }

  private async assignmentContextMatches(
    message: WorkspaceRuntimeMessage,
  ): Promise<boolean> {
    if (
      !message.assignmentId ||
      !message.executionWorkspaceId ||
      !message.workspaceRuntimeId
    ) {
      return false;
    }
    const assignment = await this.env.CONCLAVE_DB.prepare(
      `SELECT id, execution_workspace_id, runtime_identity_id,
              worker_type_id, workspace_worker_id, run_id, task_id,
              attempt_id, idempotency_key
         FROM worker_assignments WHERE id = ?1`,
    )
      .bind(message.assignmentId)
      .first<Record<string, unknown>>();
    return (
      assignment != null &&
      workspaceAssignmentContextMatches(
        message as unknown as WorkspaceAssignmentCorrelation,
        assignment,
      ) &&
      message.executionWorkspaceId === this.executionWorkspaceId &&
      message.workspaceRuntimeId === this.workspaceRuntimeId
    );
  }

  private async activeAssignmentMatches(
    message: WorkspaceRuntimeMessage,
  ): Promise<boolean> {
    if (!(await this.assignmentContextMatches(message))) return false;
    const assignment = await this.env.CONCLAVE_DB.prepare(
      "SELECT status FROM worker_assignments WHERE id = ?1",
    )
      .bind(message.assignmentId)
      .first<{ status: string }>();
    return assignment != null && workspaceAssignmentIsActive(assignment);
  }

  private async recordWorkerInventory(payload: unknown): Promise<void> {
    await recordWorkspaceWorkerInventory(
      this.env,
      this.executionWorkspaceId,
      payload,
    );
  }

  private async dispatchAssignment(request: Request): Promise<Response> {
    if (!(await this.isRuntimeLive()))
      return Response.json({ error: "Workspace is offline" }, { status: 503 });
    const body = (await request.json()) as WorkspaceAssignmentCorrelation & {
      payload: unknown;
    };
    const row = await this.env.CONCLAVE_DB.prepare(
      `SELECT wa.id, wa.execution_workspace_id, wa.runtime_identity_id,
              wa.worker_type_id, wa.workspace_worker_id,
              wa.run_id, wa.task_id, wa.attempt_id,
              wa.idempotency_key, wa.status
       FROM worker_assignments wa
       JOIN workspace_space_grants g
         ON g.id = wa.workspace_space_grant_id
        AND g.space_id = wa.space_id
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
    const currentStatus = String(row.status);
    const disposition = assignmentCommandDisposition(currentStatus);
    if (!disposition.shouldSend && disposition.duplicate) {
      return Response.json({
        delivered: false,
        ...disposition,
        status: currentStatus,
      });
    }
    if (!disposition.shouldSend) {
      return Response.json({
        delivered: false,
        ...disposition,
        status: currentStatus,
      });
    }
    let assignmentMessage: WorkspaceRuntimeMessage;
    try {
      assignmentMessage = parseWorkspaceRuntimeMessage({
        protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
        protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
        messageId: `message-${crypto.randomUUID()}`,
        timestamp: new Date().toISOString(),
        type: "assignment.start",
        ...body,
        payload: body.payload,
      });
    } catch {
      return Response.json(
        { error: "Assignment must identify a product Worker Type" },
        { status: 400 },
      );
    }
    try {
      await this.send({ ...assignmentMessage });
    } catch (error) {
      return Response.json(
        {
          error:
            error instanceof Error
              ? error.message
              : "Workspace command could not be queued",
          retryable: true,
          deliveryState: "blocked",
          acceptance: "pending",
        },
        { status: 503 },
      );
    }
    return Response.json({
      delivered: true,
      ...disposition,
      commandId: assignmentMessage.messageId,
      deliveryState: "queued",
      acceptance: "pending",
    });
  }

  private async cancelAssignment(request: Request): Promise<Response> {
    if (!(await this.isRuntimeLive()))
      return Response.json({ error: "Workspace is offline" }, { status: 503 });
    const body = (await request.json()) as WorkspaceAssignmentCorrelation & {
      payload: unknown;
    };
    const assignmentId = body.assignmentId;
    if (this.pendingCancelAcks.has(assignmentId))
      return Response.json(
        { error: "Cancellation is already in progress" },
        { status: 409 },
      );
    let timer: ReturnType<typeof setTimeout>;
    const ackPromise = new Promise<Record<string, unknown>>(
      (resolve, reject) => {
        timer = setTimeout(() => {
          this.pendingCancelAcks.delete(assignmentId);
          reject(
            new Error("Timed out waiting for Workspace process cancellation"),
          );
        }, 15_000);
        this.pendingCancelAcks.set(assignmentId, { resolve, timer });
      },
    );
    try {
      await this.send({
        protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
        protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
        messageId: `message-${crypto.randomUUID()}`,
        timestamp: new Date().toISOString(),
        type: "assignment.cancel",
        ...body,
        payload: body.payload,
      });
    } catch (error) {
      const pending = this.pendingCancelAcks.get(assignmentId);
      if (pending) {
        clearTimeout(pending.timer);
        this.pendingCancelAcks.delete(assignmentId);
      }
      return Response.json(
        {
          error:
            error instanceof Error
              ? error.message
              : "Cancellation could not be queued",
          retryable: true,
        },
        { status: 503 },
      );
    }
    try {
      const acknowledgement = await ackPromise;
      if (acknowledgement.cancelled !== true)
        return Response.json(
          { cancelled: false, ...acknowledgement },
          { status: 409 },
        );
      return Response.json({ cancelled: true, ...acknowledgement });
    } catch (error) {
      return Response.json(
        {
          error:
            error instanceof Error
              ? error.message
              : "Cancellation was not acknowledged",
        },
        { status: 504 },
      );
    }
  }

  private async send(message: Record<string, unknown>): Promise<void> {
    const serialized = serializeWorkspaceRuntimeMessage(message as never);
    if (this.socket) {
      this.socket.send(serialized);
      return;
    }
    if (!this.sessionId || !this.workspaceRuntimeId) return;
    if (this.httpEvents.length >= MAX_WORKSPACE_HTTP_EVENTS) {
      throw new Error("Workspace HTTP event queue is full");
    }
    this.httpLastActivityAt = new Date().toISOString();
    this.httpCursor += 1;
    this.httpEvents.push({
      cursor: this.httpCursor,
      envelope: {
        contract: "conclave.desktop-auth-transport",
        version: "1.0",
        eventId: `srv-${this.httpCursor}`,
        occurredAt: new Date().toISOString(),
        message: JSON.parse(serialized),
      },
    });
    await this.persistHttpRuntime();
    this.httpWaiter?.();
    this.httpWaiter = null;
  }

  private sendError(error: string): void {
    if (this.socket) this.socket.send(JSON.stringify({ error }));
  }
}
