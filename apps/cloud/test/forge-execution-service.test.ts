import { describe, expect, it } from "vitest";
import {
  ConclaveForgeExecutionService,
  workStepSessionKey,
} from "../src/forge-execution.js";

interface ExecutionRow {
  readonly id: string;
  readonly runId: string;
  readonly executionKind: string;
  readonly externalId: string;
  status: string;
  resultArtifactId?: string;
  error?: string;
  updatedAt: string;
}

class MemoryD1 {
  readonly executions: ExecutionRow[] = [];

  async batch() {
    return [];
  }

  prepare(query: string) {
    let values: readonly unknown[] = [];
    const statement = {
      bind: (...next: unknown[]) => {
        values = next;
        return statement;
      },
      first: async <T>() => {
        const row = query.includes("WHERE external_id")
          ? this.executions.find((item) => item.externalId === values[0])
          : query.includes("WHERE run_id")
            ? this.executions.find(
                (item) =>
                  item.runId === values[0] && item.executionKind === values[1],
              )
            : undefined;
        return row ? this.toDatabaseRow(row) as T : null;
      },
      all: async <T>() => ({ results: [] as readonly T[] }),
      run: async () => {
        if (query.includes("INSERT INTO run_external_executions")) {
          this.executions.push({
            id: String(values[0]),
            runId: String(values[1]),
            executionKind: String(values[2]),
            externalId: String(values[3]),
            status: String(values[4]),
            updatedAt: String(values[5]),
          });
        }
        if (query.includes("UPDATE run_external_executions")) {
          const row = this.executions.find(
            (item) => item.externalId === values[4],
          );
          if (row) {
            row.status = String(values[0]);
            row.resultArtifactId = values[1] ? String(values[1]) : undefined;
            row.error = values[2] ? String(values[2]) : undefined;
            row.updatedAt = String(values[3]);
          }
        }
        return { success: true as const };
      },
    };
    return statement;
  }

  private toDatabaseRow(row: ExecutionRow): Record<string, unknown> {
    return {
      execution_id: row.externalId,
      run_id: row.runId,
      status: row.status,
      result_artifact_id: row.resultArtifactId ?? null,
      error: row.error ?? null,
      updated_at: row.updatedAt,
    };
  }
}

function service(db: MemoryD1): ConclaveForgeExecutionService {
  return new ConclaveForgeExecutionService({ CONCLAVE_DB: db });
}

describe("Work assignment execution service", () => {
  it("keeps Verify in a separate provider session from Implement", () => {
    const implement = workStepSessionKey({
      workBindingId: "implement",
      workstreamId: "workstream-1",
      workRequestId: "request-1",
      stepKind: "implement",
    });
    const verify = workStepSessionKey({
      workBindingId: "verify",
      workstreamId: "workstream-1",
      workRequestId: "request-1",
      stepKind: "verify",
    });
    expect(implement).toBe("work-request:request-1:implement");
    expect(verify).toBe("work-request:request-1:verify");
    expect(verify).not.toBe(implement);
  });

  it("keeps Direct durable across requests and isolates fresh retries", () => {
    const direct = workStepSessionKey({
      workBindingId: "direct",
      workstreamId: "workstream-1",
      workRequestId: "request-1",
      stepKind: "implement",
    });
    expect(
      workStepSessionKey({
        workBindingId: "direct",
        workstreamId: "workstream-1",
        workRequestId: "request-2",
        stepKind: "implement",
      }),
    ).toBe(direct);
    expect(
      workStepSessionKey({
        workBindingId: "direct",
        workstreamId: "workstream-1",
        workRequestId: "request-1",
        stepKind: "implement",
        retryStepKind: "implement",
        retrySessionStrategy: "fresh",
        retryNumber: 2,
      }),
    ).toBe(`${direct}:retry-fresh-2`);
  });

  it("requires a persisted Work Request and binding", async () => {
    const response = await service(new MemoryD1()).fetch(
      new Request("https://conclave.internal/execute", {
        method: "POST",
        body: JSON.stringify({ runId: "run-1" }),
      }),
      {} as ExecutionContext,
    );

    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toEqual({
      error: "work_request_required",
    });
  });

  it("recovers a terminal Work execution by its external execution ID", async () => {
    const db = new MemoryD1();
    db.executions.push({
      id: "row-1",
      runId: "run-1",
      executionKind: "direct:task-1:1",
      externalId: "execution-1",
      status: "completed",
      resultArtifactId: "artifact-1",
      updatedAt: "2026-10-02T00:00:00.000Z",
    });

    const response = await service(db).fetch(
      new Request("https://conclave.internal/status/execution-1"),
      {} as ExecutionContext,
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      executionId: "execution-1",
      runId: "run-1",
      status: "completed",
      resultArtifactId: "artifact-1",
    });
  });

  it("returns an existing Workflow step execution on replay", async () => {
    const db = new MemoryD1();
    db.executions.push({
      id: "row-1",
      runId: "run-1",
      executionKind: "direct:task-1:1",
      externalId: "execution-1",
      status: "started",
      updatedAt: "2026-10-02T00:00:00.000Z",
    });

    const response = await service(db).fetch(
      new Request("https://conclave.internal/execute", {
        method: "POST",
        body: JSON.stringify({
          runId: "run-1",
          taskId: "task-1",
          workRequestId: "request-1",
          workBindingId: "direct",
        }),
      }),
      { waitUntil: () => undefined } as unknown as ExecutionContext,
    );

    expect(response.status).toBe(202);
    await expect(response.json()).resolves.toMatchObject({
      executionId: "execution-1",
      runId: "run-1",
      status: "started",
    });
  });
});
