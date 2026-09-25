export interface V5UsageInput {
  readonly assignmentId: string;
  readonly inputTokens?: number;
  readonly outputTokens?: number;
  readonly costMicros?: number | null;
  readonly durationMs?: number;
  readonly provider?: string | null;
  readonly model?: string | null;
  readonly billingCategory?: "subscription" | "api" | "local" | "unknown";
}

type Row = Record<string, unknown>;

function integer(value: unknown): number {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) && parsed >= 0 ? Math.floor(parsed) : 0;
}

function optionalInteger(value: unknown): number | null {
  return value == null ? null : integer(value);
}

/**
 * Records one immutable v5 usage fact from the assignment snapshot. The
 * assignment is the source of truth for requester, Project, execution
 * Workspace, Worker, and Account ownership; callers cannot supply tenancy
 * dimensions independently.
 */
export async function recordV5AssignmentUsage(
  db: D1Database,
  input: V5UsageInput,
): Promise<void> {
  const assignment = await db
    .prepare(
      `SELECT wa.id, wa.project_id, wa.run_id, wa.workstream_id, wa.work_request_id,
            wa.workflow_version_id, wa.worker_id, wa.configured_worker_id,
            cw.worker_type_id, wa.account_id,
            wa.requested_by_user_id, wa.execution_workspace_id,
            ew.owner_user_id AS workspace_owner_user_id,
            COALESCE(aa.owner_user_id, c.owner_user_id) AS account_owner_user_id,
            COALESCE(aa.provider_metadata_json, c.provider_metadata_json) AS provider_metadata_json,
            wa.model
       FROM worker_assignments wa
       JOIN execution_workspaces ew ON ew.id = wa.execution_workspace_id
       LEFT JOIN ai_accounts aa ON aa.id = wa.account_id
       LEFT JOIN workspace_worker_credentials c
         ON c.worker_id = wa.configured_worker_id
        AND c.workspace_id = wa.execution_workspace_id
       LEFT JOIN configured_workers cw ON cw.id = wa.configured_worker_id
      WHERE wa.id = ?1`,
    )
    .bind(input.assignmentId)
    .first<Row>();
  if (!assignment) return;

  const providerMetadata = (() => {
    try {
      const parsed = JSON.parse(
        String(assignment.provider_metadata_json ?? "{}"),
      );
      return parsed && typeof parsed === "object" ? (parsed as Row) : {};
    } catch {
      return {};
    }
  })();
  const provider =
    input.provider ??
    String(
      providerMetadata.provider ?? providerMetadata.providerId ?? "unknown",
    );
  const model =
    input.model ?? (assignment.model == null ? null : String(assignment.model));
  const now = new Date().toISOString();

  await db
    .prepare(
      `INSERT OR IGNORE INTO usage
       (id, project_id, run_id, workstream_id, work_request_id, workflow_version_id,
        worker_id, configured_worker_id, worker_type_id, assignment_id, account_id,
        requester_user_id, execution_workspace_id, workspace_owner_user_id,
        account_owner_user_id, credential_owner_user_id, provider, billing_category, model,
        input_tokens, output_tokens, cost_micros, duration_ms, recorded_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15,
             ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24)`,
    )
    .bind(
      `usage-${input.assignmentId}`,
      assignment.project_id,
      assignment.run_id,
      assignment.workstream_id,
      assignment.work_request_id,
      assignment.workflow_version_id,
      assignment.worker_id,
      assignment.configured_worker_id,
      assignment.worker_type_id,
      assignment.id,
      assignment.account_id,
      assignment.requested_by_user_id,
      assignment.execution_workspace_id,
      assignment.workspace_owner_user_id,
      assignment.account_owner_user_id,
      assignment.account_owner_user_id,
      provider,
      input.billingCategory ?? "unknown",
      model,
      integer(input.inputTokens),
      integer(input.outputTokens),
      optionalInteger(input.costMicros),
      integer(input.durationMs),
      now,
    )
    .run();
}

/** Checks all active Project, Run, and Account budgets before dispatch. */
export async function assertV5BudgetAvailable(
  db: D1Database,
  input: {
    readonly projectId: string;
    readonly runId: string;
    readonly accountId: string;
    readonly inputTokens?: number;
    readonly outputTokens?: number;
    readonly estimatedCostMicros?: number | null;
  },
): Promise<void> {
  const budgets = await db
    .prepare(
      `SELECT id, max_input_tokens, max_output_tokens, max_cost_micros,
            COALESCE((SELECT SUM(u.input_tokens) FROM usage u
              WHERE u.project_id = budgets.project_id
                AND (budgets.run_id IS NULL OR u.run_id = budgets.run_id)
                AND (budgets.account_id IS NULL OR u.account_id = budgets.account_id)), 0) AS used_input,
            COALESCE((SELECT SUM(u.output_tokens) FROM usage u
              WHERE u.project_id = budgets.project_id
                AND (budgets.run_id IS NULL OR u.run_id = budgets.run_id)
                AND (budgets.account_id IS NULL OR u.account_id = budgets.account_id)), 0) AS used_output,
            COALESCE((SELECT SUM(u.cost_micros) FROM usage u
              WHERE u.project_id = budgets.project_id
                AND (budgets.run_id IS NULL OR u.run_id = budgets.run_id)
                AND (budgets.account_id IS NULL OR u.account_id = budgets.account_id)), 0) AS used_cost
       FROM budgets
      WHERE project_id = ?1 AND status = 'active'
        AND (run_id IS NULL OR run_id = ?2)
        AND (account_id IS NULL OR account_id = ?3)`,
    )
    .bind(input.projectId, input.runId, input.accountId)
    .all<Row>();
  const nextInput = integer(input.inputTokens);
  const nextOutput = integer(input.outputTokens);
  for (const budget of budgets.results ?? []) {
    if (
      budget.max_input_tokens != null &&
      integer(budget.used_input) + nextInput > integer(budget.max_input_tokens)
    ) {
      throw new Error(`Budget ${String(budget.id)} rejects input token usage`);
    }
    if (
      budget.max_output_tokens != null &&
      integer(budget.used_output) + nextOutput >
        integer(budget.max_output_tokens)
    ) {
      throw new Error(`Budget ${String(budget.id)} rejects output token usage`);
    }
    if (budget.max_cost_micros != null) {
      if (input.estimatedCostMicros == null)
        throw new Error(
          `Budget ${String(budget.id)} requires known monetary cost`,
        );
      if (
        integer(budget.used_cost) + integer(input.estimatedCostMicros) >
        integer(budget.max_cost_micros)
      ) {
        throw new Error(`Budget ${String(budget.id)} rejects monetary cost`);
      }
    }
  }
}

export async function recordExecutionWorkspaceAudit(
  db: D1Database,
  input: {
    readonly workspaceId: string;
    readonly ownerUserId: string;
    readonly actorType: "user" | "workspace_runtime" | "worker" | "system";
    readonly actorId: string;
    readonly action: string;
    readonly targetType: string;
    readonly targetId: string;
    readonly details?: Record<string, unknown>;
  },
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO execution_workspace_audit_log
       (id, execution_workspace_id, workspace_owner_user_id, actor_type, actor_id,
        action, target_type, target_id, details_json, created_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)`,
    )
    .bind(
      `ewa-${crypto.randomUUID()}`,
      input.workspaceId,
      input.ownerUserId,
      input.actorType,
      input.actorId,
      input.action,
      input.targetType,
      input.targetId,
      JSON.stringify(input.details ?? {}),
      new Date().toISOString(),
    )
    .run();
}
