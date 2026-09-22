import { describe, expect, it } from "vitest";
import {
  D1GoalRepository,
  D1EventRepository,
  D1ModelCallRepository,
  D1RunRepository,
  R2ArtifactStore,
  ThresholdArtifactStore,
  type D1DatabaseLike,
  type D1Statement,
} from "../src/index.js";

class FakeStatement implements D1Statement {
  constructor(private readonly result: unknown) {}
  bind(...values: unknown[]): D1Statement {
    void values;
    return this;
  }
  async first<T>(): Promise<T | null> {
    return (this.result ?? null) as T | null;
  }
  async all<T>(): Promise<{ results: readonly T[] }> {
    return { results: (this.result ?? []) as readonly T[] };
  }
  async run(): Promise<{ success: boolean }> {
    return { success: true };
  }
}

class FakeDb implements D1DatabaseLike {
  constructor(private readonly responses: readonly unknown[]) {}
  private cursor = 0;
  prepare(query: string): D1Statement {
    void query;
    return new FakeStatement(this.responses[this.cursor++]);
  }
  async batch(): Promise<readonly { success: boolean }[]> {
    return [];
  }
}

describe("Cloudflare persistence adapters", () => {
  it("reconstructs structured criteria from D1", async () => {
    const repository = new D1GoalRepository(
      new FakeDb([
        {
          id: "goal-1",
          project_id: "project-1",
          original_message: "m",
          objective: "o",
          constraints_json: '["c"]',
          verification_policy_json: "{}",
          status: "running",
          created_at: "now",
          updated_at: "now",
        },
        [
          {
            id: "criterion-1",
            description: "Tests pass",
            verification_requirement: "executable_check",
            status: "pending",
            evidence_artifact_ids_json: "[]",
            verified_by_worker_id: null,
            verification_id: null,
            created_at: "now",
            updated_at: "now",
          },
        ],
      ]),
    );
    const goal = await repository.get("goal-1");
    expect(goal?.completionCriteria[0]?.description).toBe("Tests pass");
    expect(goal?.completionCriteria[0]?.verificationRequirement).toBe(
      "executable_check",
    );
  });

  it("resolves tenant scope before saving Goals and Runs", async () => {
    const goalRepository = new D1GoalRepository(
      new FakeDb([{ workspace_id: "workspace-1" }, null]),
    );
    await expect(
      goalRepository.save({
        id: "goal-1",
        projectId: "project-1",
        originalMessage: "Fix it",
        objective: "Fix it",
        constraints: [],
        completionCriteria: [],
        verificationPolicy: {},
        status: "ready",
        createdAt: "now",
        updatedAt: "now",
      }),
    ).resolves.toBeUndefined();

    const runRepository = new D1RunRepository(
      new FakeDb([
        { workspace_id: "workspace-1", project_id: "project-1" },
        null,
      ]),
    );
    await expect(
      runRepository.save({
        id: "run-1",
        goalId: "goal-1",
        workflowInstanceId: null,
        parentRunId: null,
        policySnapshot: {},
        currentPhaseId: null,
        status: "running",
        startedAt: "now",
        finishedAt: null,
        createdAt: "now",
        updatedAt: "now",
      }),
    ).resolves.toBeUndefined();
  });

  it("reads ordered run events and stores large payloads in R2", async () => {
    const eventRepository = new D1EventRepository(
      new FakeDb([
        [
          {
            run_id: "run-1",
            sequence: 1,
            id: "event-1",
            event_type: "RunStarted",
            entity_type: "run",
            entity_id: "run-1",
            correlation_id: "run-1",
            payload_json: '{"ok":true}',
            occurred_at: "now",
          },
        ],
      ]),
    );
    expect((await eventRepository.listByRun("run-1"))[0]?.payload).toEqual({
      ok: true,
    });
    const bytes = new TextEncoder().encode("artifact");
    const bucket = {
      put: async () => undefined,
      get: async () => ({
        body: new Response(bytes).body!,
        size: bytes.byteLength,
      }),
    };
    const store = new R2ArtifactStore(bucket, "artifacts");
    const reference = await store.put("run-1/a", bytes, "text/plain");
    expect(reference).toMatchObject({
      kind: "r2",
      bucket: "artifacts",
      key: "run-1/a",
    });
    expect(
      new TextDecoder().decode(
        (await store.get(reference)) ?? new Uint8Array(),
      ),
    ).toBe("artifact");
  });

  it("appends events to the tenant-scoped events table", async () => {
    const eventRepository = new D1EventRepository(
      new FakeDb([{ workspace_id: "workspace-1" }, []]),
    );
    await expect(
      eventRepository.append({
        runId: "run-1",
        sequence: 1,
        id: "event-1",
        eventType: "RunStarted",
        entityType: "run",
        entityId: "run-1",
        correlationId: "run-1",
        payload: { repositoryId: "repo-1" },
        occurredAt: "now",
      }),
    ).resolves.toBeUndefined();
  });

  it("keeps small artifacts inline and promotes larger artifacts to R2", async () => {
    const uploads: string[] = [];
    const store = new ThresholdArtifactStore(4, {
      put: async (key, content, mediaType) => {
        uploads.push(`${key}:${mediaType}:${content.byteLength}`);
        return {
          kind: "r2",
          bucket: "artifacts",
          key,
          sizeBytes: content.byteLength,
        };
      },
    });
    const base = {
      id: "artifact-1",
      runId: "run-1",
      taskId: null,
      attemptId: null,
      mediaType: "text/plain",
      contentDigest: "digest",
      provenance: {},
      createdAt: "now",
    } as const;

    const inline = await store.persist(base, "1234");
    const external = await store.persist(
      { ...base, id: "artifact-2" },
      "12345",
    );

    expect(inline.payload).toEqual({ kind: "inline", content: "1234" });
    expect(external.payload).toMatchObject({
      kind: "r2",
      key: "run-1/artifact-2",
    });
    expect(uploads).toEqual(["run-1/artifact-2:text/plain:5"]);
  });

  it("persists and reconstructs tenant-scoped model calls", async () => {
    const repository = new D1ModelCallRepository(
      new FakeDb([{ workspace_id: "workspace-1" }, []]),
    );
    const call = {
      id: "call-1",
      attemptId: "attempt-1",
      workerId: "worker-1",
      connectionId: "connection-1",
      provider: "codex",
      model: "codex-local",
      requestArtifactId: null,
      responseArtifactId: "artifact-1",
      status: "completed",
      inputTokens: 12,
      outputTokens: 8,
      startedAt: "2026-09-22T00:00:00.000Z",
      finishedAt: "2026-09-22T00:00:01.000Z",
    } as const;
    await expect(repository.save(call)).resolves.toBeUndefined();

    const listed = await new D1ModelCallRepository(
      new FakeDb([
        [
          {
            ...call,
            attempt_id: call.attemptId,
            worker_id: call.workerId,
            connection_id: call.connectionId,
            request_artifact_id: null,
            response_artifact_id: call.responseArtifactId,
            input_tokens: call.inputTokens,
            output_tokens: call.outputTokens,
            started_at: call.startedAt,
            finished_at: call.finishedAt,
          },
        ],
      ]),
    ).listByAttempt("attempt-1");
    expect(listed).toEqual([call]);
  });
});
