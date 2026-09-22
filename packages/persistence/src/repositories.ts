import type {
  ArtifactRecord,
  RunAggregateRows,
  PersistenceRepositories,
} from "./index.js";
import { reconstructRun } from "./index.js";
import {
  D1ArtifactRepository,
  D1EventRepository,
  D1FindingRepository,
  D1GoalRepository,
  D1ModelCallRepository,
  D1PhaseRepository,
  D1AttemptRepository,
  D1RunRepository,
  D1TaskDependencyRepository,
  D1TaskRepository,
  D1UsageRepository,
  D1VerificationRepository,
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
  D1BudgetRepository,
  D1ConnectionRepository,
  type D1DatabaseLike,
} from "./d1.js";

export class D1PersistenceRepositories implements PersistenceRepositories {
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
    this.projects = new D1ProjectRepository(db);
    this.workers = new D1WorkerRepository(db);
    this.connections = new D1ConnectionRepository(db);
    this.goals = new D1GoalRepository(db);
    this.runs = new D1RunRepository(db, (runId) => this.loadAggregate(runId));
    this.phases = new D1PhaseRepository(db);
    this.tasks = new D1TaskRepository(db);
    this.taskDependencies = new D1TaskDependencyRepository(db);
    this.attempts = new D1AttemptRepository(db);
    this.modelCalls = new D1ModelCallRepository(db);
    this.findings = new D1FindingRepository(db);
    this.verifications = new D1VerificationRepository(db);
    this.artifacts = new D1ArtifactRepository(db);
    this.events = new D1EventRepository(db);
    this.usage = new D1UsageRepository(db);
    this.organizations = new D1OrganizationRepository(db);
    this.memberships = new D1MembershipRepository(db);
    this.projectMemberships = new D1ProjectMembershipRepository(db);
    this.auditLog = new D1AuditLogRepository(db);
    this.budgets = new D1BudgetRepository(db);
    this.credentials = new D1CredentialRepository(db);
    this.retentionPolicies = new D1RetentionPolicyRepository(db);
    this.extensions = new D1ExtensionRepository(db);
    this.workflowTemplates = new D1WorkflowTemplateRepository(db);
    this.humanApprovals = new D1HumanApprovalRepository(db);
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
    const dependencies = (
      await Promise.all(
        tasks.map((task) => this.taskDependencies.listByTask(task.id)),
      )
    ).flat();
    const attempts = (
      await Promise.all(tasks.map((task) => this.attempts.listByTask(task.id)))
    ).flat();
    const modelCalls = (
      await Promise.all(
        attempts.map((attempt) => this.modelCalls.listByAttempt(attempt.id)),
      )
    ).flat();
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
