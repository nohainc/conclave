import { isTrustedOrigin } from "../observability.js";
import {
  identityService,
  provisionConclaveUser,
  hasRecentStepUp,
  recordAuthAuditEvent,
  type SensitiveOperation,
} from "../auth/index.js";
import {
  authorize,
  resolveProjectSecurityContextFromIdentity,
  authorizeProjectMembership,
  authorizeWorkspaceOwner,
  authorizeProjectOwner,
  authorizeProfileAdmin as authorizeSecurityProfileAdmin,
  type Permission,
  type SecurityContext,
} from "@conclave/security";

export function parseJson<T = Record<string, unknown>>(
  value: unknown,
  defaultValue: T = {} as T,
): T {
  if (typeof value !== "string" || value.trim().length === 0)
    return defaultValue;
  try {
    return JSON.parse(value) as T;
  } catch {
    return defaultValue;
  }
}

export function json(data: unknown, init?: ResponseInit): Response {
  return Response.json(data, {
    ...init,
    headers: {
      "content-type": "application/json; charset=utf-8",
      ...init?.headers,
    },
  });
}

export async function recordAudit(
  env: SecurityEnv,
  context: SecurityContext,
  action: string,
  targetType: string,
  targetId: string,
  details: Record<string, unknown> = {},
  resourceWorkspaceId?: string,
): Promise<void> {
  const auditWorkspaceId = resourceWorkspaceId;
  if (!auditWorkspaceId) {
    const projectId =
      typeof details.projectId === "string" ? details.projectId : null;
    if (!projectId) return;
    await env.CONCLAVE_DB.prepare(
      `INSERT INTO project_audit_log
         (id, project_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
       VALUES (?1, ?2, 'user', ?3, ?4, ?5, ?6, ?7, ?8)`,
    )
      .bind(
        `audit-${crypto.randomUUID()}`,
        projectId,
        context.userId,
        action,
        targetType,
        targetId,
        JSON.stringify(details),
        new Date().toISOString(),
      )
      .run();
    return;
  }
  const values = [
    `audit-${crypto.randomUUID()}`,
    auditWorkspaceId,
    context.userId,
    action,
    targetType,
    targetId,
    JSON.stringify(details),
    new Date().toISOString(),
  ] as const;
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO workspace_audit_log
       (id, workspace_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
     VALUES (?1, ?2, 'user', ?3, ?4, ?5, ?6, ?7, ?8)`,
  )
    .bind(...values)
    .run();
}

export async function recordPairingAuditEvent(
  env: SecurityEnv,
  userId: string | null,
  action: "pairing.created" | "pairing.rejected",
  outcome: "success" | "failure" | "denied",
  details: Record<string, unknown>,
): Promise<void> {
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO auth_audit_events
       (id, user_id, session_id, action, outcome, details_json, created_at)
     VALUES (?1, ?2, NULL, ?3, ?4, ?5, ?6)`,
  )
    .bind(
      `audit-${crypto.randomUUID()}`,
      userId,
      action,
      outcome,
      JSON.stringify(details),
      new Date().toISOString(),
    )
    .run();
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "Workflow operation failed";
}

