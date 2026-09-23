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
  ProjectRecord,
  WorkerRecord,
  ExtensionRecord,
  WorkflowTemplateRecord,
  EncryptedCredentialRecord,
  RetentionPolicyRecord,
  HumanApprovalRecord,
  OrganizationRecord,
  MembershipRecord,
  ProjectMembershipRecord,
  AuditLogRecord,
  BudgetRecord,
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

export class D1OrganizationRepository {
  constructor(private readonly db: D1DatabaseLike) {}

  async get(id: string): Promise<OrganizationRecord | null> {
    const row = await this.db
      .prepare("SELECT * FROM workspaces WHERE id = ?1")
      .bind(id)
      .first();
    return row ? toOrganization(row) : null;
  }

  async save(organization: OrganizationRecord): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO workspaces (id, name, slug, status, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(id) DO UPDATE SET name=excluded.name, status=excluded.status,
           updated_at=excluded.updated_at`,
      )
      .bind(
        organization.id,
        organization.name,
        organization.id,
        organization.status,
        organization.createdAt,
        organization.updatedAt,
      )
      .run();
  }
}

function toOrganization(row: Record<string, unknown>): OrganizationRecord {
  return {
    id: String(row.id),
    name: String(row.name),
    status: String(row.status) === "suspended" ? "suspended" : "active",
    plan: "workspace",
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}

export class D1MembershipRepository {
  constructor(private readonly db: D1DatabaseLike) {}

  async get(
    organizationId: string,
    userId: string,
  ): Promise<MembershipRecord | null> {
    const row = await this.db
      .prepare(
        "SELECT * FROM workspace_memberships WHERE workspace_id = ?1 AND user_id = ?2",
      )
      .bind(organizationId, userId)
      .first();
    return row ? toMembership(row) : null;
  }

  async save(membership: MembershipRecord): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO workspace_memberships (id, workspace_id, user_id, role, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(workspace_id, user_id) DO UPDATE SET role=excluded.role,
           updated_at=excluded.updated_at`,
      )
      .bind(
        `${membership.organizationId}:${membership.userId}`,
        membership.organizationId,
        membership.userId,
        membership.role,
        membership.createdAt,
        membership.updatedAt,
      )
      .run();
  }
}

function toMembership(row: Record<string, unknown>): MembershipRecord {
  return {
    organizationId: String(row.workspace_id),
    userId: String(row.user_id),
    role: String(row.role),
    status: "active",
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}

export class D1ProjectMembershipRepository {
  constructor(private readonly db: D1DatabaseLike) {}

  async listByProject(
    projectId: string,
  ): Promise<readonly ProjectMembershipRecord[]> {
    const rows = await this.db
      .prepare(
        "SELECT * FROM project_memberships WHERE project_id = ?1 ORDER BY user_id",
      )
      .bind(projectId)
      .all();
    return (rows.results ?? []).map(toProjectMembership);
  }

  async save(membership: ProjectMembershipRecord): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO project_memberships (id, project_id, user_id, role, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(project_id, user_id) DO UPDATE SET role=excluded.role,
           updated_at=excluded.updated_at`,
      )
      .bind(
        `${membership.projectId}:${membership.userId}`,
        membership.projectId,
        membership.userId,
        membership.role,
        membership.createdAt,
        membership.updatedAt,
      )
      .run();
  }
}

function toProjectMembership(
  row: Record<string, unknown>,
): ProjectMembershipRecord {
  return {
    projectId: String(row.project_id),
    userId: String(row.user_id),
    role: String(row.role),
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}

export class D1AuditLogRepository {
  constructor(private readonly db: D1DatabaseLike) {}

  async append(record: AuditLogRecord): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO audit_log (id, workspace_id, actor_type, actor_id, action,
           target_type, target_id, details_json, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)`,
      )
      .bind(
        record.id,
        record.organizationId,
        record.actorUserId ? "user" : "system",
        record.actorUserId ?? "system",
        record.action,
        record.resourceType,
        record.resourceId ?? "",
        json({ ...jsonObject(record.metadata), outcome: record.outcome }),
        record.occurredAt,
      )
      .run();
  }

  async listByOrganization(
    organizationId: string,
  ): Promise<readonly AuditLogRecord[]> {
    const rows = await this.db
      .prepare(
        "SELECT * FROM audit_log WHERE workspace_id = ?1 ORDER BY created_at",
      )
      .bind(organizationId)
      .all();
    return (rows.results ?? []).map((row) => {
      const details = parse<Record<string, JsonValue>>(row.details_json, {});
      const outcome = details.outcome;
      const metadata = { ...details };
      delete metadata.outcome;
      return {
        id: String(row.id),
        organizationId: String(row.workspace_id),
        actorUserId: row.actor_type === "user" ? String(row.actor_id) : null,
        action: String(row.action),
        resourceType: String(row.target_type),
        resourceId: row.target_id === null ? null : String(row.target_id),
        outcome:
          outcome === "denied" || outcome === "failure" ? outcome : "success",
        metadata,
        occurredAt: String(row.created_at),
        retentionUntil: String(row.created_at),
      };
    });
  }
}

