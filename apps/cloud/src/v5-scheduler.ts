import { resolveEffectivePermissions } from "@conclave/core";

export interface ProjectExecutionSelectionRequest {
  readonly projectId: string;
  readonly requesterUserId: string;
  readonly role: string;
  readonly capabilities: readonly string[];
  readonly accountId?: string;
  readonly workspaceId?: string;
  readonly workerId?: string;
  readonly excludeIndependenceKeys?: readonly string[];
  readonly model?: string;
  readonly maxCostMicros?: number;
}

export interface V5ExecutionTarget {
  readonly projectId: string;
  readonly workspaceId: string;
  readonly workspaceRuntimeIdentityId: string;
  readonly workspaceProjectGrantId: string;
  readonly workerId: string;
  readonly workerVersion: string;
  readonly accountId: string;
  readonly model: string | null;
  readonly effectivePermissions: readonly string[];
  readonly permissionSnapshot: Record<string, unknown>;
  readonly selectionExplanation: Record<string, unknown>;
}

type Row = Record<string, unknown>;

function strings(value: unknown): string[] {
  if (typeof value !== "string") return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed.filter((item): item is string => typeof item === "string") : [];
  } catch {
    return [];
  }
}

function object(value: unknown): Record<string, unknown> {
  if (typeof value !== "string") return {};
  try {
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? parsed as Record<string, unknown>
      : {};
  } catch {
    return {};
  }
}

function number(value: unknown, fallback = 0): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function projectPermissions(role: string): string[] {
  if (role === "owner") return ["repository:read", "repository:write", "shell:execute", "network:use"];
  if (role === "collaborator") return ["repository:read", "repository:write"];
  return ["repository:read"];
}

function allowedByJson(row: Row, key: string, value: string): boolean {
  const allowed = strings(row[key]);
  return allowed.length === 0 || allowed.includes(value);
}

/**
 * Resolves a Project execution target without consulting v4 Workspace or Host
 * tenancy. The returned explanation is persisted with the assignment.
 */
