import { describe, expect, it } from "vitest";
import { gatewayFixture } from "./helpers/assignment-gateway.js";

const types = (messages: Array<{ type: string }>) =>
  messages.map((message) => message.type);

const queuedPayload = {
  snapshot: { workerTypeId: "chatgpt" },
  input: { objective: "queued while synchronizing" },
};

async function queued(initial = "created") {
  const f = await gatewayFixture(initial, { ready: false });
  f.sqlite
    .prepare(
      "UPDATE worker_assignments SET command_payload_json = ? WHERE id = 'A1'",
    )
    .run(JSON.stringify(queuedPayload));
  return f;
}

describe("Gateway Service readiness", () => {
  it("separates liveness from readiness for a connected, unsynchronized Service", async () => {
    const f = await queued();
    expect(await f.gatewayStatus()).toMatchObject({
      online: true,
      readyForAssignments: false,
      serviceState: "authenticated",
    });
    await f.send("workspace.sync.request", {});
    expect(await f.gatewayStatus()).toMatchObject({
      online: true,
      readyForAssignments: false,
      serviceState: "synchronizing",
    });
  });

  it("queues work durably for an unready Service instead of delivering it", async () => {
    const f = await queued();
    const response = await f.dispatch();
    expect(response.status).toBe(202);
    expect(await response.json()).toMatchObject({
      delivered: false,
      queued: true,
      deliveryState: "waiting_for_service_ready",
      acceptance: "none",
    });
    expect(f.status().status).toBe("created");
    expect(types(await f.outbound())).not.toContain("assignment.start");
  });

  it("flushes queued work exactly once when the Service reports ready", async () => {
    const f = await queued();
    await f.dispatch();
    await f.becomeReady();
    const sent = (await f.outbound()).filter(
      (message) => message.type === "assignment.start",
    );
    expect(sent).toHaveLength(1);
    expect(f.status().status).toBe("dispatched");
    // A redundant nudge or a second ready report sends nothing more.
    await f.gateway.fetch(
      new Request("https://gateway.internal/flush-queued", { method: "POST" }),
    );
    await f.send("workspace.readiness", {
      state: "ready",
      readyForAssignments: true,
      syncGeneration: 1,
    });
    expect(
      (await f.outbound()).filter((m) => m.type === "assignment.start"),
    ).toHaveLength(0);
  });

  it("delivers immediately to a ready Service", async () => {
    const f = await gatewayFixture("created");
    expect(await f.gatewayStatus()).toMatchObject({
      readyForAssignments: true,
      serviceState: "ready",
      syncGeneration: 1,
    });
    const response = await f.dispatch();
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      delivered: true,
      deliveryState: "queued",
    });
    expect(types(await f.outbound())).toContain("assignment.start");
  });

  it("does not trust a ready claim made before Cloud answered the sync request", async () => {
    const f = await queued();
    await f.send("workspace.readiness", {
      state: "ready",
      readyForAssignments: true,
      syncGeneration: 1,
    });
    expect((await f.gatewayStatus()).readyForAssignments).toBe(false);
  });

  it("stops accepting work when the Service pauses or drains, and resumes after", async () => {
    // Ready from the start; the payload is stored only after becoming ready so
    // the ready transition itself does not flush the assignment.
    const f = await gatewayFixture("created");
    f.sqlite
      .prepare(
        "UPDATE worker_assignments SET command_payload_json = ? WHERE id = 'A1'",
      )
      .run(JSON.stringify(queuedPayload));
    await f.send("workspace.readiness", {
      state: "paused",
      readyForAssignments: false,
      syncGeneration: 1,
      reason: "paused_by_user",
    });
    expect(await f.gatewayStatus()).toMatchObject({
      online: true,
      readyForAssignments: false,
      serviceState: "paused",
    });
    expect((await f.dispatch()).status).toBe(202);
    expect(f.status().status).toBe("created");
    await f.send("workspace.readiness", {
      state: "ready",
      readyForAssignments: true,
      syncGeneration: 1,
    });
    expect(types(await f.outbound())).toContain("assignment.start");
  });

  it("ignores a stale readiness report from before the latest sync", async () => {
    const f = await queued();
    await f.becomeReady(2);
    await f.send("workspace.readiness", {
      state: "draining",
      readyForAssignments: false,
      syncGeneration: 1,
    });
    expect(await f.gatewayStatus()).toMatchObject({
      readyForAssignments: true,
      syncGeneration: 2,
    });
  });

  it("treats a Service that publishes no readiness as ready after sync and inventory", async () => {
    const f = await queued();
    await f.send("workspace.sync.request", {});
    expect((await f.gatewayStatus()).readyForAssignments).toBe(false);
    await f.send("worker.inventory", { workers: [], fullSnapshot: true });
    expect(await f.gatewayStatus()).toMatchObject({
      readyForAssignments: true,
      serviceState: "ready",
    });
  });

  it("restores runtime identity and readiness after the Durable Object restarts", async () => {
    const f = await gatewayFixture("created");
    const restarted = f.restart();
    const status = (await (
      await restarted.fetch(new Request("https://gateway.internal/status"))
    ).json()) as Record<string, unknown>;
    expect(status).toMatchObject({
      online: true,
      workspaceRuntimeId: "RT",
      sessionId: f.sessionId,
      readyForAssignments: true,
      serviceState: "ready",
      syncGeneration: 1,
    });
  });

  it("does not restore readiness that belongs to a replaced session", async () => {
    const f = await gatewayFixture("created");
    const second = await f.gateway.fetch(
      new Request("https://gateway.internal/runtime/sessions", {
        method: "POST",
        headers: f.headers,
        body: JSON.stringify({
          workspaceRuntimeId: "RT",
          contractVersion: "1.0",
        }),
      }),
    );
    expect(second.status).toBe(200);
    // The replacement connection has not synchronized: not ready, and the
    // previous session's `ready` must not leak through.
    expect(await f.gatewayStatus()).toMatchObject({
      online: true,
      readyForAssignments: false,
      serviceState: "authenticated",
    });
    const restarted = f.restart();
    const status = (await (
      await restarted.fetch(new Request("https://gateway.internal/status"))
    ).json()) as Record<string, unknown>;
    expect(status).toMatchObject({
      readyForAssignments: false,
      serviceState: "authenticated",
    });
  });

  it("heals readiness from the heartbeat when a readiness message was lost", async () => {
    const f = await queued();
    await f.send("workspace.sync.request", {});
    expect((await f.gatewayStatus()).readyForAssignments).toBe(false);
    await f.send("workspace.heartbeat", {
      status: "online",
      readiness: {
        state: "ready",
        readyForAssignments: true,
        syncGeneration: 1,
      },
    });
    expect(await f.gatewayStatus()).toMatchObject({
      readyForAssignments: true,
      serviceState: "ready",
    });
  });

  it("publishes readiness to D1 as it changes", async () => {
    const f = await gatewayFixture("created");
    const row = f.sqlite
      .prepare(
        "SELECT state, ready_for_assignments AS ready, sync_generation AS generation, runtime_identity_id AS runtime FROM workspace_service_readiness WHERE workspace_id = 'WS'",
      )
      .get() as Record<string, unknown>;
    expect(row).toMatchObject({
      state: "ready",
      ready: 1,
      generation: 1,
      runtime: "RT",
    });
  });
  describe("long-poll fallback", () => {
    const pollRaw = (
      f: Awaited<ReturnType<typeof gatewayFixture>>,
      waitMs: number,
    ) =>
      f.gateway.fetch(
        new Request("https://gateway.internal/runtime/poll", {
          method: "POST",
          headers: f.headers,
          body: JSON.stringify({
            sessionId: f.sessionId,
            cursor: f.cursor(),
            waitMs,
          }),
        }),
      );

    it("returns a waiting poll as soon as a command is available", async () => {
      const f = await gatewayFixture("created");
      const startedAt = Date.now();
      const waiting = pollRaw(f, 30_000);
      await new Promise((resolve) => setTimeout(resolve, 20));
      const dispatched = await f.dispatch();
      expect(dispatched.status).toBe(200);
      const response = await waiting;
      const body = (await response.json()) as {
        events: Array<{ message: { type: string } }>;
        timedOut: boolean;
      };
      expect(Date.now() - startedAt).toBeLessThan(5_000);
      expect(body.timedOut).toBe(false);
      expect(body.events.map((event) => event.message.type)).toContain(
        "assignment.start",
      );
    });

    it("supersedes an older poll instead of rejecting the newer one", async () => {
      const f = await gatewayFixture("created");
      const first = pollRaw(f, 30_000);
      await new Promise((resolve) => setTimeout(resolve, 10));
      const second = pollRaw(f, 30_000);
      const firstResponse = await first;
      expect(firstResponse.status).toBe(200);
      expect(
        ((await firstResponse.json()) as { timedOut: boolean }).timedOut,
      ).toBe(true);
      await f.dispatch();
      const secondResponse = await second;
      expect(secondResponse.status).toBe(200);
      const body = (await secondResponse.json()) as {
        events: Array<{ message: { type: string } }>;
      };
      expect(
        body.events.filter(
          (event) => event.message.type === "assignment.start",
        ),
      ).toHaveLength(1);
    });
  });
});
