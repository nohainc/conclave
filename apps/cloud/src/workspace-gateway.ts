import {
  parseWorkspaceRuntimeMessage,
  serializeWorkspaceRuntimeMessage,
  WORKSPACE_RUNTIME_PROTOCOL_NAME,
  WORKSPACE_RUNTIME_PROTOCOL_VERSION,
  type WorkspaceRuntimeMessage,
} from "@conclave/workspace-runtime-protocol";
import { createEventPublisher } from "./event-publisher.js";
import {
  recordAssignmentCancelled,
  recordAssignmentError,
  recordAssignmentResult,
} from "./assignment-dispatcher.js";
import { extractBearerToken } from "../../../packages/security/src/index.js";
import { logStructured, requestIdFor } from "./observability.js";
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
        const accepted = payload.accepted ?? payload.status === "accepted";
        await this.env.CONCLAVE_DB.prepare(
          `UPDATE worker_assignments SET status = ?1, updated_at = ?2
           WHERE id = ?3 AND execution_workspace_id = ?4
             AND runtime_identity_id = ?5
             AND status IN ('created', 'dispatched', 'acknowledged', 'running')`,
        )
          .bind(
            accepted ? "acknowledged" : "failed",
            now,
            message.assignmentId,
            this.executionWorkspaceId,
            this.workspaceRuntimeId,
          )
          .run();
        return;
      }
      case "assignment.progress": {
        const payload = message.payload as Record<string, unknown>;
        const workspaceId =
          this.executionWorkspaceId ?? message.executionWorkspaceId;
        if (!workspaceId) return;
        await createEventPublisher(this.env).publish({
          type: "assignment.progress",
          durable: false,
          workspaceId,
          workspaceRuntimeId:
            this.workspaceRuntimeId ?? message.workspaceRuntimeId,
          runId: message.runId,
          taskId: message.taskId,
          attemptId: message.attemptId,
          assignmentId: message.assignmentId,
          idempotencyKey: `assignment-progress:${message.messageId}`,
          payload: {
            entityId: message.assignmentId,
            workerId: message.workerId,
            percentage:
              typeof payload.percentage === "number" ? payload.percentage : 0,
            message: typeof payload.message === "string" ? payload.message : "",
            ...(typeof payload.metrics === "object" &&
            payload.metrics !== null &&
            !Array.isArray(payload.metrics)
              ? { summary: JSON.stringify(payload.metrics).slice(0, 32768) }
              : {}),
          },
        });
        return;
      }
      case "thread.status":
        // Runtime readiness is logical-only. Never persist or relay a local
        // absolute path or repository clone path.
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
    const assignments = await this.env.CONCLAVE_DB.prepare(
      `SELECT id AS assignment_id, status
       FROM worker_assignments
       WHERE execution_workspace_id = ?1
         AND status IN ('created', 'dispatched', 'acknowledged', 'running')`,
    )
      .bind(workspaceId)
      .all<Record<string, unknown>>();
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
    await this.send({ ...assignmentMessage });
    return Response.json({ delivered: true });
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
    await this.send({
      protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
      protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
      messageId: `message-${crypto.randomUUID()}`,
      timestamp: new Date().toISOString(),
      type: "assignment.cancel",
      ...body,
      payload: body.payload,
    });
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
