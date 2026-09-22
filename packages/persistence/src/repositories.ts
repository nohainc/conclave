import type {
  ArtifactRecord,
  AttemptRecord,
  AuditLogRecord,
  BudgetRecord,
  EncryptedCredentialRecord,
  ExtensionRecord,
  FindingRecord,
  HumanApprovalRecord,
  MembershipRecord,
  ModelCallRecord,
  OrganizationRecord,
  PhaseRecord,
  ProjectMembershipRecord,
  ProjectRecord,
  RetentionPolicyRecord,
  TaskDependencyRecord,
  UsageRecord,
  VerificationRecord,
  WorkflowTemplateRecord,
  WorkerRecord,
  ConnectionRecord,
  RunAggregateRows,
  PersistenceRepositories,
} from "./index.js";
import { reconstructRun } from "./index.js";
import {
  D1ArtifactRepository,
  D1EventRepository,
  D1FindingRepository,
  D1GoalRepository,
  D1PhaseRepository,
  D1AttemptRepository,
  D1RunRepository,
  D1TaskRepository,
  D1UsageRepository,
  D1VerificationRepository,
  type D1DatabaseLike,
} from "./d1.js";

type JsonRecord = { readonly id: string };

export class D1RecordStore {
  constructor(private readonly db: D1DatabaseLike) {}
  async get<T extends JsonRecord>(
    repository: string,
    id: string,
  ): Promise<T | null> {
    const row = await this.db
      .prepare(
        "SELECT record_json FROM persistence_records WHERE repository = ?1 AND record_id = ?2",
      )
      .bind(repository, id)
      .first<{ record_json: string }>();
    return row ? (JSON.parse(row.record_json) as T) : null;
  }
  async save<T extends JsonRecord>(
    repository: string,
    record: T,
    organizationId: string | null = null,
  ): Promise<void> {
    const now = new Date().toISOString();
    await this.db
      .prepare(
        `INSERT INTO persistence_records (repository, record_id, organization_id, record_json, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?5) ON CONFLICT(repository, record_id) DO UPDATE SET organization_id=excluded.organization_id, record_json=excluded.record_json, updated_at=excluded.updated_at`,
      )
      .bind(repository, record.id, organizationId, JSON.stringify(record), now)
      .run();
  }
  async list<T extends JsonRecord>(
    repository: string,
    organizationId?: string,
  ): Promise<readonly T[]> {
    const query =
      organizationId === undefined
        ? "SELECT record_json FROM persistence_records WHERE repository = ?1 ORDER BY updated_at"
        : "SELECT record_json FROM persistence_records WHERE repository = ?1 AND organization_id = ?2 ORDER BY updated_at";
    const result =
      organizationId === undefined
        ? await this.db
            .prepare(query)
            .bind(repository)
            .all<{ record_json: string }>()
        : await this.db
            .prepare(query)
            .bind(repository, organizationId)
            .all<{ record_json: string }>();
    return (result.results ?? []).map(
      (row) => JSON.parse(row.record_json) as T,
    );
  }
}

class RecordRepository<T extends JsonRecord> {
  constructor(
    protected readonly store: D1RecordStore,
    protected readonly repository: string,
  ) {}
  get(id: string): Promise<T | null> {
    return this.store.get<T>(this.repository, id);
  }
  save(record: T, organizationId?: string | null): Promise<void> {
    return this.store.save(this.repository, record, organizationId);
  }
  list(organizationId?: string): Promise<readonly T[]> {
    return this.store.list<T>(this.repository, organizationId);
  }
}

