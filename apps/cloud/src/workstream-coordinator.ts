/**
 * Durable Object coordinator for one Workstream.
 *
 * D1 is the source of truth. The object only serializes mutations, fences
 * workers, and schedules reconciliation after a restart or lease timeout.
 */

export interface WorkstreamCoordinatorEnv {
  readonly CONCLAVE_DB: D1Database;
  readonly CONCLAVE_WORKSPACE_GATEWAY?: DurableObjectNamespace;
}

export type CoordinatorRequestRow = {
  id: string;
  workstreamId: string;
  mode: "stateless" | "stateful";
  status: string;
  primaryWorkspaceId: string;
  checkoutId: string;
  createdAt: string;
};

export type CoordinatorLeaseRow = {
  id: string;
  workstreamId: string;
  workRequestId: string;
  checkoutId: string;
  workspaceId: string;
  fencingToken: number;
  status: "active" | "released" | "expired";
  expiresAt: string;
  baseRevision?: string;
};

export const WORKSTREAM_LEASE_MS = 60_000;

export function selectNextStatefulRequest(
  rows: readonly CoordinatorRequestRow[],
): CoordinatorRequestRow | null {
  return [...rows]
    .filter((row) => row.mode === "stateful" && row.status === "queued")
    .sort((a, b) =>
      a.createdAt.localeCompare(b.createdAt) || a.id.localeCompare(b.id),
    )[0] ?? null;
}

export function nextFencingToken(maxToken: number | null | undefined): number {
  return Math.max(1, (maxToken ?? 0) + 1);
}

export function leaseIsCurrent(
  lease: Pick<CoordinatorLeaseRow, "status" | "expiresAt" | "fencingToken">,
  fencingToken: number,
  now = Date.now(),
): boolean {
  return (
    lease.status === "active" &&
    lease.fencingToken === fencingToken &&
    Date.parse(lease.expiresAt) > now
  );
}

function json(data: unknown, init?: ResponseInit): Response {
  return Response.json(data, {
    ...init,
    headers: { "content-type": "application/json; charset=utf-8", ...init?.headers },
  });
}

function badRequest(message: string): Response {
  return json({ error: message }, { status: 400 });
}

function conflict(message: string): Response {
  return json({ error: message }, { status: 409 });
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) throw new Error(`${field} is required`);
  return value;
}

export class WorkstreamExecutionCoordinator implements DurableObject {
  constructor(
    private readonly state: DurableObjectState,
    private readonly env: WorkstreamCoordinatorEnv,
  ) {}

  async fetch(request: Request): Promise<Response> {
    try {
      const identity = request.headers.get("x-workstream-id");
      if (identity) {
        const existing = await this.state.storage.get<string>("workstreamId");
        if (existing && existing !== identity) return conflict("Coordinator identity mismatch");
        if (!existing) await this.state.storage.put("workstreamId", identity);
      }
      const path = new URL(request.url).pathname;
      if (request.method === "GET" && path === "/status") return this.status();
      if (request.method !== "POST") return badRequest("POST is required");
      if (path === "/enqueue") return await this.enqueue(await request.json());
      if (path === "/cancel") return await this.cancel(await request.json());
      if (path === "/heartbeat") return await this.heartbeat(await request.json());
      if (path === "/complete") return await this.complete(await request.json());
      if (path === "/reconcile") return await this.reconcile();
      return json({ error: "Not found" }, { status: 404 });
    } catch (error) {
      return json(
        { error: error instanceof Error ? error.message : "Coordinator error" },
        { status: 400 },
      );
    }
  }

  async alarm(): Promise<void> {
    await this.reconcile(true);
  }

  private async status(): Promise<Response> {
    const workstreamId = await this.workstreamId();
    const active = await this.env.CONCLAVE_DB.prepare(
      `SELECT id, work_request_id AS workRequestId, checkout_id AS checkoutId,
              workspace_id AS workspaceId, fencing_token AS fencingToken,
              status, expires_at AS expiresAt
       FROM workstream_execution_leases
       WHERE workstream_id = ?1 AND status = 'active'
       LIMIT 1`,
    ).bind(workstreamId).first<CoordinatorLeaseRow>();
    const queued = await this.env.CONCLAVE_DB.prepare(
      `SELECT id, created_at AS createdAt FROM work_requests
       WHERE workstream_id = ?1 AND mode = 'stateful' AND status = 'queued'
       ORDER BY created_at, id`,
    ).bind(workstreamId).all<{ id: string; createdAt: string }>();
    return json({ workstreamId, active, queued: queued.results });
  }