export function requiredString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${field} is required`);
  }
  return value;
}

export function workflowInstanceId(idempotencyKey: string): string {
  return `workflow-${idempotencyKey}`;
}

export async function resolveWorkflowInstanceId(
  env: Env,
  runId: string,
  idempotencyKey?: string,
): Promise<string> {
  const run = await env.CONCLAVE_DB.prepare(
    "SELECT workflow_instance_id FROM runs WHERE id = ?1",
  )
    .bind(runId)
    .first<{ workflow_instance_id?: string | null }>();
  if (run?.workflow_instance_id) return run.workflow_instance_id;
  if (!idempotencyKey) return workflowInstanceId(runId);
  const candidate = workflowInstanceId(idempotencyKey);
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    "UPDATE runs SET workflow_instance_id = COALESCE(workflow_instance_id, ?1), updated_at = ?2 WHERE id = ?3",
  )
    .bind(candidate, now, runId)
    .run();
  const stored = await env.CONCLAVE_DB.prepare(
    "SELECT workflow_instance_id FROM runs WHERE id = ?1",
  )
    .bind(runId)
    .first<{ workflow_instance_id?: string | null }>();
  return stored?.workflow_instance_id ?? candidate;
}

export class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export type SecurityEnv = Env & {
  /** Comma-separated user IDs permitted to administer Profiles and releases. */
  readonly CONCLAVE_PROFILE_ADMIN_USER_IDS?: string;
  readonly CONCLAVE_RELEASE_TRUST_KEYS_JSON?: string;
  readonly CONCLAVE_RELEASE_PUBLISHER?: string;
  readonly BETTER_AUTH_SECRET?: string;
  readonly BETTER_AUTH_URL?: string;
  readonly CONCLAVE_AUTH_GITHUB_CLIENT_ID?: string;
  readonly CONCLAVE_AUTH_GITHUB_CLIENT_SECRET?: string;
  readonly CONCLAVE_AUTH_GOOGLE_CLIENT_ID?: string;
  readonly CONCLAVE_AUTH_GOOGLE_CLIENT_SECRET?: string;
  readonly TEST_AUTHENTICATION?: (
    request: Request,
    env: Env,
  ) => Promise<SecurityContext>;
  readonly CONCLAVE_WORKSPACE_GATEWAY?: DurableObjectNamespace;
  readonly CONCLAVE_REALTIME_GATEWAY?: DurableObjectNamespace;
  readonly CONCLAVE_WORKSTREAM_COORDINATOR?: DurableObjectNamespace;
};

export function testAuthenticationEnabled(env: Env): boolean {
  return (
    env.CONCLAVE_ENVIRONMENT === "development" &&
    typeof (env as SecurityEnv).TEST_AUTHENTICATION === "function"
  );
}

export function bearer(request: Request): string | null {
  const value = request.headers.get("authorization");
  return value?.startsWith("Bearer ") ? value.slice(7) : null;
}

export function requireSameOriginForCookieMutation(request: Request): void {
  if (!request.headers.get("cookie") || bearer(request)) return;

  const requestOrigin = new URL(request.url).origin;
  const origin = request.headers.get("origin");
  if (origin === requestOrigin || (origin && isTrustedOrigin(request))) return;

  const referer = request.headers.get("referer");
  if (origin === null && referer) {
    try {
      if (new URL(referer).origin === requestOrigin) return;
      const refUrl = new URL(referer);
      if (
        refUrl.hostname === "localhost" ||
        refUrl.hostname === "127.0.0.1" ||
        refUrl.hostname === "[::1]"
      ) {
        return;
      }
    } catch {
      // Treat malformed referers as untrusted.
    }
  }

  throw new HttpError(403, "Same-origin request required for cookie session");
}

export async function securityContext(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<SecurityContext> {
  // Preserve the route-handler context contract for callers that also use it
  // for non-authentication infrastructure; human identity never comes from it.
  void accessContext;
  const testAuthentication = env.TEST_AUTHENTICATION;
  if (
    env.CONCLAVE_ENVIRONMENT === "development" &&
    typeof testAuthentication === "function"
  ) {
    return testAuthentication(request, env);
  }
  if (env.BETTER_AUTH_SECRET) {
    const identity = await identityService.resolve(request, env);
    if (!identity) throw new HttpError(401, "Authentication required");
    try {
      await provisionConclaveUser(env.CONCLAVE_DB, identity);
      return await resolveProjectSecurityContextFromIdentity(
        env.CONCLAVE_DB,
        identity,
      );
    } catch (err: unknown) {
      if (
        err instanceof Error &&
        "code" in err &&
        (err as { code: string }).code === "UNAUTHORIZED"
      ) {
        throw new HttpError(401, err.message);
      }
      if (
        err instanceof Error &&
        "code" in err &&
        (err as { code: string }).code === "FORBIDDEN"
      ) {
        throw new HttpError(403, err.message);
      }
      throw err;
    }
  }

  throw new HttpError(401, "Better Auth authentication required");
}

export async function authorizeRequest(
  request: Request,
  env: SecurityEnv,
  permission: Permission,
  projectId?: string,
  accessContext?: ExecutionContext,
): Promise<SecurityContext> {
  const context = await securityContext(request, env, accessContext);
  if (
    permission === "profiles:admin" ||
    permission === "profiles:release:manage"
  ) {
    const adminUserIds = (env.CONCLAVE_PROFILE_ADMIN_USER_IDS ?? "")
      .split(",")
      .map((userId) => userId.trim())
      .filter(Boolean);
    try {
      authorizeSecurityProfileAdmin(context, adminUserIds, permission);
    } catch {
      throw new HttpError(
        403,
        "Profile administrator authorization is required",
      );
    }
  }
  if (projectId && !testAuthenticationEnabled(env)) {
    try {
      await authorizeProjectMembership(
        env.CONCLAVE_DB,
        context,
        projectId,
        permission,
      );
    } catch {
      throw new HttpError(404, "Resource not found");
    }
  }
  try {
    if (
      !testAuthenticationEnabled(env) &&
      (projectId ||
        permission === "projects:read" ||
        permission === "projects:manage")
    ) {
      authorize(context, permission, projectId);
    }
  } catch (error) {
    await recordAuthAuditEvent(env.CONCLAVE_DB, {
      action: "auth.authorization.denied",
      outcome: "denied",
      userId: context.userId,
      sessionId: context.sessionId,
      workspaceId: null,
      reason: "not_authorized",
      operation: permission,
    }).catch(() => undefined);
    throw new HttpError(
      403,
      error instanceof Error ? error.message : "Forbidden",
    );
  }
  return context;
}

export async function requireWorkspaceContext(
  context: SecurityContext,
  env: SecurityEnv,
  workspaceId: string,
): Promise<void> {
  try {
    await authorizeWorkspaceOwner(env.CONCLAVE_DB, context, workspaceId);
  } catch {
    if (!testAuthenticationEnabled(env))
      throw new HttpError(404, "Resource not found");
  }
}

export async function requireRecentStepUp(
  env: SecurityEnv,
  context: SecurityContext,
  operation: SensitiveOperation,
): Promise<void> {
  const satisfied = await hasRecentStepUp(
    env.CONCLAVE_DB,
    context.userId,
    context.sessionId,
    operation,
  );
  if (!satisfied) {
    throw new HttpError(428, "Fresh strong authentication required");
  }
}

export const MAX_ARTIFACT_UPLOAD_BYTES = 64 * 1024 * 1024;

export function artifactName(value: string | null): string {
  const normalized = (value ?? "artifact").replace(/[^a-zA-Z0-9._-]/g, "_");
  return normalized.slice(0, 160) || "artifact";
}

export function artifactMetadata(
  row: Record<string, unknown>,
): Record<string, unknown> {
  const provenance = parseJson<Record<string, unknown>>(
    row.provenance_json,
    {},
  );
  return {
    id: String(row.id),
    workspaceId: String(row.workspace_id),
    projectId: String(row.project_id),
    runId: String(row.run_id),
    ...(row.task_id ? { taskId: String(row.task_id) } : {}),
    ...(row.attempt_id ? { attemptId: String(row.attempt_id) } : {}),
    mediaType: String(row.media_type),
    contentDigest: String(row.content_digest),
    sizeBytes: Number(row.size_bytes),
    name: artifactName(
      typeof provenance.name === "string" ? provenance.name : null,
    ),
    storage: "artifact-service",
    downloadUrl: `/api/artifacts/${encodeURIComponent(String(row.id))}?workspaceId=${encodeURIComponent(String(row.workspace_id))}`,
    createdAt: String(row.created_at),
  };
}

export async function workspaceOwnerContext(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  permission: Permission,
  accessContext?: ExecutionContext,
): Promise<SecurityContext> {
  const context = await securityContext(request, env, accessContext);
  try {
    await authorizeWorkspaceOwner(
      env.CONCLAVE_DB,
      context,
      workspaceId,
      permission,
    );
  } catch {
    if (testAuthenticationEnabled(env)) return context;
    throw new HttpError(404, "Workspace not found");
  }
  return context;
}

export function securityEnv(env: Env): SecurityEnv {
  return env as SecurityEnv;
}

export async function authorizeProjectOwnerOrThrow(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<SecurityContext> {
  const context = await authorizeRequest(
    request,
    env,
    "projects:read",
    projectId,
    accessContext,
  );
  try {
    await authorizeProjectOwner(env.CONCLAVE_DB, context, projectId);
  } catch {
    throw new HttpError(403, "Only the Project owner can manage collaboration");
  }
  return context;
}

// =========================================================================
// Workstream Discuss / Work API
// =========================================================================