export class D1ProjectRepository extends RecordRepository<ProjectRecord> {
  constructor(store: D1RecordStore) {
    super(store, "projects");
  }
}
export class D1WorkerRepository extends RecordRepository<WorkerRecord> {
  constructor(store: D1RecordStore) {
    super(store, "workers");
  }
}
export class D1ConnectionRepository extends RecordRepository<ConnectionRecord> {
  constructor(store: D1RecordStore) {
    super(store, "connections");
  }
}
export class D1TaskDependencyRepository {
  constructor(store: D1RecordStore) {
    this.store = store;
  }
  private readonly store: D1RecordStore;
  async listByTask(taskId: string): Promise<readonly TaskDependencyRecord[]> {
    const rows = await this.store.list<
      TaskDependencyRecord & { readonly id: string }
    >("task_dependencies");
    return rows
      .filter((row) => row.taskId === taskId)
      .map(({ taskId: sourceTaskId, dependsOnTaskId }) => ({
        taskId: sourceTaskId,
        dependsOnTaskId,
      }));
  }
  save(record: TaskDependencyRecord): Promise<void> {
    return this.store.save("task_dependencies", {
      ...record,
      id: `${record.taskId}:${record.dependsOnTaskId}`,
    });
  }
}
export class D1ModelCallRepository extends RecordRepository<ModelCallRecord> {
  constructor(store: D1RecordStore) {
    super(store, "model_calls");
  }
  async listByAttempt(attemptId: string): Promise<readonly ModelCallRecord[]> {
    return (await this.list()).filter((call) => call.attemptId === attemptId);
  }
}
export class D1OrganizationRepository extends RecordRepository<OrganizationRecord> {
  constructor(store: D1RecordStore) {
    super(store, "organizations");
  }
}
export class D1MembershipRepository {
  private readonly store: D1RecordStore;
  constructor(store: D1RecordStore) {
    this.store = store;
  }
  async get(
    organizationId: string,
    userId: string,
  ): Promise<MembershipRecord | null> {
    const rows = await this.store.list<
      MembershipRecord & { readonly id: string }
    >("organization_memberships");
    return (
      rows.find(
        (row) => row.organizationId === organizationId && row.userId === userId,
      ) ?? null
    );
  }
  save(record: MembershipRecord): Promise<void> {
    return this.store.save("organization_memberships", {
      ...record,
      id: `${record.organizationId}:${record.userId}`,
    });
  }
}
export class D1ProjectMembershipRepository {
  private readonly store: D1RecordStore;
  constructor(store: D1RecordStore) {
    this.store = store;
  }
  async listByProject(
    projectId: string,
  ): Promise<readonly ProjectMembershipRecord[]> {
    const rows = await this.store.list<
      ProjectMembershipRecord & { readonly id: string }
    >("project_memberships");
    return rows
      .filter((row) => row.projectId === projectId)
      .map(
        ({ projectId: rowProjectId, userId, role, createdAt, updatedAt }) => ({
          projectId: rowProjectId,
          userId,
          role,
          createdAt,
          updatedAt,
        }),
      );
  }
  save(record: ProjectMembershipRecord): Promise<void> {
    return this.store.save("project_memberships", {
      ...record,
      id: `${record.projectId}:${record.userId}`,
    });
  }
}
export class D1AuditLogRepository extends RecordRepository<AuditLogRecord> {
  constructor(store: D1RecordStore) {
    super(store, "audit_log");
  }
  append(record: AuditLogRecord): Promise<void> {
    return this.save(record, record.organizationId);
  }
  async listByOrganization(
    organizationId: string,
  ): Promise<readonly AuditLogRecord[]> {
    return (await this.list(organizationId)).filter(
      (record) => record.organizationId === organizationId,
    );
  }
}
export class D1BudgetRepository extends RecordRepository<BudgetRecord> {
  constructor(store: D1RecordStore) {
    super(store, "budgets");
  }
}
export class D1CredentialRepository extends RecordRepository<EncryptedCredentialRecord> {
  constructor(store: D1RecordStore) {
    super(store, "encrypted_credentials");
  }
  async getByProvider(
    organizationId: string,
    provider: string,
  ): Promise<EncryptedCredentialRecord | null> {
    return (
      (await this.list(organizationId)).find(
        (record) =>
          record.organizationId === organizationId &&
          record.provider === provider,
      ) ?? null
    );
  }
}
export class D1RetentionPolicyRepository extends RecordRepository<RetentionPolicyRecord> {
  constructor(store: D1RecordStore) {
    super(store, "retention_policies");
  }
  async getByOrganization(
    organizationId: string,
  ): Promise<RetentionPolicyRecord | null> {
    return (
      (await this.list(organizationId)).find(
        (record) => record.organizationId === organizationId,
      ) ?? null
    );
  }
}
export class D1ExtensionRepository extends RecordRepository<ExtensionRecord> {
  constructor(store: D1RecordStore) {
    super(store, "extensions");
  }
}
export class D1WorkflowTemplateRepository extends RecordRepository<WorkflowTemplateRecord> {
  constructor(store: D1RecordStore) {
    super(store, "workflow_templates");
  }
  async listByOrganization(
    organizationId: string,
  ): Promise<readonly WorkflowTemplateRecord[]> {
    return (await this.list(organizationId)).filter(
      (record) => record.organizationId === organizationId,
    );
  }
}
export class D1HumanApprovalRepository extends RecordRepository<HumanApprovalRecord> {
  constructor(store: D1RecordStore) {
    super(store, "human_approvals");
  }
}

