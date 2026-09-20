import { describe, expect, it, vi } from "vitest";
import worker from "../src/index.js";

const instance = {
  id: "run-key-1",
  status: vi.fn(async () => ({ status: "waiting" })),
  pause: vi.fn(async () => undefined),
  resume: vi.fn(async () => undefined),
  restart: vi.fn(async () => undefined),
  sendEvent: vi.fn(async () => undefined),
};

const workflowBinding = {
  create: vi.fn(async () => instance),
  get: vi.fn(async () => instance),
};

const env = {
  CONCLAVE_ENVIRONMENT: "development",
  CONCLAVE_RUN_WORKFLOW: workflowBinding,
} as unknown as Env;

describe("Worker smoke tests", () => {
  it("returns a health response", async () => {
    const response = await worker.fetch(
      new Request("https://conclave.test/health"),
      env,
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      environment: "development",
    });
  });

  it("returns not found for unknown routes", async () => {
    const response = await worker.fetch(
      new Request("https://conclave.test/unknown"),
      env,
    );

    expect(response.status).toBe(404);
  });

  it("creates an idempotent durable run and sends control events", async () => {
    const response = await worker.fetch(
      new Request("https://conclave.test/api/runs", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "idempotency-key": "goal-1",
        },
        body: JSON.stringify({ runId: "run-1", goalId: "goal-1" }),
      }),
      env,
    );
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({
      id: "run-key-1",
      status: "waiting",
    });
    expect(workflowBinding.create).toHaveBeenCalledWith({
      id: "run-goal-1",
      params: { runId: "run-1", goalId: "goal-1", idempotencyKey: "goal-1" },
    });

    workflowBinding.create.mockRejectedValueOnce(new Error("already exists"));
    const duplicate = await worker.fetch(
      new Request("https://conclave.test/api/runs", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "idempotency-key": "goal-1",
        },
        body: JSON.stringify({ runId: "run-1", goalId: "goal-1" }),
      }),
      env,
    );
    expect(duplicate.status).toBe(202);
    expect(workflowBinding.get).toHaveBeenCalledWith("run-goal-1");

    const eventResponse = await worker.fetch(
      new Request("https://conclave.test/api/runs/run-goal-1/events", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          type: "run-control",
          payload: { eventId: "event-1", action: "continue" },
        }),
      }),
      env,
    );
    expect(eventResponse.status).toBe(200);
    expect(instance.sendEvent).toHaveBeenCalledWith({
      type: "run-control",
      payload: { eventId: "event-1", action: "continue" },
    });

    await worker.fetch(
      new Request("https://conclave.test/api/runs/run-goal-1/pause", {
        method: "POST",
      }),
      env,
    );
    await worker.fetch(
      new Request("https://conclave.test/api/runs/run-goal-1/resume", {
        method: "POST",
      }),
      env,
    );
    expect(instance.pause).toHaveBeenCalledOnce();
    expect(instance.resume).toHaveBeenCalledOnce();
  });
});