export class D1BudgetRepository {
  constructor(private readonly db: D1DatabaseLike) {}

  async get(id: string): Promise<BudgetRecord | null> {
    const row = await this.db
      .prepare("SELECT * FROM budgets WHERE id = ?1")
      .bind(id)
      .first();
    return row ? toBudget(row) : null;
  }

  async save(budget: BudgetRecord): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO budgets (id, workspace_id, project_id, run_id, credential_profile_id, max_cost_micros,
           max_input_tokens, max_output_tokens, used_input_tokens, used_output_tokens,
           used_cost_micros, status, max_attempts, max_wall_time_seconds, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, NULL, NULL, ?13, ?14)
         ON CONFLICT(id) DO UPDATE SET project_id=excluded.project_id, run_id=excluded.run_id,
           credential_profile_id=excluded.credential_profile_id,
           max_cost_micros=excluded.max_cost_micros, max_input_tokens=excluded.max_input_tokens,
           max_output_tokens=excluded.max_output_tokens, used_input_tokens=excluded.used_input_tokens,
           used_output_tokens=excluded.used_output_tokens, used_cost_micros=excluded.used_cost_micros,
           status=excluded.status, updated_at=excluded.updated_at`,
      )
      .bind(
        budget.id,
        budget.organizationId,
        budget.projectId,
        budget.runId,
        budget.credentialProfileId,
        budget.maxCostMicros,
        budget.maxInputTokens,
        budget.maxOutputTokens,
        budget.usedInputTokens,
        budget.usedOutputTokens,
        budget.usedCostMicros,
        budget.status,
        budget.createdAt,
        budget.updatedAt,
      )
      .run();
  }
}

function toBudget(row: Record<string, unknown>): BudgetRecord {
  return {
    id: String(row.id),
    organizationId: String(row.workspace_id),
    projectId: row.project_id === null ? null : String(row.project_id),
    runId: row.run_id === null ? null : String(row.run_id),
    credentialProfileId:
      row.credential_profile_id === null ||
      row.credential_profile_id === undefined
        ? null
        : String(row.credential_profile_id),
    maxInputTokens:
      row.max_input_tokens === null ? null : Number(row.max_input_tokens),
    maxOutputTokens:
      row.max_output_tokens === null ? null : Number(row.max_output_tokens),
    maxCostMicros:
      row.max_cost_micros === null ? null : Number(row.max_cost_micros),
    usedInputTokens: Number(row.used_input_tokens ?? 0),
    usedOutputTokens: Number(row.used_output_tokens ?? 0),
    usedCostMicros: Number(row.used_cost_micros ?? 0),
    status: String(row.status) as BudgetRecord["status"],
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}

export class D1ProjectRepository {
  constructor(private readonly db: D1DatabaseLike) {}

  async get(id: string): Promise<ProjectRecord | null> {
    const row = await this.db
      .prepare("SELECT * FROM projects WHERE id = ?1")
      .bind(id)
      .first();
    return row ? toProject(row) : null;
  }

  async save(project: ProjectRecord): Promise<void> {
    if (!project.workspaceId) {
      throw new Error(`D1 project requires workspaceId: ${project.id}`);
    }
    await this.db
      .prepare(
        `INSERT INTO projects (id, workspace_id, name, description, repository_id, settings_json, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
         ON CONFLICT(id) DO UPDATE SET name=excluded.name, description=excluded.description,
           repository_id=excluded.repository_id, settings_json=excluded.settings_json,
           updated_at=excluded.updated_at`,
      )
      .bind(
        project.id,
        project.workspaceId,
        project.name,
        project.description ?? null,
        project.repositoryId,
        json(project.settings ?? {}),
        project.createdAt,
        project.updatedAt,
      )
      .run();
  }
}

function toProject(row: Record<string, unknown>): ProjectRecord {
  return {
    id: String(row.id),
    workspaceId: String(row.workspace_id),
    name: String(row.name),
    description:
      row.description === null ? null : String(row.description ?? ""),
    repositoryId: row.repository_id === null ? null : String(row.repository_id),
    settings: parse(row.settings_json, {}),
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}

export class D1WorkerRepository {
  constructor(private readonly db: D1DatabaseLike) {}

  async get(id: string): Promise<WorkerRecord | null> {
    const row = await this.db
      .prepare("SELECT * FROM workers WHERE id = ?1")
      .bind(id)
      .first();
    return row ? toWorker(row) : null;
  }

  async save(worker: WorkerRecord): Promise<void> {
    if (!worker.workspaceId || !worker.agentId || !worker.workerCatalogId) {
      throw new Error(
        `D1 worker requires workspaceId, agentId, and workerCatalogId: ${worker.id}`,
      );
    }
    const config = {
      ...jsonObject(worker.config ?? {}),
      kind: worker.kind,
    };
    await this.db
      .prepare(
        `INSERT INTO workers (id, workspace_id, agent_id, plugin_id, plugin_version_policy, name,
           roles_json, capabilities_json, config_json, secret_refs_json, billing_mode,
           cost_metadata_json, independence_key, concurrency_limit, session_policy,
           enabled, status, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)
         ON CONFLICT(id) DO UPDATE SET agent_id=excluded.agent_id, plugin_id=excluded.plugin_id,
           plugin_version_policy=excluded.plugin_version_policy, name=excluded.name,
           roles_json=excluded.roles_json, capabilities_json=excluded.capabilities_json,
           config_json=excluded.config_json, secret_refs_json=excluded.secret_refs_json,
           billing_mode=excluded.billing_mode, cost_metadata_json=excluded.cost_metadata_json,
           independence_key=excluded.independence_key, concurrency_limit=excluded.concurrency_limit,
           session_policy=excluded.session_policy, enabled=excluded.enabled,
           status=excluded.status, updated_at=excluded.updated_at`,
      )
      .bind(
        worker.id,
        worker.workspaceId,
        worker.agentId,
        worker.workerCatalogId,
        worker.workerVersionPolicy ?? "latest",
        worker.name,
        json(worker.roles),
        json(worker.capabilities),
        json(config),
        json(worker.secretRefs ?? []),
        worker.billingMode ?? "manual",
        json(worker.costMetadata ?? {}),
        worker.independenceKey,
        worker.concurrencyLimit ?? 1,
        worker.sessionPolicy ?? "stateless",
        worker.enabled === false ? 0 : 1,
        worker.availability,
        worker.createdAt,
        worker.updatedAt,
      )
      .run();
  }
}

export class D1ExtensionRepository {
  constructor(private readonly db: D1DatabaseLike) {}

  async get(id: string): Promise<ExtensionRecord | null> {
    const row = await this.db
      .prepare("SELECT * FROM extensions WHERE row_id = ?1")
      .bind(id)
      .first();
    return row ? toExtension(row) : null;
  }

  async save(extension: ExtensionRecord): Promise<void> {
    const rowId = extension.id;
    await this.db
      .prepare(
        `INSERT INTO extensions (row_id, organization_id, extension_id, kind, name, version,
           manifest_json, status, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
         ON CONFLICT(row_id) DO UPDATE SET name=excluded.name, manifest_json=excluded.manifest_json,
           status=excluded.status, updated_at=excluded.updated_at`,
      )
      .bind(
        rowId,
        extension.organizationId,
        extension.extensionId,
        extension.kind,
        extension.name,
        extension.version,
        json(extension.manifest),
        extension.status,
        extension.createdAt,
        extension.updatedAt,
      )
      .run();
  }
}

function toExtension(row: Record<string, unknown>): ExtensionRecord {
  return {
    id: String(row.row_id),
    organizationId: String(row.organization_id),
    extensionId: String(row.extension_id),
    kind: String(row.kind) as ExtensionRecord["kind"],
    name: String(row.name),
    version: String(row.version),
    manifest: parse(row.manifest_json, {}),
    status: String(row.status) as ExtensionRecord["status"],
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}

export class D1WorkflowTemplateRepository {
  constructor(private readonly db: D1DatabaseLike) {}

  async get(id: string): Promise<WorkflowTemplateRecord | null> {
    const row = await this.db
      .prepare("SELECT * FROM workflow_templates WHERE row_id = ?1")
      .bind(id)
      .first();
    return row ? toWorkflowTemplate(row) : null;
  }

  async save(template: WorkflowTemplateRecord): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO workflow_templates (row_id, organization_id, template_id, name, version,
           template_json, status, created_by_user_id, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
         ON CONFLICT(row_id) DO UPDATE SET name=excluded.name, template_json=excluded.template_json,
           status=excluded.status, updated_at=excluded.updated_at`,
      )
      .bind(
        template.id,
        template.organizationId,
        template.templateId,
        template.name,
        template.version,
        json(template.template),
        template.status,
        template.createdByUserId,
        template.createdAt,
        template.updatedAt,
      )
      .run();
  }

