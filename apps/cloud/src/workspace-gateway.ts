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
import { logStructured, requestIdFor } from "./observability.js";

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

async function findWorkspaceRuntimeIdentity(
  db: Pick<D1Database, "prepare">,
  workspaceRuntimeId: string,
): Promise<{
  executionWorkspaceId: string;
  credentialTokenHash: string;
} | null> {
  const row = await db
    .prepare(
      `SELECT wri.workspace_id AS executionWorkspaceId,
              wri.credential_token_hash AS credentialTokenHash
       FROM workspace_runtime_identities wri
       JOIN execution_workspaces ew ON ew.id = wri.workspace_id
       WHERE wri.id = ?1
         AND wri.revoked_at IS NULL
         AND ew.status <> 'revoked'`,
    )
    .bind(workspaceRuntimeId)
    .first<{
      executionWorkspaceId: string;
      credentialTokenHash: string;
    }>();
  return row ?? null;
}

export class WorkspaceGateway implements DurableObject {
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
  ) {}

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
    const identity = await findWorkspaceRuntimeIdentity(
      this.env.CONCLAVE_DB,
      runtimeId,
    );
    if (
      !identity ||
      identity.executionWorkspaceId !== this.state.id.name ||
      identity.credentialTokenHash !== (await hashToken(token))
    ) {
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
        } catch {}
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
      await this.env.CONCLAVE_DB.prepare(
        "UPDATE workspace_sessions SET disconnected_at = ?1 WHERE runtime_identity_id = ?2 AND disconnected_at IS NULL",
      )
        .bind(now, runtimeId)
        .run();
      await this.env.CONCLAVE_DB.prepare(
        "INSERT INTO workspace_sessions (id, workspace_id, runtime_identity_id, client_version, protocol_version, connected_at, last_heartbeat_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)",
      )
        .bind(
          this.sessionId,
          this.executionWorkspaceId,
          runtimeId,
          "unknown",
          WORKSPACE_RUNTIME_PROTOCOL_VERSION,
          now,
        )
        .run();
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
        () =>
          this.env.CONCLAVE_DB.prepare(
            "UPDATE workspace_sessions SET disconnected_at = ?1 WHERE id = ?2",
          )
            .bind(now, sessionId)
            .run(),
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
      const session = await this.env.CONCLAVE_DB.prepare(
        "SELECT last_heartbeat_at AS lastActivityAt FROM workspace_sessions WHERE id = ?1",
      )
        .bind(this.sessionId)
        .first<{ lastActivityAt: string }>();
      return session?.lastActivityAt ?? this.socketConnectedAt;
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
        this.socket.close(1000, "Workspace runtime unpaired");
      } catch {
        // The runtime credential is already revoked; a failed close cannot
        // restore authorization or permit future reconnects.
      }
    } else if (this.sessionId) {
      const now = new Date().toISOString();
      await this.env.CONCLAVE_DB.prepare(
        "UPDATE workspace_sessions SET disconnected_at = ?1 WHERE id = ?2",
      )
        .bind(now, this.sessionId)
        .run();
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
      ReturnType<typeof findWorkspaceRuntimeIdentity>
    > = null;
    if (workspaceRuntimeId) {
      try {
        runtimeIdentity = await findWorkspaceRuntimeIdentity(
          this.env.CONCLAVE_DB,
          workspaceRuntimeId,
        );
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

    const authorized =
      runtimeIdentity.credentialTokenHash === (await hashToken(token));
    if (!authorized) {
      logStructured(
        "warn",
        "GW-06 durable_object_runtime_authentication_failed",
        {
          requestId: correlationId,
          runtimeId: workspaceRuntimeId,
          workspaceId: runtimeIdentity.executionWorkspaceId,
        },
        { reason: "invalid_or_revoked_credential" },
      );
      return Response.json(
        { error: "Invalid or revoked Workspace runtime credential" },
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
      await this.env.CONCLAVE_DB.prepare(
        "UPDATE workspace_sessions SET disconnected_at = ?1 WHERE id = ?2 AND disconnected_at IS NULL",
      )
        .bind(now, this.sessionId)
        .run();
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
        this.env.CONCLAVE_DB.prepare(
          `INSERT INTO workspace_sessions
           (id, workspace_id, runtime_identity_id, client_version, protocol_version,
            ip_address, connected_at, last_heartbeat_at)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)`,
        )
          .bind(
            sessionId,
            runtimeIdentity.executionWorkspaceId,
            workspaceRuntimeId,
            "0.1.0",
            WORKSPACE_RUNTIME_PROTOCOL_VERSION,
            request.headers.get("CF-Connecting-IP") ?? "127.0.0.1",
            now,
          )
          .run(),
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
      () =>
        this.env.CONCLAVE_DB.prepare(
          "UPDATE workspace_sessions SET disconnected_at = ?1 WHERE id = ?2",
        )
          .bind(now, sessionId)
          .run(),
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
            () =>
              this.env.CONCLAVE_DB.prepare(
                "UPDATE workspace_sessions SET last_heartbeat_at = ?1 WHERE id = ?2",
              )
                .bind(now, sessionId)
                .run(),
            "session_heartbeat_update_failed",
            {
              requestId: this.correlationId ?? undefined,
              runtimeId: this.workspaceRuntimeId ?? undefined,
              workspaceId: this.executionWorkspaceId ?? undefined,
            },
          );
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
          hostId: this.workspaceRuntimeId ?? message.workspaceRuntimeId,
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
      const activationState = item.activationState;
      const readinessState = item.readinessState;
      const revision = item.revision;
      const concurrency = item.localConcurrencyLimit;
      if (
        typeof workerId !== "string" ||
        typeof workerTypeId !== "string" ||
        !["enabled", "disabled"].includes(String(activationState)) ||
        ![
          "not_probed",
          "ready",
          "setup_required",
          "sign_in_required",
          "worker_runtime_unavailable",
          "test_failed",
        ].includes(String(readinessState)) ||
        !Number.isSafeInteger(revision) ||
        (revision as number) < 1 ||
        !Number.isInteger(concurrency) ||
        (concurrency as number) < 1
      ) {
        continue;
      }
      const previous = await this.env.CONCLAVE_DB.prepare(
        "SELECT workspace_id, revision FROM workspace_worker_inventory WHERE worker_id = ?1",
      )
        .bind(workerId)
        .first<{ workspace_id: string; revision: number }>();
      // A Worker ID is permanently owned by the Workspace that first synced
      // it, and its local revision only moves forward.
      if (previous && previous.workspace_id !== workspaceId) {
        continue;
      }
      // Structurally valid entries count as reported even when their revision
      // is unchanged. Malformed entries cannot keep omitted Workers alive.
      reportedWorkerIds.add(workerId);
      if (previous && Number(previous.revision) >= (revision as number)) {
        if (Number(previous.revision) === revision) {
          await this.env.CONCLAVE_DB.prepare(
            `UPDATE workspace_worker_inventory SET last_seen_at = ?3
              WHERE worker_id = ?1 AND workspace_id = ?2 AND revision = ?4`,
          )
            .bind(workerId, workspaceId, now, revision)
            .run();
        }
        continue;
      }
      const arrayJson = (value: unknown, max: number): string =>
        JSON.stringify(
          Array.isArray(value)
            ? value
                .filter((entry): entry is string => typeof entry === "string")
                .map((entry) => entry.trim())
                .filter((entry) => /^[a-z][a-z0-9_:-]{0,127}$/.test(entry))
                .slice(0, max)
            : [],
        );
      const nullableText = (value: unknown, max: number): string | null =>
        typeof value === "string" && value.trim().length <= max
          ? value.trim() || null
          : null;
      const nullableSafeToken = (
        value: unknown,
        pattern: RegExp,
      ): string | null =>
        typeof value === "string" && pattern.test(value.trim())
          ? value.trim()
          : null;
      const readinessIssueCode =
        typeof item.readinessIssueCode === "string" &&
        /^[a-z][a-z0-9_]{0,127}$/.test(item.readinessIssueCode)
          ? item.readinessIssueCode
          : null;
      await this.env.CONCLAVE_DB.prepare(
        `INSERT INTO workspace_worker_inventory
          (worker_id, workspace_id, owner_user_id, worker_type_id,
           activation_state, readiness_state, readiness_issue_code,
           engine_version, profile_definition_id, profile_release_version,
           provider_tool_name, provider_tool_version,
           capabilities_json, local_concurrency_limit, revision,
           created_at, updated_at, last_seen_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
         ON CONFLICT(worker_id) DO UPDATE SET
           worker_type_id = excluded.worker_type_id,
           activation_state = excluded.activation_state,
           readiness_state = excluded.readiness_state,
           readiness_issue_code = excluded.readiness_issue_code,
           engine_version = excluded.engine_version,
           profile_definition_id = excluded.profile_definition_id,
           profile_release_version = excluded.profile_release_version,
           provider_tool_name = excluded.provider_tool_name,
           provider_tool_version = excluded.provider_tool_version,
           capabilities_json = excluded.capabilities_json,
           local_concurrency_limit = excluded.local_concurrency_limit,
           revision = excluded.revision,
           updated_at = excluded.updated_at,
           last_seen_at = excluded.last_seen_at
         WHERE workspace_worker_inventory.workspace_id = excluded.workspace_id
           AND workspace_worker_inventory.revision < excluded.revision`,
      )
        .bind(
          workerId,
          workspaceId,
          owner.owner_user_id,
          workerTypeId,
          activationState,
          readinessState,
          readinessIssueCode,
          nullableSafeToken(
            item.engineVersion,
            /^[A-Za-z0-9][A-Za-z0-9.+_-]{0,63}$/,
          ),
          typeof item.profileDefinitionId === "string" &&
            /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(item.profileDefinitionId) &&
            item.profileDefinitionId.length <= 96
            ? item.profileDefinitionId
            : null,
          Number.isSafeInteger(item.profileReleaseVersion) &&
            (item.profileReleaseVersion as number) > 0
            ? item.profileReleaseVersion
            : null,
          nullableSafeToken(
            item.providerToolName,
            /^[A-Za-z0-9][A-Za-z0-9 ._-]{0,127}$/,
          ),
          nullableSafeToken(
            item.providerToolVersion,
            /^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}$/,
          ),
          arrayJson(item.capabilities, 128),
          Math.min(1024, concurrency as number),
          revision,
          nullableText(item.createdAt, 40) ?? now,
          now,
          nullableText(item.lastSeenAt, 40) ?? now,
        )
        .run();
      await this.env.CONCLAVE_DB.prepare(
        `INSERT OR IGNORE INTO worker_scheduling (worker_id, state, updated_at)
         SELECT worker_id, 'disabled', ?2 FROM workspace_worker_inventory WHERE worker_id = ?1`,
      )
        .bind(workerId, now)
        .run();
    }
    // Full snapshots are authoritative. Removed local slots disappear from
    // inventory; scheduling and audit rows cascade with the inventory row.
    if (fullSnapshot) {
      const existing = await this.env.CONCLAVE_DB.prepare(
        `SELECT worker_id FROM workspace_worker_inventory
          WHERE workspace_id = ?1`,
      )
        .bind(workspaceId)
        .all<{ worker_id: string }>();
      for (const row of existing.results ?? []) {
        if (reportedWorkerIds.has(row.worker_id)) continue;
        await this.env.CONCLAVE_DB.prepare(
          `DELETE FROM workspace_worker_inventory
            WHERE worker_id = ?1 AND workspace_id = ?2`,
        )
          .bind(row.worker_id, workspaceId)
          .run();
      }
    }
  }

  private async provisionCheckout(request: Request): Promise<Response> {
    if (!(await this.isRuntimeLive())) {
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
              c.revision, ws.project_id AS projectId,
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
    if (!(await this.isRuntimeLive()))
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
    if (!(await this.isRuntimeLive()))
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
    this.send({ ...assignmentMessage });
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
    this.send({
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

  private send(message: Record<string, unknown>): void {
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
    void this.persistHttpRuntime();
    this.httpWaiter?.();
    this.httpWaiter = null;
  }

  private sendError(error: string): void {
    if (this.socket) this.socket.send(JSON.stringify({ error }));
  }
}