  private async enqueue(input: unknown): Promise<Response> {
    const workRequestId = requiredString((input as Record<string, unknown>)?.workRequestId, "workRequestId");
    const request = await this.requestRow(workRequestId);
    if (!request) return json({ error: "Work Request not found" }, { status: 404 });
    if (request.mode !== "stateful") return badRequest("Only stateful Work Requests use this coordinator");
    if (request.status !== "queued") return json({ workRequestId, status: request.status });
    const result = await this.reconcile();
    return result;
  }

  private async cancel(input: unknown): Promise<Response> {
    const workRequestId = requiredString((input as Record<string, unknown>)?.workRequestId, "workRequestId");
    const request = await this.requestRow(workRequestId);
    if (!request) return json({ error: "Work Request not found" }, { status: 404 });
    if (request.status === "cancelled") return json({ workRequestId, status: "cancelled" });
    if (request.status !== "queued") return conflict("Only queued Work Requests can be cancelled");
    const now = new Date().toISOString();
    await this.env.CONCLAVE_DB.batch([
      this.env.CONCLAVE_DB.prepare(
        "UPDATE work_requests SET status = 'cancelled', updated_at = ?1 WHERE id = ?2 AND status = 'queued'",
      ).bind(now, workRequestId),
      this.env.CONCLAVE_DB.prepare(
        "UPDATE runs SET status = 'cancelled', updated_at = ?1 WHERE work_request_id = ?2 AND status = 'created'",
      ).bind(now, workRequestId),
    ]);
    await this.reconcile();
    return json({ workRequestId, status: "cancelled" });
  }

  private async heartbeat(input: unknown): Promise<Response> {
    const body = input as Record<string, unknown>;
    const lease = await this.currentLease(
      requiredString(body.leaseId, "leaseId"),
      requiredString(body.workRequestId, "workRequestId"),
      Number(body.fencingToken),
    );
    if (!lease || !leaseIsCurrent(lease, Number(body.fencingToken))) return conflict("Stale or expired lease");
    const expiresAt = new Date(Date.now() + WORKSTREAM_LEASE_MS).toISOString();
    await this.env.CONCLAVE_DB.prepare(
      "UPDATE workstream_execution_leases SET expires_at = ?1 WHERE id = ?2 AND status = 'active'",
    ).bind(expiresAt, lease.id).run();
    await this.state.storage.setAlarm(Date.parse(expiresAt));
    return json({ leaseId: lease.id, fencingToken: lease.fencingToken, expiresAt });
  }