  async listByOrganization(
    organizationId: string,
  ): Promise<readonly WorkflowTemplateRecord[]> {
    const rows = await this.db
      .prepare(
        "SELECT * FROM workflow_templates WHERE organization_id = ?1 ORDER BY template_id, version",
      )
      .bind(organizationId)
      .all();
    return (rows.results ?? []).map(toWorkflowTemplate);
  }
}

function toWorkflowTemplate(
  row: Record<string, unknown>,
): WorkflowTemplateRecord {
  return {
    id: String(row.row_id),
    organizationId: String(row.organization_id),
    templateId: String(row.template_id),
    name: String(row.name),
    version: Number(row.version),
    template: parse(row.template_json, {}),
    status: String(row.status) as WorkflowTemplateRecord["status"],
    createdByUserId: String(row.created_by_user_id),
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}

export class D1CredentialRepository {
  constructor(private readonly db: D1DatabaseLike) {}

  async get(
    organizationId: string,
    provider: string,
  ): Promise<EncryptedCredentialRecord | null> {
    const row = await this.db
      .prepare(
        "SELECT * FROM credentials WHERE organization_id = ?1 AND provider = ?2",
      )
      .bind(organizationId, provider)
      .first();
    return row ? toCredential(row) : null;
  }

  async save(credential: EncryptedCredentialRecord): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO credentials (id, organization_id, provider, key_id, algorithm, iv,
           ciphertext, created_at, expires_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
         ON CONFLICT(id) DO UPDATE SET key_id=excluded.key_id, algorithm=excluded.algorithm,
           iv=excluded.iv, ciphertext=excluded.ciphertext, expires_at=excluded.expires_at`,
      )
      .bind(
        credential.id,
        credential.organizationId,
        credential.provider,
        credential.keyId,
        credential.algorithm,
        credential.iv,
        credential.ciphertext,
        credential.createdAt,
        credential.expiresAt,
      )
      .run();
  }
}

function toCredential(row: Record<string, unknown>): EncryptedCredentialRecord {
  return {
    id: String(row.id),
    organizationId: String(row.organization_id),
    provider: String(row.provider),
    keyId: String(row.key_id),
    algorithm: "AES-GCM",
    iv: String(row.iv),
    ciphertext: String(row.ciphertext),
    createdAt: String(row.created_at),
    expiresAt: row.expires_at === null ? null : String(row.expires_at),
  };
}

export class D1RetentionPolicyRepository {
  constructor(private readonly db: D1DatabaseLike) {}

  async get(organizationId: string): Promise<RetentionPolicyRecord | null> {
    const row = await this.db
      .prepare("SELECT * FROM retention_policies WHERE organization_id = ?1")
      .bind(organizationId)
      .first();
    return row ? toRetentionPolicy(row) : null;
  }

  async save(policy: RetentionPolicyRecord): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO retention_policies (id, organization_id, audit_days, artifact_days,
           usage_days, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT(id) DO UPDATE SET audit_days=excluded.audit_days,
           artifact_days=excluded.artifact_days, usage_days=excluded.usage_days,
           updated_at=excluded.updated_at`,
      )
      .bind(
        policy.id,
        policy.organizationId,
        policy.auditDays,
        policy.artifactDays,
        policy.usageDays,
        policy.createdAt,
        policy.updatedAt,
      )
      .run();
  }
}

