import {
  isDurableRealtimeEventType,
  parseRealtimeEvent,
  type RealtimeEventEnvelope,
  type RealtimeEventPayload,
} from "@conclave/protocol";

export interface EventPublisherEnv {
  readonly CONCLAVE_DB: D1Database;
  readonly CONCLAVE_REALTIME_GATEWAY?: DurableObjectNamespace;
}

export interface DomainEventInput {
  readonly eventId?: string;
  readonly idempotencyKey?: string;
  readonly type: string;
  readonly workspaceId: string;
  readonly projectId?: string;
  readonly runId?: string;
  readonly taskId?: string;
  readonly attemptId?: string;
  readonly assignmentId?: string;
  readonly workspaceRuntimeId?: string;
  readonly payload: RealtimeEventPayload;
  readonly durable?: boolean;
  readonly occurredAt?: string;
}

export interface PublishedEventResult {
  readonly event: RealtimeEventEnvelope;
  readonly persisted: boolean;
  readonly deliveredSubscribers: number;
}

export interface EventPublisher {
  publish(input: DomainEventInput): Promise<PublishedEventResult>;
}

function json(value: unknown): string {
  return JSON.stringify(value);
}

function eventFromRow(row: Record<string, unknown>): RealtimeEventEnvelope {
  return parseRealtimeEvent({
    eventId: String(row.event_id),
    type: String(row.event_type),
    version: "1.0",
    timestamp: String(row.occurred_at),
    workspaceId: String(row.workspace_id),
    ...(row.project_id ? { projectId: String(row.project_id) } : {}),
    ...(row.run_id ? { runId: String(row.run_id) } : {}),
    ...(row.task_id ? { taskId: String(row.task_id) } : {}),
    ...(row.attempt_id ? { attemptId: String(row.attempt_id) } : {}),
    ...(row.assignment_id ? { assignmentId: String(row.assignment_id) } : {}),
    ...(row.workspace_runtime_id
      ? { workspaceRuntimeId: String(row.workspace_runtime_id) }
      : {}),
    sequence: Number(row.sequence),
    payload: JSON.parse(String(row.payload_json)) as RealtimeEventPayload,
  });
}

export class CloudEventPublisher implements EventPublisher {
  constructor(private readonly env: EventPublisherEnv) {}

  async publish(input: DomainEventInput): Promise<PublishedEventResult> {
    const durable = input.durable ?? isDurableRealtimeEventType(input.type);
    const eventId = input.eventId ?? `event-${crypto.randomUUID()}`;
    const idempotencyKey = input.idempotencyKey ?? eventId;
    const occurredAt = input.occurredAt ?? new Date().toISOString();

    let event: RealtimeEventEnvelope;
    let persisted = false;
    if (durable) {
      const result = await this.persistDurableEvent({
        ...input,
        eventId,
        idempotencyKey,
        occurredAt,
      });
      event = result.event;
      persisted = result.persisted;
    } else {
      event = parseRealtimeEvent({
        eventId,
        type: input.type,
        version: "1.0",
        timestamp: occurredAt,
        workspaceId: input.workspaceId,
        ...(input.projectId ? { projectId: input.projectId } : {}),
        ...(input.runId ? { runId: input.runId } : {}),
        ...(input.taskId ? { taskId: input.taskId } : {}),
        ...(input.attemptId ? { attemptId: input.attemptId } : {}),
        ...(input.assignmentId ? { assignmentId: input.assignmentId } : {}),
        ...(input.workspaceRuntimeId
          ? { workspaceRuntimeId: input.workspaceRuntimeId }
          : {}),
        sequence: 0,
        payload: input.payload,
      });
    }

    const deliveredSubscribers = await this.fanout(event);
    return { event, persisted, deliveredSubscribers };
  }