export async function selectProjectExecutionTarget(
  db: D1Database,
  request: ProjectExecutionSelectionRequest,
  now = new Date(),
): Promise<V5ExecutionTarget | null> {
  const membership = await db.prepare(
    `SELECT role FROM project_memberships WHERE project_id = ?1 AND user_id = ?2`,
  ).bind(request.projectId, request.requesterUserId).first<{ role: string }>();
  if (!membership || membership.role === "viewer") return null;

  const rows = await db.prepare(
    `SELECT g.id AS grant_id, g.project_id, g.workspace_id, g.status AS grant_status,
            g.scope, g.repository_mappings_json, g.path_mappings_json,
            g.allowed_worker_ids_json, g.allowed_worker_capabilities_json,
            g.allowed_permissions_json, g.network_policy_json,
            g.concurrency_json, g.budget_json, g.requires_step_up, g.expires_at,
            pep.budget_json AS project_budget_json,
            ew.name AS workspace_name, ew.owner_user_id, ew.status AS workspace_status,
            wri.id AS runtime_identity_id,
            w.id AS worker_id, w.publisher, wv.version AS worker_version,
            wv.capabilities_json, wv.permissions_json,
            i.status AS installation_status, d.enabled AS desired_enabled,
            d.version_policy, a.id AS account_id, a.status AS account_status,
            a.owner_user_id AS account_owner_user_id,
            a.auth_type, a.execution_workspace_id AS account_workspace_id,
            a.provider_metadata_json,
            pag.id AS account_grant_id,
            (SELECT COUNT(*) FROM worker_assignments wa
             WHERE wa.execution_workspace_id = g.workspace_id
               AND wa.status IN ('created', 'dispatched', 'acknowledged', 'running')) AS active_assignments
     FROM workspace_project_grants g
     LEFT JOIN project_execution_preferences pep ON pep.project_id = g.project_id
     JOIN execution_workspaces ew ON ew.id = g.workspace_id
     JOIN workspace_runtime_identities wri ON wri.workspace_id = ew.id AND wri.revoked_at IS NULL
     JOIN workspace_worker_desired_state d ON d.workspace_id = ew.id AND d.enabled = 1
     JOIN workers w ON w.id = d.worker_id AND w.status = 'active'
     JOIN worker_versions wv ON wv.worker_id = w.id AND wv.is_revoked = 0
       AND (d.version_policy = 'latest' OR d.version_policy = wv.version)
     JOIN workspace_worker_installations i ON i.workspace_id = ew.id
       AND i.worker_id = w.id AND i.worker_version_id = wv.id AND i.status = 'ready'
     JOIN ai_accounts a ON a.worker_id = w.id AND a.status = 'ready'
     LEFT JOIN project_account_grants pag ON pag.project_id = g.project_id
       AND pag.account_id = a.id AND pag.status = 'active'
       AND (pag.grantee_user_id IS NULL OR pag.grantee_user_id = ?2)
       AND (pag.expires_at IS NULL OR pag.expires_at > ?3)
     WHERE g.project_id = ?1 AND g.status = 'active'
       AND (g.expires_at IS NULL OR g.expires_at > ?3)
       AND ew.status = 'online'
       AND (a.owner_user_id = ?2 OR pag.id IS NOT NULL)
       AND (a.execution_workspace_id IS NULL OR a.execution_workspace_id = ew.id)
     ORDER BY CASE WHEN a.owner_user_id = ?2 THEN 0 ELSE 1 END,
              active_assignments, ew.id, w.id, a.id`,
  ).bind(request.projectId, request.requesterUserId, now.toISOString()).all<Row>();

  const excluded = new Set(request.excludeIndependenceKeys ?? []);
  const rejected: Array<Record<string, unknown>> = [];
  const candidates = [...(rows.results ?? [])].sort((left, right) => {
    const load = number(left.active_assignments) - number(right.active_assignments);
    return load || String(left.workspace_id).localeCompare(String(right.workspace_id));
  });
  for (const row of candidates) {
    const workspaceId = String(row.workspace_id);
    const workerId = String(row.worker_id);
    const accountId = String(row.account_id);
    const capabilities = strings(row.capabilities_json).map((value) => value.toLowerCase());
    const requiredCapabilities = request.capabilities.map((value) => value.toLowerCase());
    const grantCapabilities = strings(row.allowed_worker_capabilities_json).map((value) => value.toLowerCase());
    const providerMetadata = object(row.provider_metadata_json);
    const provider = String(providerMetadata.provider ?? providerMetadata.providerId ?? "unknown");
    const independenceKey = `${provider}:${String(row.publisher)}`;
    const concurrency = object(row.concurrency_json);
    const maxConcurrent = number(concurrency.maxConcurrentAssignments, 1);
    const budget = object(row.budget_json);
    const projectBudget = object(row.project_budget_json);
    const maxBudget = Math.min(
      request.maxCostMicros ?? Number.POSITIVE_INFINITY,
      number(budget.maxCostMicros, Number.POSITIVE_INFINITY),
      number(projectBudget.maxCostMicros, Number.POSITIVE_INFINITY),
    );

    const reject = (reason: string) => rejected.push({ workspaceId, workerId, accountId, reason });
    if (request.workspaceId && request.workspaceId !== workspaceId) { reject("explicit_workspace_mismatch"); continue; }
    if (request.workerId && request.workerId !== workerId) { reject("explicit_worker_mismatch"); continue; }
    if (request.accountId && request.accountId !== accountId) { reject("explicit_account_mismatch"); continue; }
    if (String(row.installation_status) !== "ready" || Number(row.desired_enabled) !== 1) { reject("worker_not_ready"); continue; }
    if (!requiredCapabilities.every((capability) => capabilities.includes(capability))) { reject("worker_capability_missing"); continue; }
    if (grantCapabilities.some((capability) => !capabilities.includes(capability))) { reject("grant_capability_not_declared"); continue; }
    if (!allowedByJson(row, "allowed_worker_ids_json", workerId)) { reject("worker_not_allowed_by_grant"); continue; }
    if (excluded.has(independenceKey)) { reject("provider_independence_conflict"); continue; }
    if (number(row.active_assignments) >= maxConcurrent) { reject("workspace_concurrency_limit"); continue; }
    if (request.model && providerMetadata.models && Array.isArray(providerMetadata.models) && !providerMetadata.models.includes(request.model)) { reject("model_not_supported_by_account"); continue; }
    const estimatedCost = number(providerMetadata.estimatedCostMicros, 0);
    if (estimatedCost > maxBudget) { reject("budget_limit"); continue; }

    const grantPermissions = strings(row.allowed_permissions_json);
    const workerPermissions = strings(row.permissions_json);
    const permissions = resolveEffectivePermissions({
      projectMemberPermissions: projectPermissions(membership.role),
      workspaceGrantPermissions: grantPermissions,
      workerManifestPermissions: workerPermissions,
      workspaceLocalPermissions: workerPermissions,
      projectPolicyPermissions: projectPermissions(membership.role),
    });
    if (permissions.length === 0) { reject("effective_permission_intersection_empty"); continue; }
    const snapshotAt = now.toISOString();
    const permissionSnapshot = {
      projectId: request.projectId,
      workspaceId,
      grantId: String(row.grant_id),
      requesterUserId: request.requesterUserId,
      scope: String(row.scope),
      permissions,
      repositoryMappings: parseJsonValue(row.repository_mappings_json),
      pathMappings: parseJsonValue(row.path_mappings_json),
      networkPolicy: object(row.network_policy_json),
      concurrency,
      budget,
      snapshotAt,
    };
    return {
      projectId: request.projectId,
      workspaceId,
      workspaceRuntimeIdentityId: String(row.runtime_identity_id),
      workspaceProjectGrantId: String(row.grant_id),
      workerId,
      workerVersion: String(row.worker_version),
      accountId,
      model: request.model ?? null,
      effectivePermissions: permissions,
      permissionSnapshot,
      selectionExplanation: {
        projectMembership: membership.role,
        workspace: { id: workspaceId, status: row.workspace_status, grantId: row.grant_id },
        worker: { id: workerId, version: row.worker_version, status: row.installation_status },
        account: { id: accountId, owner: row.account_owner_user_id === request.requesterUserId, provider },
        filters: ["project_authorized", "grant_active", "workspace_online", "worker_ready", "account_authorized", "permissions_intersected", "capacity_available", "budget_available"],
        rejectedAlternatives: rejected,
      },
    };
  }
  return null;
}

function parseJsonValue(value: unknown): unknown {
  if (typeof value !== "string") return value ?? null;
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}