  private async complete(input: unknown): Promise<Response> {
    const body = input as Record<string, unknown>;
    const lease = await this.currentLease(
      requiredString(body.leaseId, "leaseId"),
      requiredString(body.workRequestId, "workRequestId"),
      Number(body.fencingToken),
    );
    if (!lease || !leaseIsCurrent(lease, Number(body.fencingToken))) return conflict("Stale or expired lease");
    const status = body.status === "failed"
      ? "failed"
      : body.status === "cancelled"
        ? "cancelled"
        : "completed";
    const now = new Date().toISOString();
    if (this.env.CONCLAVE_WORKSPACE_GATEWAY) {
      const gateway = this.env.CONCLAVE_WORKSPACE_GATEWAY.getByName(lease.workspaceId);
      await gateway.fetch("https://workspace-gateway/finalize-checkout", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          checkoutId: lease.checkoutId,
          workRequestId: lease.workRequestId,
          baseRevision: lease.baseRevision,
          outcome: status === "completed" ? "success" : status,
          message: `Workstream checkpoint for ${lease.workRequestId}`,
        }),
      });
    }
    await this.env.CONCLAVE_DB.batch([
      this.env.CONCLAVE_DB.prepare(
        "UPDATE workstream_execution_leases SET status = 'released', released_at = ?1 WHERE id = ?2 AND status = 'active'",
      ).bind(now, lease.id),
      this.env.CONCLAVE_DB.prepare(
        "UPDATE work_requests SET status = ?1, updated_at = ?2 WHERE id = ?3 AND status = 'running'",
      ).bind(status, now, lease.workRequestId),
      this.env.CONCLAVE_DB.prepare(
        "UPDATE runs SET status = ?1, updated_at = ?2 WHERE work_request_id = ?3 AND status = 'running'",
      ).bind(status, now, lease.workRequestId),
    ]);
    await this.reconcile();
    return json({ workRequestId: lease.workRequestId, status });
  }

  private async reconcile(fromAlarm = false): Promise<Response> {
    const workstreamId = await this.workstreamId();
    const now = new Date().toISOString();
    await this.env.CONCLAVE_DB.prepare(
      `UPDATE workstream_execution_leases SET status = 'expired', released_at = ?1
       WHERE workstream_id = ?2 AND status = 'active' AND expires_at <= ?1`,
    ).bind(now, workstreamId).run();
    await this.env.CONCLAVE_DB.prepare(
      `UPDATE work_requests SET status = 'failed', updated_at = ?1
       WHERE workstream_id = ?2 AND status = 'running'
         AND id IN (SELECT work_request_id FROM workstream_execution_leases
                    WHERE workstream_id = ?2 AND status = 'expired' AND released_at = ?1)`,
    ).bind(now, workstreamId).run();
    const active = await this.env.CONCLAVE_DB.prepare(
      "SELECT id FROM workstream_execution_leases WHERE workstream_id = ?1 AND status = 'active' LIMIT 1",
    ).bind(workstreamId).first<{ id: string }>();
    if (!active) await this.startNext(workstreamId);
    if (fromAlarm) {
      const nextExpiry = await this.env.CONCLAVE_DB.prepare(
        "SELECT MIN(expires_at) AS expiresAt FROM workstream_execution_leases WHERE workstream_id = ?1 AND status = 'active'",
      ).bind(workstreamId).first<{ expiresAt: string | null }>();
      if (nextExpiry?.expiresAt) await this.state.storage.setAlarm(Date.parse(nextExpiry.expiresAt));
    }
    return this.status();
  }

  private async startNext(workstreamId: string): Promise<void> {
    const rows = await this.env.CONCLAVE_DB.prepare(
      `SELECT id, workstream_id AS workstreamId, mode, status,
              primary_workspace_id AS primaryWorkspaceId, checkout_id AS checkoutId,
              created_at AS createdAt
       FROM work_requests WHERE workstream_id = ?1 AND mode = 'stateful' AND status = 'queued'
       ORDER BY created_at, id LIMIT 1`,
    ).bind(workstreamId).all<CoordinatorRequestRow>();
    const next = selectNextStatefulRequest(rows.results);
    if (!next) return;
    const tokenRow = await this.env.CONCLAVE_DB.prepare(
      "SELECT MAX(fencing_token) AS maxToken FROM workstream_execution_leases WHERE workstream_id = ?1",
    ).bind(workstreamId).first<{ maxToken: number | null }>();
    const token = nextFencingToken(tokenRow?.maxToken);
    const leaseId = `lease-${crypto.randomUUID()}`;
    const now = new Date().toISOString();
    const expiresAt = new Date(Date.now() + WORKSTREAM_LEASE_MS).toISOString();
    await this.env.CONCLAVE_DB.batch([
      this.env.CONCLAVE_DB.prepare(
        "UPDATE work_requests SET status = 'running', updated_at = ?1 WHERE id = ?2 AND status = 'queued'",
      ).bind(now, next.id),
      this.env.CONCLAVE_DB.prepare(
        "UPDATE runs SET status = 'running', updated_at = ?1 WHERE work_request_id = ?2 AND status = 'created'",
      ).bind(now, next.id),
      this.env.CONCLAVE_DB.prepare(
        `INSERT INTO workstream_execution_leases
         (id, workstream_id, checkout_id, work_request_id, workspace_id, fencing_token, status, acquired_at, expires_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'active', ?7, ?8)`,
      ).bind(leaseId, workstreamId, next.checkoutId, next.id, next.primaryWorkspaceId, token, now, expiresAt),
    ]);
    await this.state.storage.setAlarm(Date.parse(expiresAt));
  }

  private async requestRow(id: string): Promise<CoordinatorRequestRow | null> {
    return this.env.CONCLAVE_DB.prepare(
      `SELECT id, workstream_id AS workstreamId, mode, status,
              primary_workspace_id AS primaryWorkspaceId, checkout_id AS checkoutId,
              created_at AS createdAt FROM work_requests WHERE id = ?1`,
    ).bind(id).first<CoordinatorRequestRow>();
  }

  private async currentLease(leaseId: string, workRequestId: string, token: number) {
    return this.env.CONCLAVE_DB.prepare(
      `SELECT l.id, l.workstream_id AS workstreamId, l.work_request_id AS workRequestId,
              checkout_id AS checkoutId, workspace_id AS workspaceId,
              fencing_token AS fencingToken, l.status, l.expires_at AS expiresAt,
              c.revision AS baseRevision
       FROM workstream_execution_leases l
       JOIN workstream_checkouts c ON c.id = l.checkout_id
       WHERE l.id = ?1 AND l.work_request_id = ?2 AND l.fencing_token = ?3`,
    ).bind(leaseId, workRequestId, token).first<CoordinatorLeaseRow>();
  }

  private async workstreamId(): Promise<string> {
    const value = await this.state.storage.get<string>("workstreamId");
    if (value) return value;
    throw new Error("Coordinator identity is not initialized");
  }
}