  private async persistDurableEvent(
    input: DomainEventInput & {
      eventId: string;
      idempotencyKey: string;
      occurredAt: string;
    },
  ): Promise<{ event: RealtimeEventEnvelope; persisted: boolean }> {
    const eventBase = {
      eventId: input.eventId,
      type: input.type,
      version: "1.0",
      timestamp: input.occurredAt,
      workspaceId: input.workspaceId,
      ...(input.projectId ? { projectId: input.projectId } : {}),
      ...(input.runId ? { runId: input.runId } : {}),
      ...(input.taskId ? { taskId: input.taskId } : {}),
      ...(input.attemptId ? { attemptId: input.attemptId } : {}),
      ...(input.assignmentId ? { assignmentId: input.assignmentId } : {}),
      ...(input.workspaceRuntimeId
        ? { workspaceRuntimeId: input.workspaceRuntimeId }
        : {}),
      payload: input.payload,
    };
    // Validate the complete contract before a sequence can be consumed.
    parseRealtimeEvent({ ...eventBase, sequence: 0 });

    const db = this.env.CONCLAVE_DB;
    const results = await db.batch([
      db
        .prepare(
          `INSERT INTO realtime_event_cursors (workspace_id, next_sequence)
           VALUES (
             ?1,
             COALESCE(
               (SELECT MAX(sequence) + 1 FROM realtime_events WHERE workspace_id = ?1),
               1
             )
           )
           ON CONFLICT(workspace_id) DO NOTHING`,
        )
        .bind(input.workspaceId),
      db
        .prepare(
          `UPDATE realtime_event_cursors
           SET next_sequence = next_sequence + 1
           WHERE workspace_id = ?1
             AND NOT EXISTS (
               SELECT 1 FROM realtime_events
               WHERE workspace_id = ?1
                 AND (event_id = ?2 OR idempotency_key = ?3)
             )
           RETURNING next_sequence - 1 AS sequence`,
        )
        .bind(input.workspaceId, input.eventId, input.idempotencyKey),
      db
        .prepare(
          `INSERT INTO realtime_events
           (event_id, workspace_id, project_id, run_id, task_id,
            attempt_id, assignment_id, workspace_runtime_id, sequence,
            event_type, payload_json, idempotency_key, occurred_at)
           SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, cursor.next_sequence - 1,
                  ?9, ?10, ?11, ?12
           FROM realtime_event_cursors AS cursor
           WHERE cursor.workspace_id = ?2
             AND NOT EXISTS (
               SELECT 1 FROM realtime_events
               WHERE workspace_id = ?2
                 AND (event_id = ?1 OR idempotency_key = ?11)
             )
           RETURNING *`,
        )
        .bind(
          input.eventId,
          input.workspaceId,
          input.projectId ?? null,
          input.runId ?? null,
          input.taskId ?? null,
          input.attemptId ?? null,
          input.assignmentId ?? null,
          input.workspaceRuntimeId ?? null,
          input.type,
          json(input.payload),
          input.idempotencyKey,
          input.occurredAt,
        ),
    ]);

    const inserted = results[2]?.results?.[0] as
      Record<string, unknown> | undefined;
    if (inserted) {
      return { event: eventFromRow(inserted), persisted: true };
    }

    const duplicate = await db
      .prepare(
        `SELECT * FROM realtime_events
         WHERE workspace_id = ?1 AND (event_id = ?2 OR idempotency_key = ?3)
         LIMIT 1`,
      )
      .bind(input.workspaceId, input.eventId, input.idempotencyKey)
      .first<Record<string, unknown>>();
    if (duplicate) return { event: eventFromRow(duplicate), persisted: false };
    throw new Error("Could not persist durable realtime event");
  }

  private async fanout(event: RealtimeEventEnvelope): Promise<number> {
    const gateway = this.env.CONCLAVE_REALTIME_GATEWAY;
    if (!gateway) return 0;
    const members = event.projectId
      ? await this.env.CONCLAVE_DB.prepare(
          `SELECT user_id FROM project_memberships
           WHERE project_id = ?1`,
        )
          .bind(event.projectId)
          .all<{ user_id: string }>()
      : await this.env.CONCLAVE_DB.prepare(
          `SELECT owner_user_id AS user_id FROM execution_workspaces
           WHERE id = ?1 AND status <> 'revoked'`,
        )
          .bind(event.workspaceId)
          .all<{ user_id: string }>();
    const results = await Promise.all(
      (members.results ?? []).map(async ({ user_id: userId }) => {
        try {
          const response = await gateway.getByName(`user:${userId}`).fetch(
            new Request("https://realtime.internal/publish", {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: json(event),
            }),
          );
          return response.ok;
        } catch {
          return false;
        }
      }),
    );
    return results.filter(Boolean).length;
  }
}

export function createEventPublisher(env: EventPublisherEnv): EventPublisher {
  return new CloudEventPublisher(env);
}
