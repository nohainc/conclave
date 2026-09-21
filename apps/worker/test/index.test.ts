import { describe, expect, it, vi } from "vitest";
import worker from "../src/index.js";

const workflowExecutions = new Map<string, string>();
const identityDb = {
  prepare(query: string) {
    let values: readonly unknown[] = [];
    return {
      bind(...next: unknown[]) {
        values = next;
        return this;
      },
      async first<T>() {
        if (query.includes("run_external_executions")) {
          const runId = String(values[0]);
          const workflowInstanceId = workflowExecutions.get(runId);
          return workflowInstanceId
            ? ({ workflow_instance_id: workflowInstanceId } as T)
            : null;
        }
        return null;
      },
      async all<T>() {
        return { results: [] as readonly T[] };
      },
      async run() {
        if (query.includes("run_external_executions")) {
          workflowExecutions.set(String(values[0]), String(values[1]));
        }
        return { success: true };
      },
    };
  },
  async batch() {
    return [];
  },
};

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
  CONCLAVE_ALLOW_ANONYMOUS_DEV: "true",
  CONCLAVE_RUN_WORKFLOW: workflowBinding,
  CONCLAVE_DB: identityDb,
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

  it("fails closed when production authentication is missing", async () => {
    const productionEnv = {
      ...env,
      CONCLAVE_ENVIRONMENT: "production",
      CONCLAVE_ALLOW_ANONYMOUS_DEV: undefined,
    } as unknown as Env;
    const response = await worker.fetch(
      new Request("https://conclave.test/api/runs", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          runId: "run-1",
          goalId: "goal-1",
          idempotencyKey: "key-1",
        }),
      }),
      productionEnv,
    );
    expect(response.status).toBe(401);

    const ciResponse = await worker.fetch(
      new Request("https://conclave.test/api/runs/run-1/ci-evidence", {
        method: "POST",
      }),
      productionEnv,
    );
    expect(ciResponse.status).toBe(401);
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
      id: "run-1",
      status: "waiting",
    });
    expect(workflowBinding.create).toHaveBeenCalledWith({
      id: "workflow-goal-1",
      params: {
        runId: "run-1",
        goalId: "goal-1",
        idempotencyKey: "goal-1",
        organizationId: "local-development",
      },
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
    expect(workflowBinding.get).toHaveBeenCalledWith("workflow-goal-1");

    const eventResponse = await worker.fetch(
      new Request("https://conclave.test/api/runs/run-1/events", {
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

    const forgeTerminal = {
      eventId: "forge-event-1",
      runId: "run-1",
      executionId: "forge-execution-1",
      status: "completed",
      resultArtifactId: "artifact-result-1",
    };
    const forgeResponse = await worker.fetch(
      new Request("https://conclave.test/api/runs/run-1/forge-events", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(forgeTerminal),
      }),
      env,
    );
    expect(forgeResponse.status).toBe(200);
    expect(instance.sendEvent).toHaveBeenCalledWith({
      type: "forge-terminal",
      payload: forgeTerminal,
    });

    await worker.fetch(
      new Request("https://conclave.test/api/runs/run-1/pause", {
        method: "POST",
      }),
      env,
    );
    await worker.fetch(
      new Request("https://conclave.test/api/runs/run-1/resume", {
        method: "POST",
      }),
      env,
    );
    const statusResponse = await worker.fetch(
      new Request("https://conclave.test/api/runs/run-1"),
      {
        ...env,
        CONCLAVE_RUN_WORKFLOW: {
          ...workflowBinding,
          get: vi.fn(async (id: string) => {
            expect(id).toBe("workflow-goal-1");
            return instance;
          }),
        },
      } as unknown as Env,
    );
    expect(await statusResponse.json()).toEqual({
      id: "run-1",
      workflowInstanceId: "workflow-goal-1",
      status: "waiting",
    });
    await worker.fetch(
      new Request("https://conclave.test/api/runs/run-1/restart", {
        method: "POST",
      }),
      env,
    );
    expect(instance.pause).toHaveBeenCalledOnce();
    expect(instance.resume).toHaveBeenCalledOnce();
    expect(instance.restart).toHaveBeenCalledOnce();

    const ciEvidence = {
      evidenceId: "ci-evidence-1",
      source: "github_actions",
      externalRunId: "github-100",
      revision: "abc123",
      workflow: "CI",
      conclusion: "success",
      checks: [
        {
          name: "TypeScript checks",
          status: "passed",
          command: "pnpm check",
          exitCode: 0,
          artifactIds: [],
        },
      ],
      smokeTests: ["Worker health"],
      healthChecks: ["/health returned 200"],
      observedAt: "2026-09-21T10:00:00.000Z",
    };
    const ciResponse = await worker.fetch(
      new Request("https://conclave.test/api/runs/run-1/ci-evidence", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(ciEvidence),
      }),
      env,
    );
    expect(ciResponse.status).toBe(200);
    expect(instance.sendEvent).toHaveBeenCalledWith({
      type: "ci-evidence",
      payload: ciEvidence,
    });
  });
});
