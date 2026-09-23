import { describe, expect, it } from "vitest";
import {
  ConclaveForgeExecutionService,
  readExecutionContext,
} from "../src/forge-execution.js";

class MemoryD1 {
  readonly records = new Map<string, string>();
  readonly contextQueries: string[] = [];
  contextRow: Record<string, unknown> | null = null;

  prepare(query: string) {
    let values: readonly unknown[] = [];
    const statement = {
      bind: (...next: unknown[]) => {
        values = next;
        return statement;
      },
      first: async <T>() => {
        if (query.includes("FROM projects")) {
          this.contextQueries.push(query);
          return this.contextRow as T;
        }
        if (
          query.includes("FROM forge_executions") &&
          query.includes("WHERE run_id")
        ) {
          for (const record of this.records.values()) {
            const parsed = JSON.parse(record) as {
              executionId: string;
              runId: string;
            };
            if (parsed.runId === String(values[0])) {
              return {
                execution_id: parsed.executionId,
                run_id: parsed.runId,
                workspace_id: null,
                status: "started",
                result_artifact_id: null,
                error: null,
                updated_at: "2026-09-22T00:00:00.000Z",
              } as T;
            }
          }
          return null;
        }
        if (
          !query.includes("FROM persistence_records") &&
          !query.includes("FROM forge_executions")
        )
          return null;
        const record = this.records.get(String(values[0]));
        if (!record) return null;
        if (query.includes("FROM forge_executions")) {
          const parsed = JSON.parse(record) as {
            executionId: string;
            runId: string;
            status: string;
            resultArtifactId?: string;
            error?: string;
            updatedAt: string;
          };
          return {
            execution_id: parsed.executionId,
            run_id: parsed.runId,
            status: parsed.status,
            result_artifact_id: parsed.resultArtifactId ?? null,
            error: parsed.error ?? null,
            updated_at: parsed.updatedAt,
          } as T;
        }
        return { record_json: record } as T;
      },
      all: async <T>() => ({ results: [] as readonly T[] }),
      run: async () => {
        if (query.includes("INSERT INTO forge_executions")) {
          this.records.set(
            String(values[0]),
            JSON.stringify({
              executionId: String(values[0]),
              runId: String(values[1]),
              workspaceId: values[2] ?? null,
              status: String(values[3]),
              updatedAt: String(values[4]),
            }),
          );
        }
        return { success: true as const };
      },
    };
    return statement;
  }

  async batch() {
    return [];
  }
}

function service(db: MemoryD1): ConclaveForgeExecutionService {
  return new ConclaveForgeExecutionService({
    CONCLAVE_DB: db,
    CONCLAVE_ARTIFACTS: {} as R2Bucket,
  });
}

describe("durable Forge execution service", () => {
  it("rejects a domain run that belongs to another Goal", async () => {
    const db = new MemoryD1();
    db.contextRow = {
      project_id: "project-1",
      repository_id: "repo-1",
      goal_id: "goal-1",
      run_goal_id: "goal-other",
      run_project_id: "project-1",
    };

    await expect(
      readExecutionContext(
        { CONCLAVE_DB: db } as never,
        {
          runId: "run-1",
          goalId: "goal-1",
          organizationId: "org-1",
          projectId: "project-1",
          repositoryId: "repo-1",
        },
        "execution-1",
      ),
    ).rejects.toThrow("Run does not belong to the requested Goal");
    expect(db.contextQueries[0]).toContain("p.workspace_id = ?3");
  });

  it("rejects a repository override that is not the Project repository", async () => {
    const db = new MemoryD1();
    db.contextRow = {
      project_id: "project-1",
      repository_id: "repo-1",
      goal_id: "goal-1",
      run_goal_id: null,
      run_project_id: null,
    };

    await expect(
      readExecutionContext(
        { CONCLAVE_DB: db } as never,
        {
          runId: "run-1",
          goalId: "goal-1",
          organizationId: "org-1",
          projectId: "project-1",
          repositoryId: "repo-other",
        },
        "execution-1",
      ),
    ).rejects.toThrow("Forge repository does not match the Project repository");
  });

  it("recovers a persisted terminal execution by execution ID", async () => {
    const db = new MemoryD1();
    db.records.set(
      "execution-1",
      JSON.stringify({
        executionId: "execution-1",
        runId: "run-1",
        status: "completed",
        resultArtifactId: "artifact-1",
        updatedAt: "2026-09-22T00:00:00.000Z",
      }),
    );

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

  it("rejects execution intake without a domain run ID", async () => {
    const response = await service(new MemoryD1()).fetch(
      new Request("https://conclave.internal/execute", {
        method: "POST",
        body: JSON.stringify({}),
      }),
      {} as ExecutionContext,
    );

    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toEqual({
      error: "run_id_required",
    });
  });

  it("returns the persisted execution for a retried domain run", async () => {
    const db = new MemoryD1();
    db.records.set(
      "execution-1",
      JSON.stringify({
        executionId: "execution-1",
        runId: "run-1",
        status: "started",
        updatedAt: "2026-09-22T00:00:00.000Z",
      }),
    );
    const response = await service(db).fetch(
      new Request("https://conclave.internal/execute", {
        method: "POST",
        body: JSON.stringify({ runId: "run-1" }),
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

  it("accepts direct Host Gateway execution without an internal HTTP API", async () => {
    const db = new MemoryD1();
    const gateway = {} as DurableObjectNamespace;
    const response = await new ConclaveForgeExecutionService({
      CONCLAVE_DB: db,
      CONCLAVE_ARTIFACTS: {} as R2Bucket,
      CONCLAVE_HOST_GATEWAY: gateway,
    }).fetch(
      new Request("https://conclave.internal/execute", {
        method: "POST",
        body: JSON.stringify({ runId: "run-1" }),
      }),
      { waitUntil: () => undefined } as unknown as ExecutionContext,
    );

    expect(response.status).toBe(202);
  });
});
