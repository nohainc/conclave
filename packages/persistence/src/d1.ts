import type {
  ArtifactRecord,
  CompletionCriterionRecord,
  FindingRecord,
  GoalRecord,
  JsonValue,
  AttemptRecord,
  ModelCallRecord,
  PhaseRecord,
  RunEventRecord,
  RunRecord,
  TaskDependencyRecord,
  TaskRecord,
  UsageRecord,
  VerificationRecord,
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

function jsonObject(value: JsonValue): Record<string, JsonValue> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, JsonValue>)
    : {};
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
    const project = await this.db
      .prepare("SELECT workspace_id FROM projects WHERE id = ?1")
      .bind(goal.projectId)
      .first<{ workspace_id: string }>();
    if (!project?.workspace_id) {
      throw new Error(
        `Cannot save Goal for unknown Project: ${goal.projectId}`,
      );
    }
    await this.db
      .prepare(
        `INSERT INTO goals (id, workspace_id, project_id, original_message, objective, constraints_json, completion_criteria_json, verification_policy_json, status, created_at, updated_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
      ON CONFLICT(id) DO UPDATE SET project_id=excluded.project_id, original_message=excluded.original_message, objective=excluded.objective, constraints_json=excluded.constraints_json, completion_criteria_json=excluded.completion_criteria_json, verification_policy_json=excluded.verification_policy_json, status=excluded.status, updated_at=excluded.updated_at`,
      )
      .bind(
        goal.id,
        project.workspace_id,
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
  constructor(
    private readonly db: D1DatabaseLike,
    private readonly aggregateLoader?: (
      runId: string,
    ) => Promise<import("./index.js").ReconstructedRun | null>,
  ) {}
  async get(id: string): Promise<RunRecord | null> {
    const row = await this.db
      .prepare("SELECT * FROM runs WHERE id = ?1")
      .bind(id)
      .first();
    if (!row) return null;
    return {
      id: String(row.id),
      goalId: String(row.goal_id),
      workflowInstanceId:
        row.workflow_instance_id === null ||
        row.workflow_instance_id === undefined
          ? null
          : String(row.workflow_instance_id),
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
    const scope = await this.db
      .prepare(
        `SELECT p.workspace_id, p.id AS project_id
         FROM goals g JOIN projects p ON p.id = g.project_id
         WHERE g.id = ?1`,
      )
      .bind(run.goalId)
      .first<{ workspace_id: string; project_id: string }>();
    if (!scope?.workspace_id || !scope.project_id) {
      throw new Error(`Cannot save Run for unknown Goal: ${run.goalId}`);
    }
    await this.db
      .prepare(
        `INSERT INTO runs (id, workspace_id, project_id, goal_id, workflow_instance_id, parent_run_id, policy_snapshot_json, current_phase_id, status, started_at, finished_at, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13) ON CONFLICT(id) DO UPDATE SET workflow_instance_id=excluded.workflow_instance_id, status=excluded.status, current_phase_id=excluded.current_phase_id, started_at=excluded.started_at, finished_at=excluded.finished_at, updated_at=excluded.updated_at`,
      )
      .bind(
        run.id,
        scope.workspace_id,
        scope.project_id,
        run.goalId,
        run.workflowInstanceId ?? null,
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

  async loadAggregate(
    runId: string,
  ): Promise<import("./index.js").ReconstructedRun | null> {
    if (!this.aggregateLoader) {
      throw new Error("D1RunRepository requires an aggregate loader");
    }
    return this.aggregateLoader(runId);
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

export class D1TaskDependencyRepository {
  constructor(private readonly db: D1DatabaseLike) {}

  async listByTask(taskId: string): Promise<readonly TaskDependencyRecord[]> {
    const rows = await this.db
      .prepare(
        "SELECT task_id, depends_on_task_id FROM task_dependencies WHERE task_id = ?1 ORDER BY depends_on_task_id",
      )
      .bind(taskId)
      .all();
    return (rows.results ?? []).map((row) => ({
      taskId: String(row.task_id),
      dependsOnTaskId: String(row.depends_on_task_id),
    }));
  }

  async save(record: TaskDependencyRecord): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO task_dependencies (task_id, depends_on_task_id)
         VALUES (?1, ?2)
         ON CONFLICT(task_id, depends_on_task_id) DO NOTHING`,
      )
      .bind(record.taskId, record.dependsOnTaskId)
      .run();
  }
}

export class D1PhaseRepository {
  constructor(private readonly db: D1DatabaseLike) {}

  async get(id: string): Promise<PhaseRecord | null> {
    const row = await this.db
      .prepare("SELECT * FROM phases WHERE id = ?1")
      .bind(id)
      .first();
    return row ? toPhase(row) : null;
  }

  async save(phase: PhaseRecord): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO phases (id, run_id, name, purpose, sequence, status, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
         ON CONFLICT(id) DO UPDATE SET name=excluded.name, purpose=excluded.purpose,
           sequence=excluded.sequence, status=excluded.status, updated_at=excluded.updated_at`,
      )
      .bind(
        phase.id,
        phase.runId,
        phase.name,
        phase.purpose,
        phase.sequence,
        phase.status,
        phase.createdAt,
        phase.updatedAt,
      )
      .run();
  }

  async listByRun(runId: string): Promise<readonly PhaseRecord[]> {
    const rows = await this.db
      .prepare("SELECT * FROM phases WHERE run_id = ?1 ORDER BY sequence")
      .bind(runId)
      .all();
    return (rows.results ?? []).map(toPhase);
  }
}

function toPhase(row: Record<string, unknown>): PhaseRecord {
  return {
    id: String(row.id),
    runId: String(row.run_id),
    name: String(row.name),
    purpose: String(row.purpose),
    sequence: Number(row.sequence),
    status: String(row.status),
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}

export class D1AttemptRepository {
  constructor(private readonly db: D1DatabaseLike) {}

  async get(id: string): Promise<AttemptRecord | null> {
    const row = await this.db
      .prepare("SELECT * FROM attempts WHERE id = ?1")
      .bind(id)
      .first();
    return row ? toAttempt(row) : null;
  }

  async save(attempt: AttemptRecord): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO attempts (id, task_id, worker_id, attempt_number, input_snapshot_json,
           output_artifact_ids_json, status, failure_class, started_at, finished_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
         ON CONFLICT(id) DO UPDATE SET output_artifact_ids_json=excluded.output_artifact_ids_json,
           status=excluded.status, failure_class=excluded.failure_class,
           started_at=excluded.started_at, finished_at=excluded.finished_at`,
      )
      .bind(
        attempt.id,
        attempt.taskId,
        attempt.workerId,
        attempt.attemptNumber,
        json(attempt.inputSnapshot),
        json(attempt.outputArtifactIds),
        attempt.status,
        attempt.failureClass,
        attempt.startedAt,
        attempt.finishedAt,
      )
      .run();
  }

  async listByTask(taskId: string): Promise<readonly AttemptRecord[]> {
    const rows = await this.db
      .prepare(
        "SELECT * FROM attempts WHERE task_id = ?1 ORDER BY attempt_number",
      )
      .bind(taskId)
      .all();
    return (rows.results ?? []).map(toAttempt);
  }
}

export class D1ModelCallRepository {
  constructor(private readonly db: D1DatabaseLike) {}

  async get(id: string): Promise<ModelCallRecord | null> {
    const row = await this.db
      .prepare("SELECT * FROM model_calls WHERE id = ?1")
      .bind(id)
      .first();
    return row ? toModelCall(row) : null;
  }

  async save(call: ModelCallRecord): Promise<void> {
    const scope = await this.db
      .prepare(
        `SELECT r.workspace_id FROM attempts a
         JOIN tasks t ON t.id = a.task_id
         JOIN phases p ON p.id = t.phase_id
         JOIN runs r ON r.id = p.run_id
         WHERE a.id = ?1`,
      )
      .bind(call.attemptId)
      .first<{ workspace_id: string }>();
    if (!scope?.workspace_id) {
      throw new Error(
        `Cannot save ModelCall for unknown Attempt: ${call.attemptId}`,
      );
    }
    await this.db
      .prepare(
        `INSERT INTO model_calls (id, workspace_id, attempt_id, worker_id, connection_id, provider, model,
           request_artifact_id, response_artifact_id, status, input_tokens, output_tokens, started_at, finished_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
         ON CONFLICT(id) DO UPDATE SET status=excluded.status, input_tokens=excluded.input_tokens,
           output_tokens=excluded.output_tokens, request_artifact_id=excluded.request_artifact_id,
           response_artifact_id=excluded.response_artifact_id, finished_at=excluded.finished_at`,
      )
      .bind(
        call.id,
        scope.workspace_id,
        call.attemptId,
        call.workerId,
        call.connectionId,
        call.provider,
        call.model,
        call.requestArtifactId,
        call.responseArtifactId,
        call.status,
        call.inputTokens,
        call.outputTokens,
        call.startedAt,
        call.finishedAt,
      )
      .run();
  }

  async listByAttempt(attemptId: string): Promise<readonly ModelCallRecord[]> {
    const rows = await this.db
      .prepare(
        "SELECT * FROM model_calls WHERE attempt_id = ?1 ORDER BY started_at",
      )
      .bind(attemptId)
      .all();
    return (rows.results ?? []).map(toModelCall);
  }
}

function toModelCall(row: Record<string, unknown>): ModelCallRecord {
  return {
    id: String(row.id),
    attemptId: String(row.attempt_id),
    workerId: String(row.worker_id),
    connectionId: String(row.connection_id),
    provider: String(row.provider),
    model: String(row.model),
    requestArtifactId:
      row.request_artifact_id === null ? null : String(row.request_artifact_id),
    responseArtifactId:
      row.response_artifact_id === null
        ? null
        : String(row.response_artifact_id),
    status: String(row.status),
    inputTokens: row.input_tokens === null ? null : Number(row.input_tokens),
    outputTokens: row.output_tokens === null ? null : Number(row.output_tokens),
    startedAt: String(row.started_at),
    finishedAt: row.finished_at === null ? null : String(row.finished_at),
  };
}

export class D1FindingRepository {
  constructor(private readonly db: D1DatabaseLike) {}

  async get(id: string): Promise<FindingRecord | null> {
    const row = await this.db
      .prepare("SELECT * FROM findings WHERE id = ?1")
      .bind(id)
      .first();
    return row ? toFinding(row) : null;
  }

  async save(finding: FindingRecord): Promise<void> {
    const scope = await runScope(this.db, finding.runId);
    await this.db
      .prepare(
        `INSERT INTO findings (id, workspace_id, run_id, task_id, attempt_id, category, severity, title, description, status, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
         ON CONFLICT(id) DO UPDATE SET task_id=excluded.task_id, attempt_id=excluded.attempt_id,
           category=excluded.category, severity=excluded.severity, title=excluded.title,
           description=excluded.description, status=excluded.status, updated_at=excluded.updated_at`,
      )
      .bind(
        finding.id,
        scope.workspaceId,
        finding.runId,
        finding.taskId,
        finding.sourceAttemptId,
        finding.scope,
        finding.severity === "blocker" || finding.severity === "major"
          ? finding.severity === "blocker"
            ? "critical"
            : "warning"
          : finding.severity === "minor"
            ? "warning"
            : "info",
        finding.scope,
        finding.description,
        finding.status,
        finding.createdAt,
        finding.updatedAt,
      )
      .run();
  }

  async listByRun(runId: string): Promise<readonly FindingRecord[]> {
    const rows = await this.db
      .prepare("SELECT * FROM findings WHERE run_id = ?1 ORDER BY created_at")
      .bind(runId)
      .all();
    return (rows.results ?? []).map(toFinding);
  }
}

function toFinding(row: Record<string, unknown>): FindingRecord {
  const severity = String(row.severity);
  return {
    id: String(row.id),
    runId: String(row.run_id),
    taskId: row.task_id === null ? null : String(row.task_id),
    sourceAttemptId: row.attempt_id === null ? null : String(row.attempt_id),
    severity:
      severity === "critical"
        ? "blocker"
        : severity === "warning"
          ? "major"
          : severity === "info"
            ? "note"
            : "minor",
    scope: String(row.category),
    description: String(row.description),
    evidenceArtifactIds: [],
    status: String(row.status),
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}

export class D1VerificationRepository {
  constructor(private readonly db: D1DatabaseLike) {}

  async get(id: string): Promise<VerificationRecord | null> {
    const row = await this.db
      .prepare("SELECT * FROM verifications WHERE id = ?1")
      .bind(id)
      .first();
    return row ? toVerification(row) : null;
  }

  async save(verification: VerificationRecord): Promise<void> {
    const scope = await runScope(this.db, verification.runId);
    if (!verification.verifierWorkerId) {
      throw new Error("D1 verifications require verifierWorkerId");
    }
    await this.db
      .prepare(
        `INSERT INTO verifications (id, workspace_id, run_id, task_id, criterion_id, verifier_worker_id, conclusion, evidence_artifact_ids_json, notes, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
         ON CONFLICT(id) DO UPDATE SET task_id=excluded.task_id, criterion_id=excluded.criterion_id,
           verifier_worker_id=excluded.verifier_worker_id, conclusion=excluded.conclusion,
           evidence_artifact_ids_json=excluded.evidence_artifact_ids_json, notes=excluded.notes`,
      )
      .bind(
        verification.id,
        scope.workspaceId,
        verification.runId,
        verification.taskId,
        verification.criterionId,
        verification.verifierWorkerId,
        verification.outcome,
        json(verification.evidenceArtifactIds),
        verification.rationale,
        verification.createdAt,
      )
      .run();
  }

  async listByRun(runId: string): Promise<readonly VerificationRecord[]> {
    const rows = await this.db
      .prepare(
        "SELECT * FROM verifications WHERE run_id = ?1 ORDER BY created_at",
      )
      .bind(runId)
      .all();
    return (rows.results ?? []).map(toVerification);
  }
}

function toVerification(row: Record<string, unknown>): VerificationRecord {
  return {
    id: String(row.id),
    runId: String(row.run_id),
    taskId: row.task_id === null ? null : String(row.task_id),
    criterionId: row.criterion_id === null ? "" : String(row.criterion_id),
    verifierWorkerId:
      row.verifier_worker_id === null ? null : String(row.verifier_worker_id),
    method: "worker",
    outcome: String(row.conclusion),
    evidenceArtifactIds: parse(row.evidence_artifact_ids_json, [] as string[]),
    rationale: row.notes === null ? "" : String(row.notes),
    createdAt: String(row.created_at),
  };
}

export class D1UsageRepository {
  constructor(private readonly db: D1DatabaseLike) {}

  async save(usage: UsageRecord): Promise<void> {
    const scope = await runScope(this.db, usage.runId);
    if (!usage.workerId) throw new Error("D1 usage requires workerId");
    await this.db
      .prepare(
        `INSERT INTO usage (id, workspace_id, project_id, run_id, worker_id, assignment_id, input_tokens, output_tokens, cost_micros, duration_ms, recorded_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
         ON CONFLICT(id) DO UPDATE SET input_tokens=excluded.input_tokens, output_tokens=excluded.output_tokens,
           cost_micros=excluded.cost_micros, duration_ms=excluded.duration_ms, recorded_at=excluded.recorded_at`,
      )
      .bind(
        usage.id,
        scope.workspaceId,
        scope.projectId,
        usage.runId,
        usage.workerId,
        null,
        usage.inputTokens,
        usage.outputTokens,
        usage.estimatedCostMicros,
        usage.executionMs,
        usage.recordedAt,
      )
      .run();
  }

  async listByRun(runId: string): Promise<readonly UsageRecord[]> {
    const rows = await this.db
      .prepare("SELECT * FROM usage WHERE run_id = ?1 ORDER BY recorded_at")
      .bind(runId)
      .all();
    return (rows.results ?? []).map(toUsage);
  }
}

async function runScope(
  db: D1DatabaseLike,
  runId: string,
): Promise<{ workspaceId: string; projectId: string }> {
  const row = await db
    .prepare("SELECT workspace_id, project_id FROM runs WHERE id = ?1")
    .bind(runId)
    .first<{ workspace_id: string; project_id: string }>();
  if (!row?.workspace_id || !row.project_id) {
    throw new Error(`Cannot persist record for unknown Run: ${runId}`);
  }
  return { workspaceId: row.workspace_id, projectId: row.project_id };
}

function toUsage(row: Record<string, unknown>): UsageRecord {
  return {
    id: String(row.id),
    runId: String(row.run_id),
    attemptId: null,
    workerId: row.worker_id === null ? null : String(row.worker_id),
    inputTokens: Number(row.input_tokens),
    outputTokens: Number(row.output_tokens),
    executionMs: Number(row.duration_ms),
    estimatedCostMicros: Number(row.cost_micros),
    recordedAt: String(row.recorded_at),
  };
}

function toAttempt(row: Record<string, unknown>): AttemptRecord {
  return {
    id: String(row.id),
    taskId: String(row.task_id),
    workerId: String(row.worker_id),
    attemptNumber: Number(row.attempt_number),
    inputSnapshot: parse(row.input_snapshot_json, {}),
    outputArtifactIds: parse(row.output_artifact_ids_json, [] as string[]),
    status: String(row.status),
    failureClass: row.failure_class === null ? null : String(row.failure_class),
    startedAt: String(row.started_at),
    finishedAt: row.finished_at === null ? null : String(row.finished_at),
  };
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
    const run = await this.db
      .prepare("SELECT workspace_id FROM runs WHERE id = ?1")
      .bind(event.runId)
      .first<{ workspace_id: string }>();
    if (!run?.workspace_id) {
      throw new Error(`Cannot append event for unknown run: ${event.runId}`);
    }
    await this.db
      .prepare(
        "INSERT INTO events (id, workspace_id, run_id, sequence, event_type, entity_type, entity_id, correlation_id, payload_json, occurred_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
      )
      .bind(
        event.id,
        run.workspace_id,
        event.runId,
        event.sequence,
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
      .prepare("SELECT * FROM events WHERE run_id = ?1 ORDER BY sequence")
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
    const scope = await this.db
      .prepare(
        `SELECT p.workspace_id, p.id AS project_id
         FROM runs r JOIN projects p ON p.id = r.project_id
         WHERE r.id = ?1`,
      )
      .bind(record.runId)
      .first<{ workspace_id: string; project_id: string }>();
    if (!scope?.workspace_id || !scope.project_id) {
      throw new Error(`Cannot save Artifact for unknown Run: ${record.runId}`);
    }
    const payload =
      record.payload.kind === "inline"
        ? {
            storageKind: "inline",
            inlineContent: record.payload.content,
            storageKey: null,
            provenance: record.provenance,
          }
        : {
            storageKind: "r2",
            inlineContent: null,
            storageKey: record.payload.key,
            provenance: {
              ...jsonObject(record.provenance),
              r2Bucket: record.payload.bucket,
            },
          };
    await this.db
      .prepare(
        "INSERT INTO artifacts (id, workspace_id, project_id, run_id, task_id, attempt_id, assignment_id, media_type, content_digest, storage_kind, storage_key, inline_content, size_bytes, provenance_json, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
      )
      .bind(
        record.id,
        scope.workspace_id,
        scope.project_id,
        record.runId,
        record.taskId,
        record.attemptId,
        record.mediaType,
        record.contentDigest,
        payload.storageKind,
        payload.storageKey,
        payload.inlineContent,
        record.sizeBytes,
        json(payload.provenance),
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
  const provenance = parse<JsonValue>(row.provenance_json, {});
  const provenanceObject = jsonObject(provenance);
  return {
    id: String(row.id),
    runId: String(row.run_id),
    taskId: row.task_id === null ? null : String(row.task_id),
    attemptId: row.attempt_id === null ? null : String(row.attempt_id),
    mediaType: String(row.media_type),
    payload:
      row.storage_kind === "inline"
        ? { kind: "inline", content: String(row.inline_content) }
        : {
            kind: "r2",
            bucket: String(provenanceObject.r2Bucket ?? ""),
            key: String(row.storage_key),
            sizeBytes: Number(row.size_bytes),
          },
    contentDigest: String(row.content_digest),
    sizeBytes: Number(row.size_bytes),
    provenance,
    createdAt: String(row.created_at),
  };
}
