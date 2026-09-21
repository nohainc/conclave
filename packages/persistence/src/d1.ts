import type {
  ArtifactRecord,
  CompletionCriterionRecord,
  GoalRecord,
  RunEventRecord,
  RunRecord,
  TaskRecord,
} from "./index.js";

export interface D1Result<T> {
  readonly results?: readonly T[];
  readonly success?: boolean;
  readonly meta?: unknown;
}

export interface D1Statement {
  bind(...values: unknown[]): D1Statement;
  first<T = Record<string, unknown>>(): Promise<T | null>;
  all<T = Record<string, unknown>>(): Promise<D1Result<T>>;
  run(): Promise<D1Result<never>>;
}

export interface D1DatabaseLike {
  prepare(query: string): D1Statement;
  batch(
    statements: readonly D1Statement[],
  ): Promise<readonly D1Result<never>[]>;
}

function json<T>(value: T): string {
  return JSON.stringify(value);
}

function parse<T>(value: unknown, fallback: T): T {
  if (typeof value !== "string") return fallback;
  return JSON.parse(value) as T;
}

function dates(
  row: Record<string, unknown>,
): Pick<GoalRecord, "createdAt" | "updatedAt"> {
  return {
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}

export class D1GoalRepository {
  constructor(private readonly db: D1DatabaseLike) {}

  async get(id: string): Promise<GoalRecord | null> {
    const row = await this.db
      .prepare("SELECT * FROM goals WHERE id = ?1")
      .bind(id)
      .first();
    if (!row) return null;
    const criteria = await this.db
      .prepare(
        "SELECT * FROM completion_criteria WHERE goal_id = ?1 ORDER BY id",
      )
      .bind(id)
      .all<Record<string, unknown>>();
    return {
      id: String(row.id),
      projectId: String(row.project_id),
      originalMessage: String(row.original_message),
      objective: String(row.objective),
      constraints: parse(row.constraints_json, [] as string[]),
      completionCriteria: (criteria.results ?? []).map(toCriterion),
      verificationPolicy: parse(row.verification_policy_json, {}),
      status: String(row.status),
      ...dates(row),
    };
  }

  async save(goal: GoalRecord): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO goals (id, project_id, original_message, objective, constraints_json, completion_criteria_json, verification_policy_json, status, created_at, updated_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
      ON CONFLICT(id) DO UPDATE SET project_id=excluded.project_id, original_message=excluded.original_message, objective=excluded.objective, constraints_json=excluded.constraints_json, completion_criteria_json=excluded.completion_criteria_json, verification_policy_json=excluded.verification_policy_json, status=excluded.status, updated_at=excluded.updated_at`,
      )
      .bind(
        goal.id,
        goal.projectId,
        goal.originalMessage,
        goal.objective,
        json(goal.constraints),
        json(goal.completionCriteria.map((criterion) => criterion.description)),
        json(goal.verificationPolicy),
        goal.status,
        goal.createdAt,
        goal.updatedAt,
      )
      .run();
    await this.db.batch(
      goal.completionCriteria.map((criterion) =>
        this.db
          .prepare(
            `INSERT INTO completion_criteria (id, goal_id, description, verification_requirement, status, evidence_artifact_ids_json, verified_by_worker_id, verification_id, created_at, updated_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
      ON CONFLICT(goal_id, id) DO UPDATE SET description=excluded.description, verification_requirement=excluded.verification_requirement, status=excluded.status, evidence_artifact_ids_json=excluded.evidence_artifact_ids_json, verified_by_worker_id=excluded.verified_by_worker_id, verification_id=excluded.verification_id, updated_at=excluded.updated_at`,
          )
          .bind(
            criterion.id,
            goal.id,
            criterion.description,
            criterion.verificationRequirement,
            criterion.status,
            json(criterion.evidenceArtifactIds),
            criterion.verifiedByWorkerId,
            criterion.verificationId,
            criterion.createdAt,
            criterion.updatedAt,
          ),
      ),
    );
  }

  async listByProject(projectId: string): Promise<readonly GoalRecord[]> {
    const rows = await this.db
      .prepare("SELECT id FROM goals WHERE project_id = ?1 ORDER BY created_at")
      .bind(projectId)
      .all<{ id: string }>();
    return Promise.all(
      (rows.results ?? []).map((row) => this.get(row.id)),
    ).then((goals) =>
      goals.filter((goal): goal is GoalRecord => goal !== null),
    );
  }
}

function toCriterion(row: Record<string, unknown>): CompletionCriterionRecord {
  return {
    id: String(row.id),
    description: String(row.description),
    verificationRequirement: String(row.verification_requirement),
    status: String(row.status) as CompletionCriterionRecord["status"],
    evidenceArtifactIds: parse(row.evidence_artifact_ids_json, [] as string[]),
    verifiedByWorkerId:
      row.verified_by_worker_id === null
        ? null
        : String(row.verified_by_worker_id),
    verificationId:
      row.verification_id === null ? null : String(row.verification_id),
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}

export class D1RunRepository {
  constructor(private readonly db: D1DatabaseLike) {}
  async get(id: string): Promise<RunRecord | null> {
    const row = await this.db
      .prepare("SELECT * FROM runs WHERE id = ?1")
      .bind(id)
      .first();
    if (!row) return null;
    return {
      id: String(row.id),
      goalId: String(row.goal_id),
      parentRunId:
        row.parent_run_id === null ? null : String(row.parent_run_id),
      policySnapshot: parse(row.policy_snapshot_json, {}),
      currentPhaseId:
        row.current_phase_id === null ? null : String(row.current_phase_id),
      status: String(row.status),
      startedAt: row.started_at === null ? null : String(row.started_at),
      finishedAt: row.finished_at === null ? null : String(row.finished_at),
      ...dates(row),
    };
  }
  async save(run: RunRecord): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO runs (id, goal_id, parent_run_id, policy_snapshot_json, current_phase_id, status, started_at, finished_at, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10) ON CONFLICT(id) DO UPDATE SET status=excluded.status, current_phase_id=excluded.current_phase_id, started_at=excluded.started_at, finished_at=excluded.finished_at, updated_at=excluded.updated_at`,
      )
      .bind(
        run.id,
        run.goalId,
        run.parentRunId,
        json(run.policySnapshot),
        run.currentPhaseId,
        run.status,
        run.startedAt,
        run.finishedAt,
        run.createdAt,
        run.updatedAt,
      )
      .run();
  }
  async listByGoal(goalId: string): Promise<readonly RunRecord[]> {
    const rows = await this.db
      .prepare("SELECT id FROM runs WHERE goal_id = ?1 ORDER BY created_at")
      .bind(goalId)
      .all<{ id: string }>();
    return Promise.all(
      (rows.results ?? []).map((row) => this.get(row.id)),
    ).then((runs) => runs.filter((run): run is RunRecord => run !== null));
  }
}

export class D1TaskRepository {
  constructor(private readonly db: D1DatabaseLike) {}
  async get(id: string): Promise<TaskRecord | null> {
    const row = await this.db
      .prepare("SELECT * FROM tasks WHERE id = ?1")
      .bind(id)
      .first();
    return row ? toTask(row) : null;
  }
  async save(task: TaskRecord): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO tasks (id, phase_id, objective, role, capabilities_json, input_json, output_contract_json, status, requires_independent_verification, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11) ON CONFLICT(id) DO UPDATE SET objective=excluded.objective, role=excluded.role, capabilities_json=excluded.capabilities_json, input_json=excluded.input_json, output_contract_json=excluded.output_contract_json, status=excluded.status, requires_independent_verification=excluded.requires_independent_verification, updated_at=excluded.updated_at`,
      )
      .bind(
        task.id,
        task.phaseId,
        task.objective,
        task.role,
        json(task.capabilities),
        json(task.input),
        json(task.outputContract),
        task.status,
        task.requiresIndependentVerification ? 1 : 0,
        task.createdAt,
        task.updatedAt,
      )
      .run();
  }
  async listByPhase(phaseId: string): Promise<readonly TaskRecord[]> {
    const rows = await this.db
      .prepare("SELECT * FROM tasks WHERE phase_id = ?1 ORDER BY created_at")
      .bind(phaseId)
      .all();
    return (rows.results ?? []).map(toTask);
  }
}

function toTask(row: Record<string, unknown>): TaskRecord {
  return {
    id: String(row.id),
    phaseId: String(row.phase_id),
    objective: String(row.objective),
    role: String(row.role),
    capabilities: parse(row.capabilities_json, [] as string[]),
    input: parse(row.input_json, {}),
    outputContract: parse(row.output_contract_json, {}),
    status: String(row.status),
    requiresIndependentVerification:
      Number(row.requires_independent_verification) === 1,
    ...dates(row),
  };
}

export class D1EventRepository {
  constructor(private readonly db: D1DatabaseLike) {}
  async append(event: RunEventRecord): Promise<void> {
    await this.db
      .prepare(
        "INSERT INTO run_events (run_id, sequence, id, event_type, entity_type, entity_id, correlation_id, payload_json, occurred_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
      )
      .bind(
        event.runId,
        event.sequence,
        event.id,
        event.eventType,
        event.entityType,
        event.entityId,
        event.correlationId,
        json(event.payload),
        event.occurredAt,
      )
      .run();
  }
  async listByRun(runId: string): Promise<readonly RunEventRecord[]> {
    const rows = await this.db
      .prepare("SELECT * FROM run_events WHERE run_id = ?1 ORDER BY sequence")
      .bind(runId)
      .all();
    return (rows.results ?? []).map((row) => ({
      runId: String(row.run_id),
      sequence: Number(row.sequence),
      id: String(row.id),
      eventType: String(row.event_type),
      entityType: String(row.entity_type),
      entityId: String(row.entity_id),
      correlationId: String(row.correlation_id),
      payload: parse(row.payload_json, {}),
      occurredAt: String(row.occurred_at),
    }));
  }
}

export interface R2ObjectLike {
  readonly body: ReadableStream<Uint8Array>;
  readonly size: number;
  readonly httpMetadata?: { readonly contentType?: string };
}
export interface R2BucketLike {
  put(
    key: string,
    value: ArrayBuffer | ArrayBufferView | ReadableStream | string,
    options?: { httpMetadata?: { contentType?: string } },
  ): Promise<unknown>;
  get(key: string): Promise<R2ObjectLike | null>;
}

export class R2ArtifactStore {
  readonly kind = "r2" as const;
  constructor(
    private readonly bucket: R2BucketLike,
    private readonly bucketName: string,
  ) {}
  async put(
    key: string,
    content: Uint8Array,
    mediaType: string,
  ): Promise<{
    readonly kind: "r2";
    readonly bucket: string;
    readonly key: string;
    readonly sizeBytes: number;
  }> {
    await this.bucket.put(key, content, {
      httpMetadata: { contentType: mediaType },
    });
    return {
      kind: "r2",
      bucket: this.bucketName,
      key,
      sizeBytes: content.byteLength,
    };
  }
  async get(reference: {
    readonly kind: "r2";
    readonly bucket: string;
    readonly key: string;
  }): Promise<Uint8Array | null> {
    if (reference.bucket !== this.bucketName) return null;
    const object = await this.bucket.get(reference.key);
    return object
      ? new Uint8Array(await new Response(object.body).arrayBuffer())
      : null;
  }
}

export class D1ArtifactRepository {
  constructor(private readonly db: D1DatabaseLike) {}
  async get(id: string): Promise<ArtifactRecord | null> {
    const row = await this.db
      .prepare("SELECT * FROM artifacts WHERE id = ?1")
      .bind(id)
      .first();
    return row ? toArtifact(row) : null;
  }
  async save(record: ArtifactRecord): Promise<void> {
    const payload =
      record.payload.kind === "inline"
        ? {
            storageKind: "inline",
            inlinePayload: record.payload.content,
            bucket: null,
            key: null,
          }
        : {
            storageKind: "r2",
            inlinePayload: null,
            bucket: record.payload.bucket,
            key: record.payload.key,
          };
    await this.db
      .prepare(
        "INSERT INTO artifacts (id, run_id, task_id, attempt_id, media_type, storage_kind, inline_payload, r2_bucket, r2_key, content_digest, size_bytes, provenance_json, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
      )
      .bind(
        record.id,
        record.runId,
        record.taskId,
        record.attemptId,
        record.mediaType,
        payload.storageKind,
        payload.inlinePayload,
        payload.bucket,
        payload.key,
        record.contentDigest,
        record.sizeBytes,
        json(record.provenance),
        record.createdAt,
      )
      .run();
  }
  async listByRun(runId: string): Promise<readonly ArtifactRecord[]> {
    const rows = await this.db
      .prepare("SELECT * FROM artifacts WHERE run_id = ?1 ORDER BY created_at")
      .bind(runId)
      .all();
    return (rows.results ?? []).map(toArtifact);
  }
}

function toArtifact(row: Record<string, unknown>): ArtifactRecord {
  return {
    id: String(row.id),
    runId: String(row.run_id),
    taskId: row.task_id === null ? null : String(row.task_id),
    attemptId: row.attempt_id === null ? null : String(row.attempt_id),
    mediaType: String(row.media_type),
    payload:
      row.storage_kind === "inline"
        ? { kind: "inline", content: String(row.inline_payload) }
        : {
            kind: "r2",
            bucket: String(row.r2_bucket),
            key: String(row.r2_key),
            sizeBytes: Number(row.size_bytes),
          },
    contentDigest: String(row.content_digest),
    sizeBytes: Number(row.size_bytes),
    provenance: parse(row.provenance_json, {}),
    createdAt: String(row.created_at),
  };
}