function toRetentionPolicy(
  row: Record<string, unknown>,
): RetentionPolicyRecord {
  return {
    id: String(row.id),
    organizationId: String(row.organization_id),
    auditDays: Number(row.audit_days),
    artifactDays: Number(row.artifact_days),
    usageDays: Number(row.usage_days),
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}

export class D1HumanApprovalRepository {
  constructor(private readonly db: D1DatabaseLike) {}

  async get(id: string): Promise<HumanApprovalRecord | null> {
    const row = await this.db
      .prepare("SELECT * FROM human_approvals WHERE id = ?1")
      .bind(id)
      .first();
    return row ? toHumanApproval(row) : null;
  }

  async save(approval: HumanApprovalRecord): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO human_approvals (id, organization_id, run_id, task_id,
           requested_by_user_id, decided_by_user_id, prompt, decision, requested_at, decided_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
         ON CONFLICT(id) DO UPDATE SET decided_by_user_id=excluded.decided_by_user_id,
           prompt=excluded.prompt, decision=excluded.decision, decided_at=excluded.decided_at`,
      )
      .bind(
        approval.id,
        approval.organizationId,
        approval.runId,
        approval.taskId,
        approval.requestedByUserId,
        approval.decidedByUserId,
        approval.prompt,
        approval.decision,
        approval.requestedAt,
        approval.decidedAt,
      )
      .run();
  }
}

function toHumanApproval(row: Record<string, unknown>): HumanApprovalRecord {
  return {
    id: String(row.id),
    organizationId: String(row.organization_id),
    runId: String(row.run_id),
    taskId: row.task_id === null ? null : String(row.task_id),
    requestedByUserId: String(row.requested_by_user_id),
    decidedByUserId:
      row.decided_by_user_id === null ? null : String(row.decided_by_user_id),
    prompt: String(row.prompt),
    decision: String(row.decision) as HumanApprovalRecord["decision"],
    requestedAt: String(row.requested_at),
    decidedAt: row.decided_at === null ? null : String(row.decided_at),
  };
}

function toWorker(row: Record<string, unknown>): WorkerRecord {
  const config = parse<Record<string, JsonValue>>(row.config_json, {});
  const configuredKind = config.kind;
  const kind =
    configuredKind === "model" ||
    configuredKind === "agent" ||
    configuredKind === "runtime" ||
    configuredKind === "ci" ||
    configuredKind === "tool" ||
    configuredKind === "human"
      ? configuredKind
      : "agent";
  const status = String(row.status);
  return {
    id: String(row.id),
    workspaceId: String(row.workspace_id),
    agentId: String(row.agent_id),
    workerCatalogId: String(row.plugin_id),
    workerVersionPolicy: String(row.plugin_version_policy),
    name: String(row.name),
    kind,
    roles: parse(row.roles_json, [] as string[]),
    capabilities: parse(row.capabilities_json, [] as string[]),
    permissions: [],
    independenceKey: String(row.independence_key),
    availability:
      status === "draining" || status === "error"
        ? "offline"
        : (status as WorkerRecord["availability"]),
    connectionIds: [],
    config,
    secretRefs: parse(row.secret_refs_json, [] as string[]),
    billingMode: String(row.billing_mode),
    costMetadata: parse(row.cost_metadata_json, {}),
    concurrencyLimit: Number(row.concurrency_limit),
    sessionPolicy: String(row.session_policy),
    enabled: Number(row.enabled) === 1,
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
        `SELECT r.workspace_id, r.project_id FROM attempts a
         JOIN tasks t ON t.id = a.task_id
         JOIN phases p ON p.id = t.phase_id
         JOIN runs r ON r.id = p.run_id
         WHERE a.id = ?1`,
      )
      .bind(call.attemptId)
      .first<{ workspace_id: string; project_id: string }>();
    if (!scope?.workspace_id || !scope.project_id) {
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
    const startedMs = Date.parse(call.startedAt);
    const finishedMs = call.finishedAt
      ? Date.parse(call.finishedAt)
      : startedMs;
    const durationMs =
      Number.isFinite(startedMs) && Number.isFinite(finishedMs)
        ? Math.max(0, finishedMs - startedMs)
        : 0;
    await this.db
      .prepare(
        `INSERT INTO usage (id, workspace_id, project_id, run_id, worker_id, assignment_id,
           provider, billing_category, input_tokens, output_tokens, cost_micros, duration_ms, recorded_at)
         SELECT ?1, r.workspace_id, r.project_id, r.id, ?2, NULL, ?3, 'api', ?4, ?5, NULL, ?6, ?7
         FROM attempts a
         JOIN tasks t ON t.id = a.task_id
         JOIN phases p ON p.id = t.phase_id
         JOIN runs r ON r.id = p.run_id
         WHERE a.id = ?7
         ON CONFLICT(id) DO UPDATE SET input_tokens=excluded.input_tokens,
           output_tokens=excluded.output_tokens, duration_ms=excluded.duration_ms,
           recorded_at=excluded.recorded_at`,
      )
      .bind(
        `usage:model-call:${call.id}`,
        call.workerId,
        call.provider,
        call.inputTokens ?? 0,
        call.outputTokens ?? 0,
        durationMs,
        call.finishedAt ?? call.startedAt,
        call.attemptId,
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
        finding.status === "fixed" || finding.status === "verified"
          ? "resolved"
          : finding.status === "dismissed"
            ? "ignored"
            : finding.status === "reopened"
              ? "open"
              : finding.status,
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
    status:
      row.status === "resolved"
        ? "verified"
        : row.status === "ignored"
          ? "dismissed"
          : String(row.status),
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
        verification.outcome === "passed" ? "verified" : verification.outcome,
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
    outcome: row.conclusion === "verified" ? "passed" : String(row.conclusion),
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
    const profile = usage.credentialProfileId
      ? await this.db
          .prepare(
            "SELECT owner_type, owner_id FROM credential_profiles WHERE id = ?1",
          )
          .bind(usage.credentialProfileId)
          .first<{ owner_type: string; owner_id: string }>()
      : null;
    await this.db
      .prepare(
        `INSERT INTO usage (id, workspace_id, project_id, run_id, worker_id, assignment_id, credential_profile_id, credential_profile_owner_type, credential_profile_owner_id, requester_user_id, host_id, provider, billing_category, model, input_tokens, output_tokens, cost_micros, duration_ms, recorded_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)
         ON CONFLICT(id) DO UPDATE SET input_tokens=excluded.input_tokens, output_tokens=excluded.output_tokens,
           credential_profile_id=excluded.credential_profile_id, credential_profile_owner_type=excluded.credential_profile_owner_type,
           credential_profile_owner_id=excluded.credential_profile_owner_id, requester_user_id=excluded.requester_user_id,
           host_id=excluded.host_id, provider=excluded.provider, billing_category=excluded.billing_category,
           model=excluded.model, cost_micros=excluded.cost_micros,
           duration_ms=excluded.duration_ms, recorded_at=excluded.recorded_at`,
      )
      .bind(
        usage.id,
        scope.workspaceId,
        scope.projectId,
        usage.runId,
        usage.workerId,
        null,
        usage.credentialProfileId ?? null,
        usage.credentialProfileOwnerType ??
          (profile?.owner_type as "user" | "workspace" | undefined) ??
          null,
        usage.credentialProfileOwnerId ?? profile?.owner_id ?? null,
        usage.requesterUserId ?? null,
        usage.hostId ?? null,
        usage.provider ?? null,
        usage.billingCategory ?? "unknown",
        usage.model ?? null,
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
    credentialProfileId:
      row.credential_profile_id === null ||
      row.credential_profile_id === undefined
        ? null
        : String(row.credential_profile_id),
    credentialProfileOwnerType:
      row.credential_profile_owner_type === null ||
      row.credential_profile_owner_type === undefined
        ? null
        : (String(row.credential_profile_owner_type) as "user" | "workspace"),
    credentialProfileOwnerId:
      row.credential_profile_owner_id === null ||
      row.credential_profile_owner_id === undefined
        ? null
        : String(row.credential_profile_owner_id),
    requesterUserId:
      row.requester_user_id === null || row.requester_user_id === undefined
        ? null
        : String(row.requester_user_id),
    hostId:
      row.host_id === null || row.host_id === undefined
        ? null
        : String(row.host_id),
    provider:
      row.provider === null || row.provider === undefined
        ? null
        : String(row.provider),
    billingCategory: String(
      row.billing_category ?? "unknown",
    ) as UsageRecord["billingCategory"],
    model:
      row.model === null || row.model === undefined ? null : String(row.model),
    inputTokens: Number(row.input_tokens),
    outputTokens: Number(row.output_tokens),
    executionMs: Number(row.duration_ms),
    estimatedCostMicros:
      row.cost_micros === null || row.cost_micros === undefined
        ? null
        : Number(row.cost_micros),
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
