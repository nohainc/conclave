export type JsonPrimitive = string | number | boolean | null;
export type JsonValue =
  JsonPrimitive | JsonValue[] | { readonly [key: string]: JsonValue };

export interface EntityRecord {
  readonly id: string;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface ProjectRecord extends EntityRecord {
  readonly workspaceId?: string;
  readonly name: string;
  readonly description?: string | null;
  readonly repositoryId: string | null;
  readonly settings?: JsonValue;
}

export type CompletionCriterionStatus =
  "pending" | "verified" | "failed" | "waived";

export interface CompletionCriterionRecord {
  readonly id: string;
  readonly description: string;
  readonly verificationRequirement: string;
  readonly status: CompletionCriterionStatus;
  readonly evidenceArtifactIds: readonly string[];
  readonly verifiedByWorkerId: string | null;
  readonly verificationId: string | null;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface WorkerRecord extends EntityRecord {
  readonly workspaceId?: string;
  readonly agentId?: string;
  readonly pluginId?: string;
  readonly pluginVersionPolicy?: string;
  readonly name: string;
  readonly kind: "model" | "agent" | "runtime" | "ci" | "tool" | "human";
  readonly roles: readonly string[];
  readonly capabilities: readonly string[];
  readonly permissions: readonly string[];
  readonly independenceKey: string;
  readonly availability: "available" | "busy" | "disabled" | "offline";
  readonly connectionIds: readonly string[];
  readonly config?: JsonValue;
  readonly secretRefs?: readonly string[];
  readonly billingMode?: string;
  readonly costMetadata?: JsonValue;
  readonly concurrencyLimit?: number;
  readonly sessionPolicy?: string;
  readonly enabled?: boolean;
}

export interface GoalRecord extends EntityRecord {
  readonly projectId: string;
  readonly originalMessage: string;
  readonly objective: string;
  readonly constraints: readonly string[];
  readonly completionCriteria: readonly CompletionCriterionRecord[];
  readonly verificationPolicy: JsonValue;
  readonly status: string;
}

export interface RunRecord extends EntityRecord {
  readonly goalId: string;
  readonly workflowInstanceId?: string | null;
  readonly parentRunId: string | null;
  readonly policySnapshot: JsonValue;
  readonly currentPhaseId: string | null;
  readonly status: string;
  readonly startedAt: string | null;
  readonly finishedAt: string | null;
}

export interface PhaseRecord extends EntityRecord {
  readonly runId: string;
  readonly name: string;
  readonly purpose: string;
  readonly sequence: number;
  readonly status: string;
}

export interface TaskRecord extends EntityRecord {
  readonly phaseId: string;
  readonly objective: string;
  readonly role: string;
  readonly capabilities: readonly string[];
  readonly input: JsonValue;
  readonly outputContract: JsonValue;
  readonly status: string;
  readonly requiresIndependentVerification: boolean;
}

export interface TaskDependencyRecord {
  readonly taskId: string;
  readonly dependsOnTaskId: string;
}

export interface AttemptRecord {
  readonly id: string;
  readonly taskId: string;
  readonly workerId: string;
  readonly attemptNumber: number;
  readonly inputSnapshot: JsonValue;
  readonly outputArtifactIds: readonly string[];
  readonly status: string;
  readonly failureClass: string | null;
  readonly startedAt: string;
  readonly finishedAt: string | null;
}

export interface ModelCallRecord {
  readonly id: string;
  readonly attemptId: string;
  readonly workerId: string;
  readonly connectionId: string;
  readonly provider: string;
  readonly model: string;
  readonly requestArtifactId: string | null;
  readonly responseArtifactId: string | null;
  readonly status: string;
  readonly inputTokens: number | null;
  readonly outputTokens: number | null;
  readonly startedAt: string;
  readonly finishedAt: string | null;
}

export interface FindingRecord extends EntityRecord {
  readonly runId: string;
  readonly taskId: string | null;
  readonly sourceAttemptId: string | null;
  readonly severity: "blocker" | "major" | "minor" | "note";
  readonly scope: string;
  readonly description: string;
  readonly evidenceArtifactIds: readonly string[];
  readonly status: string;
}

export interface VerificationRecord {
  readonly id: string;
  readonly runId: string;
  readonly taskId: string | null;
  readonly criterionId: string;
  readonly verifierWorkerId: string | null;
  readonly method: string;
  readonly outcome: string;
  readonly evidenceArtifactIds: readonly string[];
  readonly rationale: string;
  readonly createdAt: string;
}

export type ArtifactPayloadReference =
  | { readonly kind: "inline"; readonly content: string }
  | {
      readonly kind: "r2";
      readonly bucket: string;
      readonly key: string;
      readonly sizeBytes: number;
    };

export interface ArtifactRecord {
  readonly id: string;
  readonly runId: string;
  readonly taskId: string | null;
  readonly attemptId: string | null;
  readonly mediaType: string;
  readonly payload: ArtifactPayloadReference;
  readonly contentDigest: string;
  readonly sizeBytes: number;
  readonly provenance: JsonValue;
  readonly createdAt: string;
}

export interface RunEventRecord {
  readonly runId: string;
  readonly sequence: number;
  readonly id: string;
  readonly eventType: string;
  readonly entityType: string;
  readonly entityId: string;
  readonly correlationId: string;
  readonly payload: JsonValue;
  readonly occurredAt: string;
}

export interface UsageRecord {
  readonly id: string;
  readonly runId: string;
  readonly attemptId: string | null;
  readonly workerId: string | null;
  readonly inputTokens: number;
  readonly outputTokens: number;
  readonly executionMs: number;
  readonly estimatedCostMicros: number;
  readonly recordedAt: string;
}

export interface OrganizationRecord extends EntityRecord {
  readonly name: string;
  readonly status: "active" | "suspended";
  readonly plan: string;
}

export interface MembershipRecord {
  readonly organizationId: string;
  readonly userId: string;
  readonly role: string;
  readonly status: "active" | "invited" | "suspended";
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface ProjectMembershipRecord {
  readonly projectId: string;
  readonly userId: string;
  readonly role: string;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface AuditLogRecord {
  readonly id: string;
  readonly organizationId: string;
  readonly actorUserId: string | null;
  readonly action: string;
  readonly resourceType: string;
  readonly resourceId: string | null;
  readonly outcome: "success" | "denied" | "failure";
  readonly metadata: JsonValue;
  readonly occurredAt: string;
  readonly retentionUntil: string;
}

export interface BudgetRecord extends EntityRecord {
  readonly organizationId: string;
  readonly projectId: string | null;
  readonly runId: string | null;
  readonly maxInputTokens: number | null;
  readonly maxOutputTokens: number | null;
  readonly maxCostMicros: number | null;
  readonly usedInputTokens: number;
  readonly usedOutputTokens: number;
  readonly usedCostMicros: number;
  readonly status: "active" | "exhausted" | "disabled";
}

export interface EncryptedCredentialRecord {
  readonly id: string;
  readonly organizationId: string;
  readonly provider: string;
  readonly keyId: string;
  readonly algorithm: "AES-GCM";
  readonly iv: string;
  readonly ciphertext: string;
  readonly createdAt: string;
  readonly expiresAt: string | null;
}

export interface RetentionPolicyRecord extends EntityRecord {
  readonly organizationId: string;
  readonly auditDays: number;
  readonly artifactDays: number;
  readonly usageDays: number;
}

export interface ExtensionRecord extends EntityRecord {
  readonly organizationId: string;
  readonly extensionId: string;
  readonly kind: "provider" | "agent" | "tool" | "ci" | "human";
  readonly name: string;
  readonly version: string;
  readonly manifest: JsonValue;
  readonly status: "active" | "disabled" | "pending_review";
}

export interface WorkflowTemplateRecord extends EntityRecord {
  readonly organizationId: string;
  readonly templateId: string;
  readonly name: string;
  readonly version: number;
  readonly template: JsonValue;
  readonly status: "draft" | "active" | "archived";
  readonly createdByUserId: string;
}

export interface HumanApprovalRecord {
  readonly id: string;
  readonly organizationId: string;
  readonly runId: string;
  readonly taskId: string | null;
  readonly requestedByUserId: string;
  readonly decidedByUserId: string | null;
  readonly prompt: string;
  readonly decision: "pending" | "approved" | "rejected";
  readonly requestedAt: string;
  readonly decidedAt: string | null;
}

export interface Repository<T extends { readonly id: string }> {
  get(id: string): Promise<T | null>;
  save(record: T): Promise<void>;
}

export type ProjectRepository = Repository<ProjectRecord>;
export type WorkerRepository = Repository<WorkerRecord>;
export interface GoalRepository extends Repository<GoalRecord> {
  listByProject(projectId: string): Promise<readonly GoalRecord[]>;
}
export interface RunRepository extends Repository<RunRecord> {
  listByGoal(goalId: string): Promise<readonly RunRecord[]>;
  loadAggregate(runId: string): Promise<RunAggregateRows | null>;
}
export interface PhaseRepository extends Repository<PhaseRecord> {
  listByRun(runId: string): Promise<readonly PhaseRecord[]>;
}
export interface TaskRepository extends Repository<TaskRecord> {
  listByPhase(phaseId: string): Promise<readonly TaskRecord[]>;
}
export interface TaskDependencyRepository {
  listByTask(taskId: string): Promise<readonly TaskDependencyRecord[]>;
  save(record: TaskDependencyRecord): Promise<void>;
}
export interface AttemptRepository extends Repository<AttemptRecord> {
  listByTask(taskId: string): Promise<readonly AttemptRecord[]>;
}
export interface ModelCallRepository extends Repository<ModelCallRecord> {
  listByAttempt(attemptId: string): Promise<readonly ModelCallRecord[]>;
}
export interface FindingRepository extends Repository<FindingRecord> {
  listByRun(runId: string): Promise<readonly FindingRecord[]>;
}
export interface VerificationRepository extends Repository<VerificationRecord> {
  listByRun(runId: string): Promise<readonly VerificationRecord[]>;
}
export interface ArtifactRepository {
  get(id: string): Promise<ArtifactRecord | null>;
  save(record: ArtifactRecord): Promise<void>;
  listByRun(runId: string): Promise<readonly ArtifactRecord[]>;
}
export interface RunEventRepository {
  append(event: RunEventRecord): Promise<void>;
  listByRun(runId: string): Promise<readonly RunEventRecord[]>;
}
export interface UsageRepository {
  save(record: UsageRecord): Promise<void>;
  listByRun(runId: string): Promise<readonly UsageRecord[]>;
}

export type OrganizationRepository = Repository<OrganizationRecord>;
export interface MembershipRepository {
  get(organizationId: string, userId: string): Promise<MembershipRecord | null>;
  save(record: MembershipRecord): Promise<void>;
}
export interface ProjectMembershipRepository {
  listByProject(projectId: string): Promise<readonly ProjectMembershipRecord[]>;
  save(record: ProjectMembershipRecord): Promise<void>;
}
export interface AuditLogRepository {
  append(record: AuditLogRecord): Promise<void>;
  listByOrganization(
    organizationId: string,
  ): Promise<readonly AuditLogRecord[]>;
}
export type BudgetRepository = Repository<BudgetRecord>;
export interface EncryptedCredentialRepository {
  get(
    organizationId: string,
    provider: string,
  ): Promise<EncryptedCredentialRecord | null>;
  save(record: EncryptedCredentialRecord): Promise<void>;
}
export interface RetentionPolicyRepository {
  get(organizationId: string): Promise<RetentionPolicyRecord | null>;
  save(record: RetentionPolicyRecord): Promise<void>;
}
export type ExtensionRepository = Repository<ExtensionRecord>;
export interface WorkflowTemplateRepository extends Repository<WorkflowTemplateRecord> {
  listByOrganization(
    organizationId: string,
  ): Promise<readonly WorkflowTemplateRecord[]>;
}
export interface HumanApprovalRepository {
  get(id: string): Promise<HumanApprovalRecord | null>;
  save(record: HumanApprovalRecord): Promise<void>;
}

export interface PersistenceRepositories {
  readonly projects: ProjectRepository;
  readonly workers: WorkerRepository;
  readonly goals: GoalRepository;
  readonly runs: RunRepository;
  readonly phases: PhaseRepository;
  readonly tasks: TaskRepository;
  readonly taskDependencies: TaskDependencyRepository;
  readonly attempts: AttemptRepository;
  readonly modelCalls: ModelCallRepository;
  readonly findings: FindingRepository;
  readonly verifications: VerificationRepository;
  readonly artifacts: ArtifactRepository;
  readonly events: RunEventRepository;
  readonly usage: UsageRepository;
  readonly organizations: OrganizationRepository;
  readonly memberships: MembershipRepository;
  readonly projectMemberships: ProjectMembershipRepository;
  readonly auditLog: AuditLogRepository;
  readonly budgets: BudgetRepository;
  readonly credentials: EncryptedCredentialRepository;
  readonly retentionPolicies: RetentionPolicyRepository;
  readonly extensions: ExtensionRepository;
  readonly workflowTemplates: WorkflowTemplateRepository;
  readonly humanApprovals: HumanApprovalRepository;
}

export interface ArtifactPayloadStore {
  put(
    key: string,
    content: Uint8Array,
    mediaType: string,
  ): Promise<ArtifactPayloadReference>;
  get(reference: ArtifactPayloadReference): Promise<Uint8Array | null>;
}

export interface R2ArtifactPayloadStore extends ArtifactPayloadStore {
  readonly kind: "r2";
}

export interface RunAggregateRows {
  readonly goal: GoalRecord;
  readonly run: RunRecord;
  readonly phases: readonly PhaseRecord[];
  readonly tasks: readonly TaskRecord[];
  readonly dependencies: readonly TaskDependencyRecord[];
  readonly attempts: readonly AttemptRecord[];
  readonly modelCalls: readonly ModelCallRecord[];
  readonly findings: readonly FindingRecord[];
  readonly verifications: readonly VerificationRecord[];
  readonly artifacts: readonly ArtifactRecord[];
  readonly events: readonly RunEventRecord[];
  readonly usage: readonly UsageRecord[];
}

export interface ReconstructedRun extends RunAggregateRows {
  readonly eventSequence: readonly number[];
}

export function reconstructRun(rows: RunAggregateRows): ReconstructedRun {
  if (rows.goal.id !== rows.run.goalId) {
    throw new Error("Run aggregate goal relationship is invalid");
  }

  const events = [...rows.events].sort(
    (left, right) => left.sequence - right.sequence,
  );
  events.forEach((event, index) => {
    const expectedSequence = index + 1;
    if (event.runId !== rows.run.id || event.sequence !== expectedSequence) {
      throw new Error(
        "Run events must be contiguous, ordered, and belong to the run",
      );
    }
  });

  return {
    ...rows,
    events,
    eventSequence: events.map((event) => event.sequence),
  };
}

export * from "./d1.js";
export * from "./repositories.js";
