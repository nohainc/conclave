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
  readonly chatId?: string;
  readonly runId?: string;
  readonly taskId?: string;
  readonly attemptId?: string;
  readonly assignmentId?: string;
  readonly hostId?: string;
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
    ...(row.chat_id ? { chatId: String(row.chat_id) } : {}),
    ...(row.run_id ? { runId: String(row.run_id) } : {}),
    ...(row.task_id ? { taskId: String(row.task_id) } : {}),
    ...(row.attempt_id ? { attemptId: String(row.attempt_id) } : {}),
    ...(row.assignment_id ? { assignmentId: String(row.assignment_id) } : {}),
    ...(row.host_id ? { hostId: String(row.host_id) } : {}),
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
      const existing = await this.env.CONCLAVE_DB.prepare(
        `SELECT * FROM realtime_events
         WHERE event_id = ?1 OR (workspace_id = ?2 AND idempotency_key = ?3)
         LIMIT 1`,
      )
        .bind(eventId, input.workspaceId, idempotencyKey)
        .first<Record<string, unknown>>();
      if (existing) {
        event = eventFromRow(existing);
      } else {
        event = await this.persistDurableEvent({
          ...input,
          eventId,
          idempotencyKey,
          occurredAt,
        });
        persisted = true;
      }
    } else {
      event = parseRealtimeEvent({
        eventId,
        type: input.type,
        version: "1.0",
        timestamp: occurredAt,
        workspaceId: input.workspaceId,
        ...(input.projectId ? { projectId: input.projectId } : {}),
        ...(input.chatId ? { chatId: input.chatId } : {}),
        ...(input.runId ? { runId: input.runId } : {}),
        ...(input.taskId ? { taskId: input.taskId } : {}),
        ...(input.attemptId ? { attemptId: input.attemptId } : {}),
        ...(input.assignmentId ? { assignmentId: input.assignmentId } : {}),
        ...(input.hostId ? { hostId: input.hostId } : {}),
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
  ): Promise<RealtimeEventEnvelope> {
    const cursor = await this.env.CONCLAVE_DB.prepare(
      `INSERT INTO realtime_event_cursors (workspace_id, next_sequence)
       VALUES (?1, 1)
       ON CONFLICT(workspace_id) DO UPDATE SET next_sequence = next_sequence + 1
       RETURNING next_sequence - 1 AS sequence`,
    )
      .bind(input.workspaceId)
      .first<{ sequence: number }>();
    if (!cursor) throw new Error("Could not allocate realtime event sequence");

    const event = parseRealtimeEvent({
      eventId: input.eventId,
      type: input.type,
      version: "1.0",
      timestamp: input.occurredAt,
      workspaceId: input.workspaceId,
      ...(input.projectId ? { projectId: input.projectId } : {}),
      ...(input.chatId ? { chatId: input.chatId } : {}),
      ...(input.runId ? { runId: input.runId } : {}),
      ...(input.taskId ? { taskId: input.taskId } : {}),
      ...(input.attemptId ? { attemptId: input.attemptId } : {}),
      ...(input.assignmentId ? { assignmentId: input.assignmentId } : {}),
      ...(input.hostId ? { hostId: input.hostId } : {}),
      sequence: cursor.sequence,
      payload: input.payload,
    });

    try {
      await this.env.CONCLAVE_DB.prepare(
        `INSERT INTO realtime_events
         (event_id, workspace_id, project_id, chat_id, run_id, task_id,
          attempt_id, assignment_id, host_id, sequence, event_type,
          payload_json, idempotency_key, occurred_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)`,
      )
        .bind(
          event.eventId,
          event.workspaceId,
          event.projectId ?? null,
          event.chatId ?? null,
          event.runId ?? null,
          event.taskId ?? null,
          event.attemptId ?? null,
          event.assignmentId ?? null,
          event.hostId ?? null,
          event.sequence,
          event.type,
          json(event.payload),
          input.idempotencyKey,
          event.timestamp,
        )
        .run();
    } catch (error) {
      const duplicate = await this.env.CONCLAVE_DB.prepare(
        `SELECT * FROM realtime_events
         WHERE event_id = ?1 OR (workspace_id = ?2 AND idempotency_key = ?3)
         LIMIT 1`,
      )
        .bind(input.eventId, input.workspaceId, input.idempotencyKey)
        .first<Record<string, unknown>>();
      if (duplicate) return eventFromRow(duplicate);
      throw error;
    }
    return event;
  }

  private async fanout(event: RealtimeEventEnvelope): Promise<number> {
    const gateway = this.env.CONCLAVE_REALTIME_GATEWAY;
    if (!gateway) return 0;
    let members = event.projectId
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
    if ((members.results ?? []).length === 0) {
      // Transitional fallback for v4 development databases. Production v5
      // fanout is derived from Project membership or Workspace ownership.
      members = await this.env.CONCLAVE_DB.prepare(
        `SELECT user_id FROM workspace_memberships
         WHERE workspace_id = ?1 AND status = 'active'`,
      )
        .bind(event.workspaceId)
        .all<{ user_id: string }>();
    }
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