export class D1PersistenceRepositories implements PersistenceRepositories {
  readonly store: D1RecordStore;
  readonly projects: D1ProjectRepository;
  readonly workers: D1WorkerRepository;
  readonly connections: D1ConnectionRepository;
  readonly goals: D1GoalRepository;
  readonly runs: D1RunRepository;
  readonly phases: D1PhaseRepository;
  readonly tasks: D1TaskRepository;
  readonly taskDependencies: D1TaskDependencyRepository;
  readonly attempts: D1AttemptRepository;
  readonly modelCalls: D1ModelCallRepository;
  readonly findings: D1FindingRepository;
  readonly verifications: D1VerificationRepository;
  readonly artifacts: D1ArtifactRepository;
  readonly events: D1EventRepository;
  readonly usage: D1UsageRepository;
  readonly organizations: D1OrganizationRepository;
  readonly memberships: D1MembershipRepository;
  readonly projectMemberships: D1ProjectMembershipRepository;
  readonly auditLog: D1AuditLogRepository;
  readonly budgets: D1BudgetRepository;
  readonly credentials: D1CredentialRepository;
  readonly retentionPolicies: D1RetentionPolicyRepository;
  readonly extensions: D1ExtensionRepository;
  readonly workflowTemplates: D1WorkflowTemplateRepository;
  readonly humanApprovals: D1HumanApprovalRepository;

  constructor(db: D1DatabaseLike) {
    this.store = new D1RecordStore(db);
    this.projects = new D1ProjectRepository(this.store);
    this.workers = new D1WorkerRepository(this.store);
    this.connections = new D1ConnectionRepository(this.store);
    this.goals = new D1GoalRepository(db);
    this.runs = new D1RunRepository(db, (runId) => this.loadAggregate(runId));
    this.phases = new D1PhaseRepository(db);
    this.tasks = new D1TaskRepository(db);
    this.taskDependencies = new D1TaskDependencyRepository(this.store);
    this.attempts = new D1AttemptRepository(db);
    this.modelCalls = new D1ModelCallRepository(this.store);
    this.findings = new D1FindingRepository(db);
    this.verifications = new D1VerificationRepository(db);
    this.artifacts = new D1ArtifactRepository(db);
    this.events = new D1EventRepository(db);
    this.usage = new D1UsageRepository(db);
    this.organizations = new D1OrganizationRepository(this.store);
    this.memberships = new D1MembershipRepository(this.store);
    this.projectMemberships = new D1ProjectMembershipRepository(this.store);
    this.auditLog = new D1AuditLogRepository(this.store);
    this.budgets = new D1BudgetRepository(this.store);
    this.credentials = new D1CredentialRepository(this.store);
    this.retentionPolicies = new D1RetentionPolicyRepository(this.store);
    this.extensions = new D1ExtensionRepository(this.store);
    this.workflowTemplates = new D1WorkflowTemplateRepository(this.store);
    this.humanApprovals = new D1HumanApprovalRepository(this.store);
  }

  async loadAggregate(
    runId: string,
  ): Promise<ReturnType<typeof reconstructRun> | null> {
    const run = await this.runs.get(runId);
    if (!run) return null;
    const goal = await this.goals.get(run.goalId);
    if (!goal) return null;
    const phases = await this.phases.listByRun(runId);
    const tasks = (
      await Promise.all(phases.map((phase) => this.tasks.listByPhase(phase.id)))
    ).flat();
    const taskIds = new Set(tasks.map((task) => task.id));
    const dependencies = (
      await Promise.all(
        tasks.map((task) => this.taskDependencies.listByTask(task.id)),
      )
    ).flat();
    const attempts = (
      await Promise.all(tasks.map((task) => this.attempts.listByTask(task.id)))
    ).flat();
    const attemptIds = new Set(attempts.map((attempt) => attempt.id));
    const modelCalls = (await this.modelCalls.list()).filter((call) =>
      attemptIds.has(call.attemptId),
    );
    const findings = await this.findings.listByRun(runId);
    const verifications = await this.verifications.listByRun(runId);
    const artifacts = await this.artifacts.listByRun(runId);
    const events = await this.events.listByRun(runId);
    const usage = await this.usage.listByRun(runId);
    const rows: RunAggregateRows = {
      goal,
      run,
      phases,
      tasks,
      dependencies,
      attempts,
      modelCalls,
      findings,
      verifications,
      artifacts,
      events,
      usage,
    };
    return reconstructRun(rows);
  }
}

export interface ArtifactPayloadWriter {
  put(
    key: string,
    content: Uint8Array,
    mediaType: string,
  ): Promise<{
    readonly kind: "r2";
    readonly bucket: string;
    readonly key: string;
    readonly sizeBytes: number;
  }>;
}

export const DEFAULT_ARTIFACT_INLINE_LIMIT_BYTES = 64 * 1024;

export class ThresholdArtifactStore {
  constructor(
    private readonly inlineLimitBytes: number,
    private readonly r2: ArtifactPayloadWriter,
  ) {}
  async persist(
    record: Omit<ArtifactRecord, "payload" | "sizeBytes">,
    content: string,
  ): Promise<ArtifactRecord> {
    const bytes = new TextEncoder().encode(content);
    const payload =
      bytes.byteLength <= this.inlineLimitBytes
        ? { kind: "inline" as const, content }
        : await this.r2.put(
            `${record.runId}/${record.id}`,
            bytes,
            record.mediaType,
          );
    return { ...record, payload, sizeBytes: bytes.byteLength };
  }
}
