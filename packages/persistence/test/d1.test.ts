import { describe, expect, it } from "vitest";
import {
  D1GoalRepository,
  D1ProjectRepository,
  D1WorkerRepository,
  D1ExtensionRepository,
  D1WorkflowTemplateRepository,
  D1CredentialRepository,
  D1RetentionPolicyRepository,
  D1HumanApprovalRepository,
  D1OrganizationRepository,
  D1MembershipRepository,
  D1ProjectMembershipRepository,
  D1AuditLogRepository,
  D1EventRepository,
  D1ModelCallRepository,
  D1TaskDependencyRepository,
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

  it("reads projects and workers from their tenant tables", async () => {
    const project = await new D1ProjectRepository(
      new FakeDb([
        {
          id: "project-1",
          workspace_id: "workspace-1",
          name: "Forge",
          description: "Repository automation",
          repository_id: "repo-1",
          settings_json: '{"verification":"high"}',
          created_at: "now",
          updated_at: "now",
        },
      ]),
    ).get("project-1");
    expect(project).toMatchObject({
      id: "project-1",
      workspaceId: "workspace-1",
      repositoryId: "repo-1",
      settings: { verification: "high" },
    });

    const worker = await new D1WorkerRepository(
      new FakeDb([
        {
          id: "worker-1",
          workspace_id: "workspace-1",
          agent_id: "agent-1",
          plugin_id: "codex",
          plugin_version_policy: "1.x",
          name: "Codex",
          roles_json: '["implementation"]',
          capabilities_json: '["repository_write"]',
          config_json: '{"model":"local"}',
          secret_refs_json: "[]",
          billing_mode: "subscription",
          cost_metadata_json: "{}",
          independence_key: "agent-1:codex",
          concurrency_limit: 1,
          session_policy: "isolated_workspace",
          enabled: 1,
          status: "available",
          created_at: "now",
          updated_at: "now",
        },
      ]),
    ).get("worker-1");
    expect(worker).toMatchObject({
      id: "worker-1",
      workspaceId: "workspace-1",
      agentId: "agent-1",
      workerCatalogId: "codex",
      roles: ["implementation"],
      capabilities: ["repository_write"],
      billingMode: "subscription",
    });
  });

  it("reconstructs versioned extensions and workflow templates", async () => {
    const extension = await new D1ExtensionRepository(
      new FakeDb([
        {
          row_id: "workspace-1:codex:1.0.0",
          organization_id: "workspace-1",
          extension_id: "codex",
          kind: "agent",
          name: "Codex",
          version: "1.0.0",
          manifest_json: '{"permissions":["repo.read"]}',
          status: "active",
          created_at: "now",
          updated_at: "now",
        },
      ]),
    ).get("workspace-1:codex:1.0.0");
    expect(extension).toMatchObject({
      id: "workspace-1:codex:1.0.0",
      organizationId: "workspace-1",
      extensionId: "codex",
      version: "1.0.0",
      manifest: { permissions: ["repo.read"] },
    });

    const templates = await new D1WorkflowTemplateRepository(
      new FakeDb([
        [
          {
            row_id: "workspace-1:forge:1",
            organization_id: "workspace-1",
            template_id: "forge",
            name: "Forge",
            version: 1,
            template_json: '{"steps":["research"]}',
            status: "active",
            created_by_user_id: "user-1",
            created_at: "now",
            updated_at: "now",
          },
          {
            row_id: "workspace-1:forge:2",
            organization_id: "workspace-1",
            template_id: "forge",
            name: "Forge",
            version: 2,
            template_json: '{"steps":["research","review"]}',
            status: "active",
            created_by_user_id: "user-1",
            created_at: "now",
            updated_at: "now",
          },
        ],
      ]),
    ).listByOrganization("workspace-1");
    expect(templates.map((template) => template.version)).toEqual([1, 2]);
  });

  it("reads security-sensitive records from tenant tables", async () => {
    const credential = await new D1CredentialRepository(
      new FakeDb([
        {
          id: "credential-1",
          organization_id: "workspace-1",
          provider: "openai",
          key_id: "key-1",
          algorithm: "AES-GCM",
          iv: "iv",
          ciphertext: "ciphertext",
          created_at: "now",
          expires_at: null,
        },
      ]),
    ).get("workspace-1", "openai");
    expect(credential).toMatchObject({
      organizationId: "workspace-1",
      provider: "openai",
      algorithm: "AES-GCM",
    });

    const policy = await new D1RetentionPolicyRepository(
      new FakeDb([
        {
          id: "retention-1",
          organization_id: "workspace-1",
          audit_days: 30,
          artifact_days: 90,
          usage_days: 180,
          created_at: "now",
          updated_at: "now",
        },
      ]),
    ).get("workspace-1");
    expect(policy?.artifactDays).toBe(90);

    const approval = await new D1HumanApprovalRepository(
      new FakeDb([
        {
          id: "approval-1",
          organization_id: "workspace-1",
          run_id: "run-1",
          task_id: null,
          requested_by_user_id: "user-1",
          decided_by_user_id: null,
          prompt: "Deploy?",
          decision: "pending",
          requested_at: "now",
          decided_at: null,
        },
      ]),
    ).get("approval-1");
    expect(approval).toMatchObject({
      organizationId: "workspace-1",
      runId: "run-1",
      decision: "pending",
    });
  });

  it("reads collaboration and audit records from tenant tables", async () => {
    const organization = await new D1OrganizationRepository(
      new FakeDb([
        {
          id: "workspace-1",
          name: "Workspace",
          status: "active",
          created_at: "now",
          updated_at: "now",
        },
      ]),
    ).get("workspace-1");
    expect(organization).toMatchObject({
      id: "workspace-1",
      name: "Workspace",
      plan: "workspace",
    });

    const membership = await new D1MembershipRepository(
      new FakeDb([
        {
          workspace_id: "workspace-1",
          user_id: "user-1",
          role: "member",
          created_at: "now",
          updated_at: "now",
        },
      ]),
    ).get("workspace-1", "user-1");
    expect(membership).toMatchObject({
      organizationId: "workspace-1",
      userId: "user-1",
      role: "member",
    });

    const projectMemberships = await new D1ProjectMembershipRepository(
      new FakeDb([
        [
          {
            project_id: "project-1",
            user_id: "user-1",
            role: "collaborator",
            created_at: "now",
            updated_at: "now",
          },
        ],
      ]),
    ).listByProject("project-1");
    expect(projectMemberships[0]?.role).toBe("collaborator");

    const audit = await new D1AuditLogRepository(
      new FakeDb([
        [
          {
            id: "audit-1",
            workspace_id: "workspace-1",
            actor_type: "user",
            actor_id: "user-1",
            action: "run.pause",
            target_type: "run",
            target_id: "run-1",
            details_json: '{"outcome":"success"}',
            created_at: "now",
          },
        ],
      ]),
    ).listByOrganization("workspace-1");
    expect(audit[0]).toMatchObject({
      actorUserId: "user-1",
      resourceType: "run",
      action: "run.pause",
    });
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
      new FakeDb([
        { workspace_id: "workspace-1", project_id: "project-1" },
        [],
        [],
      ]),
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
      new FakeDb([
        { workspace_id: "workspace-1", project_id: "project-1" },
        [],
        [],
      ]),
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

  it("uses the relational task dependency table", async () => {
    const repository = new D1TaskDependencyRepository(
      new FakeDb([[], [{ task_id: "task-2", depends_on_task_id: "task-1" }]]),
    );
    await expect(
      repository.save({ taskId: "task-2", dependsOnTaskId: "task-1" }),
    ).resolves.toBeUndefined();
    await expect(repository.listByTask("task-2")).resolves.toEqual([
      { taskId: "task-2", dependsOnTaskId: "task-1" },
    ]);
  });
});
