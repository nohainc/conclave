import { describe, expect, it } from "vitest";
import { RealtimeGateway } from "../src/realtime-gateway.js";
import { BoundedRealtimeQueue } from "../src/realtime-queue.js";
import type { RealtimeEventEnvelope } from "@conclave/protocol";

function harness(member = true) {
  const frames: Record<string, unknown>[] = [];
  const socket = {
    readyState: 1,
    bufferedAmount: 0,
    send(text: string) {
      frames.push(JSON.parse(text));
    },
    close() {
      frames.push({ type: "closed" });
    },
  };
  const cursors = new Map<string, number>();
  const db = {
    prepare(query: string) {
      return {
        bind() {
          return this;
        },
        async first() {
          return query.includes("FROM users")
            ? { status: "active" }
            : member && query.includes("space_memberships")
              ? { member: 1 }
              : null;
        },
      };
    },
  };
  const gateway = new RealtimeGateway(
    {} as never,
    { CONCLAVE_DB: db } as never,
  );
  const clients = Reflect.get(gateway, "clients") as Map<string, unknown>;
  clients.set("client", {
    socket,
    identity: { userId: "owner" },
    subscriptions: new Map([["user", { kind: "user" }]]),
    lastDurableSequences: cursors,
    queue: new BoundedRealtimeQueue(),
    flushScheduled: false,
  });
  const publish = (event: RealtimeEventEnvelope) =>
    gateway.fetch(
      new Request("https://realtime.internal/publish", {
        method: "POST",
        body: JSON.stringify(event),
      }),
    );
  const event = (
    kind: "space" | "execution_workspace",
    sequence: number,
  ): RealtimeEventEnvelope => ({
    eventId: `${kind}-${sequence}`,
    timestamp: "2026-10-06T00:00:00.000Z",
    sequence,
    payload: { entityId: "same" },
    ...(kind === "space"
      ? {
          type: "space.updated",
          version: "1.1",
          spaceId: "same",
          stream: { kind, id: "same" },
        }
      : { type: "run.completed", version: "1.0", workspaceId: "same" }),
  });
  return { frames, cursors, publish, event, clients };
}

describe("durable stream delivery", () => {
  it("isolates execution and Space sequences, scopes gaps, and never regresses cursors", async () => {
    const f = harness();
    for (const event of [
      f.event("execution_workspace", 1),
      f.event("space", 1),
      f.event("execution_workspace", 2),
    ])
      expect((await f.publish(event)).ok).toBe(true);
    expect(f.frames.filter((frame) => frame.type === "event")).toHaveLength(3);
    expect(f.frames.some((frame) => frame.type === "reconnect.required")).toBe(
      false,
    );
    await f.publish(f.event("space", 3));
    expect(f.frames.at(-1)).toMatchObject({
      type: "reconnect.required",
      scope: { kind: "space", spaceId: "same" },
      stream: { kind: "space", id: "same" },
      lastDurableSequence: 1,
      nextSequence: 3,
    });
    expect(f.frames.at(-1)).not.toHaveProperty("workspaceId");
    await f.publish(f.event("space", 2));
    expect(f.cursors.get('["space","same"]')).toBe(3);
    expect(f.cursors.get('["execution_workspace","same"]')).toBe(2);
    await f.publish(f.event("execution_workspace", 4));
    expect(f.frames.at(-1)).toMatchObject({
      type: "reconnect.required",
      workspaceId: "same",
      stream: { kind: "execution_workspace", id: "same" },
    });
  });
  it("does not deliver a live Space signal to a removed member on user scope", async () => {
    const f = harness(false);
    await f.publish(f.event("space", 1));
    expect(f.frames).toHaveLength(0);
  });
  it("delivers Space deletion to an active user after its focused membership disappears", async () => {
    const f = harness();
    const client = f.clients.get("client") as {
      subscriptions: Map<string, unknown>;
    };
    client.subscriptions.set("space", { kind: "space", spaceId: "same" });
    const event = { ...f.event("space", 1), type: "space.deleted" };
    expect((await f.publish(event)).ok).toBe(true);
    expect(f.frames.at(-1)).toMatchObject({
      type: "event",
      event: { type: "space.deleted" },
    });
    expect(client.subscriptions.has("space")).toBe(false);
  });
});
