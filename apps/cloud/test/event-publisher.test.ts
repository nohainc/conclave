import { describe, expect, it } from "vitest";
import {
  CloudEventPublisher,
  type EventPublisherEnv,
} from "../src/event-publisher.js";

function createHarness(options: { duplicate?: boolean } = {}) {
  let nextSequence = 0;
  let insertCount = 0;
  let fanoutCount = 0;
  let stored: Record<string, unknown> | undefined = options.duplicate
    ? {
        event_id: "event-existing",
        workspace_id: "workspace-1",
        chat_id: "chat-1",
        sequence: 7,
        event_type: "chat.message.created",
        payload_json: JSON.stringify({ entityId: "message-1" }),
        occurred_at: "2026-09-23T00:00:00.000Z",
      }
    : undefined;
  const db = {
    prepare(query: string) {
      return {
        bind(...args: unknown[]) {
          return {
            async first<T>() {
              if (query.includes("FROM realtime_events")) {
                return (options.duplicate ? stored : undefined) as T | null;
              }
              if (query.includes("realtime_event_cursors")) {
                nextSequence += 1;
                return { sequence: nextSequence } as T;
              }
              return null;
            },
            async all<T>() {
              if (query.includes("workspace_memberships")) {
                return {
                  results: [{ user_id: "user-1" }, { user_id: "user-2" }],
                } as T;
              }
              return { results: [] } as T;
            },
            async run() {
              if (query.includes("INSERT INTO realtime_events")) {
                insertCount += 1;
                stored = {
                  event_id: args[0],
                  workspace_id: args[1],
                  project_id: args[2],
                  chat_id: args[3],
                  run_id: args[4],
                  task_id: args[5],
                  attempt_id: args[6],
                  assignment_id: args[7],
                  host_id: args[8],
                  sequence: args[9],
                  event_type: args[10],
                  payload_json: args[11],
                  idempotency_key: args[12],
                  occurred_at: args[13],
                };
              }
              return { success: true };
            },
          };
        },
      };
    },
  } as unknown as D1Database;
  const gateway = {
    getByName() {
      return {
        async fetch() {
          fanoutCount += 1;
          return new Response(null, { status: 200 });
        },
      };
    },
  } as unknown as DurableObjectNamespace;
  return {
    env: {
      CONCLAVE_DB: db,
      CONCLAVE_REALTIME_GATEWAY: gateway,
    } satisfies EventPublisherEnv,
    get insertCount() {
      return insertCount;
    },
    get fanoutCount() {
      return fanoutCount;
    },
  };
}

const baseEvent = {
  type: "chat.message.created",
  workspaceId: "workspace-1",
  chatId: "chat-1",
  payload: { entityId: "message-1", summary: "hello" },
};

describe("Cloud event publisher", () => {
  it("persists durable events before fanning out to Workspace members", async () => {
    const harness = createHarness();
    const result = await new CloudEventPublisher(harness.env).publish({
      ...baseEvent,
      idempotencyKey: "message-1",
    });

    expect(result.persisted).toBe(true);
    expect(result.event.sequence).toBe(1);
    expect(result.deliveredSubscribers).toBe(2);
    expect(harness.insertCount).toBe(1);
    expect(harness.fanoutCount).toBe(2);
  });

  it("does not write ephemeral events but still attempts fanout", async () => {
    const harness = createHarness();
    const result = await new CloudEventPublisher(harness.env).publish({
      ...baseEvent,
      type: "assignment.progress",
      durable: false,
      payload: { entityId: "assignment-1", percentage: 50 },
    });

    expect(result.persisted).toBe(false);
    expect(result.event.sequence).toBe(0);
    expect(harness.insertCount).toBe(0);
    expect(harness.fanoutCount).toBe(2);
  });

  it("returns safely when a subscriber is disconnected", async () => {
    const harness = createHarness();
    const namespace = harness.env.CONCLAVE_REALTIME_GATEWAY as unknown as {
      getByName: () => { fetch: () => Promise<Response> };
    };
    let calls = 0;
    namespace.getByName = () => ({
      fetch: async () => {
        calls += 1;
        if (calls === 1) throw new Error("socket closed");
        return new Response(null, { status: 200 });
      },
    });

    const result = await new CloudEventPublisher(harness.env).publish({
      ...baseEvent,
    });
    expect(result.deliveredSubscribers).toBe(1);
  });

  it("reuses an existing durable event for duplicate idempotency keys", async () => {
    const harness = createHarness({ duplicate: true });
    const result = await new CloudEventPublisher(harness.env).publish({
      ...baseEvent,
      eventId: "event-existing",
      idempotencyKey: "message-1",
    });
    expect(result.persisted).toBe(false);
    expect(harness.insertCount).toBe(0);
    expect(result.event.eventId).toBe("event-existing");
  });
});
