export { ConclaveRunWorkflow } from "../workflow.js";
export { WorkspaceGateway } from "../workspace-gateway.js";
export {
  dispatchTaskAssignment,
  recordAssignmentResult,
  recordAssignmentError,
  cancelTaskAssignment,
  type TaskToDispatch,
  type AssignmentDispatcherEnv,
} from "../assignment-dispatcher.js";
export { handleConnectorRequest } from "../interactive-connector.js";
import { handleConnectorTaskRequest } from "../interactive-connector.js";
export { handleConnectorTaskRequest };
import {
  isTrustedOrigin,
  logStructured,
  requestIdFor,
} from "../observability.js";
import {
  identityService,
  handleBetterAuthRequest,
  provisionConclaveUser,
  hasRecentStepUp,
  SENSITIVE_OPERATIONS,
  recordAuthAuditEvent,
  type SensitiveOperation,
} from "../auth/index.js";
import {
  dispatchTaskAssignment,
  cancelTaskAssignment,
  type TaskToDispatch,
  type AssignmentDispatcherEnv,
} from "../assignment-dispatcher.js";
import {
  authorize,
  extractBearerToken,
  hashToken,
  timingSafeEqual,
  computePackageDigest,
  resolveProjectSecurityContextFromIdentity,
  authorizeProjectMembership,
  authorizeWorkspaceOwner,
  authorizeProjectOwner,
  authorizeProfileAdmin as authorizeSecurityProfileAdmin,
  type Permission,
  type SecurityContext,
} from "@conclave/security";
import {
  canDiscussWorkstream,
  canExecuteWorkstream,
  canManageWorkstream,
  canViewWorkstream,
  DEFAULT_WORKSTREAM_ACCESS_POLICY,
  type ProjectMembership,
  type Workstream,
  type BuiltinWorkflowDefinition,
  type WorkflowId,
  WORKFLOW_IDS,
  WORKSTREAM_BINDING_IDS,
  WORKER_INPUT_CAPABILITIES,
} from "@conclave/core";
import { parseMachineCheckEvidence } from "@conclave/protocol";

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
  try {
    await env.CONCLAVE_DB.prepare(
      `INSERT INTO audit_log
         (id, workspace_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
       VALUES (?1, ?2, 'user', ?3, ?4, ?5, ?6, ?7, ?8)`,
    )
      .bind(...values)
      .run();
  } catch {
    await env.CONCLAVE_DB.prepare(
      `INSERT INTO workspace_audit_log
         (id, workspace_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
       VALUES (?1, ?2, 'user', ?3, ?4, ?5, ?6, ?7, ?8)`,
    )
      .bind(...values)
      .run();
  }
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

  const external = await env.CONCLAVE_DB.prepare(
    "SELECT external_id FROM run_external_executions WHERE run_id = ?1 AND execution_kind = 'cloudflare_workflow'",
  )
    .bind(runId)
    .first<{ external_id?: string | null }>();
  if (external?.external_id) {
    await env.CONCLAVE_DB.prepare(
      "UPDATE runs SET workflow_instance_id = ?1, updated_at = ?2 WHERE id = ?3 AND workflow_instance_id IS NULL",
    )
      .bind(external.external_id, new Date().toISOString(), runId)
      .run();
    return external.external_id;
  }

  if (!idempotencyKey) {
    return workflowInstanceId(runId);
  }
  const candidate = workflowInstanceId(idempotencyKey);
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    "UPDATE runs SET workflow_instance_id = ?1, updated_at = ?2 WHERE id = ?3 AND workflow_instance_id IS NULL",
  )
    .bind(candidate, now, runId)
    .run();
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO run_external_executions
       (id, run_id, execution_kind, external_id, status, created_at, updated_at)
     VALUES (?1, ?2, 'cloudflare_workflow', ?3, 'active', ?4, ?4)
     ON CONFLICT(run_id, execution_kind) DO UPDATE SET external_id=excluded.external_id,
       updated_at=excluded.updated_at`,
  )
    .bind(`${runId}:cloudflare_workflow`, runId, candidate, now)
    .run();
  return candidate;
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
  readonly CONCLAVE_PLUGIN_PUBLISHER_EMAIL?: string;
  /** Legacy V2 plugin catalog only; Worker and Workspace releases use Ed25519. */
  readonly CONCLAVE_SECURITY_KEY?: string;
  readonly TEST_AUTHENTICATION?: (
    request: Request,
    env: Env,
  ) => Promise<SecurityContext>;
  readonly CONCLAVE_CI_INGEST_TOKEN?: string;
  readonly CONCLAVE_FORGE_CALLBACK_TOKEN?: string;
  readonly CONCLAVE_WORKSPACE_GATEWAY?: DurableObjectNamespace;
  readonly CONCLAVE_REALTIME_GATEWAY?: DurableObjectNamespace;
  readonly CONCLAVE_WORKSTREAM_COORDINATOR?: DurableObjectNamespace;
  readonly CONCLAVE_CONNECTOR_REGISTRATION_TOKEN?: string;
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

export function requireCiAuthentication(
  request: Request,
  env: SecurityEnv,
): void {
  const configuredToken = env.CONCLAVE_CI_INGEST_TOKEN;
  if (testAuthenticationEnabled(env) && !configuredToken) return;
  if (!configuredToken || bearer(request) !== configuredToken)
    throw new HttpError(401, "CI evidence authentication required");
}

export function requireForgeCallbackAuthentication(
  request: Request,
  env: SecurityEnv,
): void {
  if (testAuthenticationEnabled(env) && !env.CONCLAVE_FORGE_CALLBACK_TOKEN)
    return;
  if (
    !env.CONCLAVE_FORGE_CALLBACK_TOKEN ||
    bearer(request) !== env.CONCLAVE_FORGE_CALLBACK_TOKEN
  ) {
    throw new HttpError(401, "Forge callback authentication required");
  }
}

export async function runProjectId(
  env: SecurityEnv,
  runId: string,
): Promise<string | undefined> {
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT p.id AS project_id FROM runs r JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id WHERE r.id = ?1",
  )
    .bind(runId)
    .first<{ project_id: string }>();
  return row?.project_id;
}

export async function goalProjectId(
  env: SecurityEnv,
  goalId: string,
): Promise<string | undefined> {
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT project_id FROM goals WHERE id = ?1",
  )
    .bind(goalId)
    .first<{ project_id: string }>();
  return row?.project_id;
}

export async function createOrGetRun(
  env: Env,
  params: ConclaveWorkflowParams,
): Promise<{ id: string; status: unknown }> {
  const current = await env.CONCLAVE_DB.prepare(
    "SELECT policy_snapshot_json FROM runs WHERE id = ?1",
  )
    .bind(params.runId)
    .first<{ policy_snapshot_json: string }>();
  let policy: Record<string, unknown> = {};
  if (current?.policy_snapshot_json) {
    try {
      const parsed: unknown = JSON.parse(current.policy_snapshot_json);
      if (typeof parsed === "object" && parsed !== null)
        policy = parsed as Record<string, unknown>;
    } catch {
      policy = {};
    }
  }
  await env.CONCLAVE_DB.prepare(
    "UPDATE runs SET policy_snapshot_json = ?1, updated_at = ?2 WHERE id = ?3",
  )
    .bind(
      JSON.stringify({
        ...policy,
        ...(params.repositoryId ? { repositoryId: params.repositoryId } : {}),
        ...(params.expectedCommitSha
          ? { expectedCommitSha: params.expectedCommitSha }
          : {}),
        ...(params.expectedChecks
          ? { expectedChecks: params.expectedChecks }
          : {}),
        ...(params.allowedWorkflows
          ? { allowedWorkflows: params.allowedWorkflows }
          : {}),
      }),
      new Date().toISOString(),
      params.runId,
    )
    .run();
  const id = await resolveWorkflowInstanceId(
    env,
    params.runId,
    params.idempotencyKey,
  );
  try {
    const instance = await env.CONCLAVE_RUN_WORKFLOW.create({ id, params });
    return { id: params.runId, status: (await instance.status()).status };
  } catch (error) {
    if (!errorMessage(error).toLowerCase().includes("exist")) throw error;
    const instance = await env.CONCLAVE_RUN_WORKFLOW.get(id);
    return { id: params.runId, status: (await instance.status()).status };
  }
}

export type ConclaveWorkflowParams =
  import("../workflow.js").ConclaveWorkflowParams;

export async function handleSessionLogout(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const headers = new Headers(request.headers);
  headers.delete("content-length");
  headers.set("content-type", "application/json");
  const authRequest = new Request(new URL("/api/auth/sign-out", request.url), {
    method: "POST",
    headers,
    body: JSON.stringify({ disableRedirect: true }),
  });
  const response = await handleBetterAuthRequest(authRequest, env);
  if (response.ok && env.CONCLAVE_DB) {
    await recordAudit(env, context, "logout", "session", context.sessionId);
  }
  return response;
}

const DESKTOP_HUMAN_AUDIENCE = "conclave.desktop.management" as const;
const DESKTOP_HUMAN_SESSION_MS = 30 * 24 * 60 * 60 * 1000;

export function randomSecret(prefix: string): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return `${prefix}${btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "")}`;
}

export function randomUserCode(): string {
  const bytes = crypto.getRandomValues(new Uint32Array(1));
  return String((bytes[0] ?? 0) % 100_000_000).padStart(8, "0");
}

export async function handleCreateDesktopAuthIntent(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const body = (await request.json().catch(() => ({}))) as {
    clientName?: unknown;
    contractVersion?: unknown;
  };
  if (
    (body.contractVersion !== "1.0" && body.contractVersion !== "1.1") ||
    typeof body.clientName !== "string" ||
    !body.clientName.trim()
  ) {
    throw new HttpError(
      400,
      "A supported contract version and client name are required",
    );
  }
  const intentId = crypto.randomUUID();
  const legacyCodeFlow = body.contractVersion === "1.0";
  const userCode = legacyCodeFlow
    ? randomUserCode()
    : randomSecret("conclave_dai_");
  const pollToken = randomSecret("conclave_dap_");
  const createdAt = new Date();
  const expiresAt = new Date(createdAt.getTime() + 10 * 60_000);
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO desktop_auth_intents
       (id, user_code_hash, poll_token_hash, client_name, created_at, expires_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
  )
    .bind(
      intentId,
      await hashToken(userCode),
      await hashToken(pollToken),
      body.clientName.trim().slice(0, 128),
      createdAt.toISOString(),
      expiresAt.toISOString(),
    )
    .run();

  const verificationUrl = new URL("/desktop-auth/approve", request.url);
  verificationUrl.searchParams.set("intentId", intentId);
  return json(
    {
      intentId,
      ...(legacyCodeFlow ? { userCode } : {}),
      pollToken,
      verificationUrl: verificationUrl.toString(),
      expiresAt: expiresAt.toISOString(),
      pollIntervalMs: 2000,
    },
    { status: 201 },
  );
}

export async function handleDesktopAuthIntentStatus(
  request: Request,
  env: SecurityEnv,
  intentId: string,
): Promise<Response> {
  const pollToken = extractBearerToken(request.headers);
  if (!pollToken)
    throw new HttpError(401, "Desktop auth polling credential required");
  const intent = await env.CONCLAVE_DB.prepare(
    `SELECT expires_at AS expiresAt, approved_at AS approvedAt,
            claimed_at AS claimedAt, denied_at AS deniedAt
       FROM desktop_auth_intents WHERE id = ?1 AND poll_token_hash = ?2`,
  )
    .bind(intentId, await hashToken(pollToken))
    .first<{
      expiresAt: string;
      approvedAt: string | null;
      claimedAt: string | null;
      deniedAt: string | null;
    }>();
  if (!intent) throw new HttpError(404, "Desktop auth intent not found");
  const status = intent.claimedAt
    ? "claimed"
    : intent.deniedAt
      ? "denied"
      : intent.approvedAt
        ? "approved"
        : intent.expiresAt <= new Date().toISOString()
          ? "expired"
          : "pending";
  return json({ intentId, status, expiresAt: intent.expiresAt });
}

/** Public, non-secret state for tabs opened by the desktop system browser. */
export async function handleDesktopAuthIntentBrowserStatus(
  _request: Request,
  env: SecurityEnv,
  intentId: string,
): Promise<Response> {
  const intent = await env.CONCLAVE_DB.prepare(
    `SELECT expires_at AS expiresAt, approved_at AS approvedAt,
            claimed_at AS claimedAt, denied_at AS deniedAt
       FROM desktop_auth_intents WHERE id = ?1`,
  )
    .bind(intentId)
    .first<{
      expiresAt: string;
      approvedAt: string | null;
      claimedAt: string | null;
      deniedAt: string | null;
    }>();
  if (!intent) throw new HttpError(404, "Desktop auth intent not found");
  const status = intent.claimedAt
    ? "claimed"
    : intent.deniedAt
      ? "denied"
      : intent.approvedAt
        ? "approved"
        : intent.expiresAt <= new Date().toISOString()
          ? "expired"
          : "pending";
  return json({ intentId, status, expiresAt: intent.expiresAt });
}

export async function handleCancelDesktopAuthIntent(
  request: Request,
  env: SecurityEnv,
  intentId: string,
): Promise<Response> {
  const pollToken = extractBearerToken(request.headers);
  if (!pollToken) {
    throw new HttpError(401, "Desktop auth polling credential required");
  }
  const now = new Date().toISOString();
  const result = await env.CONCLAVE_DB.prepare(
    `UPDATE desktop_auth_intents SET denied_at = ?1
      WHERE id = ?2 AND poll_token_hash = ?3 AND approved_at IS NULL
        AND claimed_at IS NULL AND denied_at IS NULL AND expires_at > ?1`,
  )
    .bind(now, intentId, await hashToken(pollToken))
    .run();
  if ((result.meta?.changes ?? 0) !== 1) {
    throw new HttpError(409, "Desktop sign-in is no longer pending");
  }
  return json({ intentId, cancelled: true });
}

export async function handleDenyDesktopAuthIntent(
  request: Request,
  env: SecurityEnv,
  intentId: string,
): Promise<Response> {
  const identity = await identityService.resolve(request, env);
  if (!identity)
    throw new HttpError(401, "Sign in before canceling this request");
  const now = new Date().toISOString();
  const result = await env.CONCLAVE_DB.prepare(
    `UPDATE desktop_auth_intents SET denied_at = ?1
      WHERE id = ?2 AND approved_at IS NULL AND claimed_at IS NULL
        AND denied_at IS NULL AND expires_at > ?1`,
  )
    .bind(now, intentId)
    .run();
  if ((result.meta?.changes ?? 0) !== 1) {
    throw new HttpError(409, "Desktop sign-in is no longer pending");
  }
  return json({ intentId, cancelled: true });
}

export async function handleApproveDesktopAuthIntent(
  request: Request,
  env: SecurityEnv,
  intentId: string,
): Promise<Response> {
  const identity = await identityService.resolve(request, env);
  if (!identity)
    throw new HttpError(
      401,
      "Sign in to Conclave AX before approving Workspace sign-in",
    );
  await provisionConclaveUser(env.CONCLAVE_DB, identity);
  const body = (await request.json().catch(() => ({}))) as {
    userCode?: unknown;
  };
  const now = new Date().toISOString();
  // Older desktop releases still submit their displayed code. New approvals
  // omit it: the authenticated browser session plus the unguessable intent URL
  // and explicit approval action bind the request to the signed-in account.
  if (body.userCode !== undefined) {
    if (typeof body.userCode !== "string" || !/^\d{8}$/.test(body.userCode)) {
      throw new HttpError(400, "The legacy desktop sign-in code is invalid");
    }
    const attempt = await env.CONCLAVE_DB.prepare(
      `UPDATE desktop_auth_intents SET approval_attempts = approval_attempts + 1
        WHERE id = ?1 AND approved_at IS NULL AND claimed_at IS NULL
          AND denied_at IS NULL AND expires_at > ?2 AND approval_attempts < 5`,
    )
      .bind(intentId, now)
      .run();
    if ((attempt.meta?.changes ?? 0) !== 1) {
      throw new HttpError(
        409,
        "This sign-in request is invalid, expired, or unavailable",
      );
    }
    const intent = await env.CONCLAVE_DB.prepare(
      "SELECT user_code_hash AS userCodeHash FROM desktop_auth_intents WHERE id = ?1",
    )
      .bind(intentId)
      .first<{ userCodeHash: string }>();
    if (
      !intent ||
      !timingSafeEqual(intent.userCodeHash, await hashToken(body.userCode))
    ) {
      await env.CONCLAVE_DB.prepare(
        `UPDATE desktop_auth_intents SET denied_at = ?1
          WHERE id = ?2 AND approval_attempts >= 5 AND approved_at IS NULL`,
      )
        .bind(now, intentId)
        .run();
      throw new HttpError(409, "The code does not match this sign-in request");
    }
  }
  const result = await env.CONCLAVE_DB.prepare(
    `UPDATE desktop_auth_intents
        SET approved_at = ?1, approved_user_id = ?2
      WHERE id = ?3 AND approved_at IS NULL
        AND claimed_at IS NULL AND denied_at IS NULL AND expires_at > ?1`,
  )
    .bind(now, identity.userId, intentId)
    .run();
  if ((result.meta?.changes ?? 0) !== 1) {
    throw new HttpError(
      409,
      "This sign-in request is invalid, expired, or already used",
    );
  }
  return json({
    approved: true,
    approvedAt: now,
    user: {
      userId: identity.userId,
      displayName: identity.name,
      email: identity.email,
    },
  });
}

export async function handleClaimDesktopAuthIntent(
  request: Request,
  env: SecurityEnv,
  intentId: string,
): Promise<Response> {
  const body = (await request.json().catch(() => ({}))) as {
    pollToken?: unknown;
  };
  const pollToken = typeof body.pollToken === "string" ? body.pollToken : "";
  if (!pollToken)
    throw new HttpError(401, "Desktop auth polling credential required");
  const intent = await env.CONCLAVE_DB.prepare(
    `SELECT approved_user_id AS userId, expires_at AS expiresAt
       FROM desktop_auth_intents
      WHERE id = ?1 AND poll_token_hash = ?2 AND approved_at IS NOT NULL
        AND claimed_at IS NULL AND denied_at IS NULL AND expires_at > ?3`,
  )
    .bind(intentId, await hashToken(pollToken), new Date().toISOString())
    .first<{ userId: string; expiresAt: string }>();
  if (!intent)
    throw new HttpError(
      409,
      "Desktop sign-in is not approved, expired, or already claimed",
    );
  const user = await env.CONCLAVE_DB.prepare(
    "SELECT id AS userId, email, display_name AS displayName FROM users WHERE id = ?1 AND status = 'active'",
  )
    .bind(intent.userId)
    .first<{ userId: string; email: string; displayName: string }>();
  if (!user) throw new HttpError(403, "Conclave account is unavailable");

  const sessionId = crypto.randomUUID();
  const credential = randomSecret("conclave_dhs_");
  const tokenHash = await hashToken(credential);
  const issuedAt = new Date();
  const expiresAt = new Date(issuedAt.getTime() + DESKTOP_HUMAN_SESSION_MS);
  const results = await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      `UPDATE desktop_auth_intents SET claimed_at = ?1, claimed_session_id = ?2
        WHERE id = ?3 AND poll_token_hash = ?4 AND approved_at IS NOT NULL
          AND claimed_at IS NULL AND denied_at IS NULL AND expires_at > ?1`,
    ).bind(
      issuedAt.toISOString(),
      sessionId,
      intentId,
      await hashToken(pollToken),
    ),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at)
       SELECT ?1, ?2, ?3, ?4, ?5, ?5, ?6 FROM desktop_auth_intents
        WHERE id = ?7 AND claimed_session_id = ?1`,
    ).bind(
      sessionId,
      user.userId,
      tokenHash,
      DESKTOP_HUMAN_AUDIENCE,
      issuedAt.toISOString(),
      expiresAt.toISOString(),
      intentId,
    ),
  ]);
  const changes =
    (results[0] as { meta?: { changes?: number } } | undefined)?.meta
      ?.changes ?? 0;
  if (changes !== 1)
    throw new HttpError(409, "Desktop sign-in is already claimed or expired");
  return json({
    credential,
    user: {
      userId: user.userId,
      displayName: user.displayName,
      email: user.email,
    },
    issuedAt: issuedAt.toISOString(),
    expiresAt: expiresAt.toISOString(),
    sessionId,
    audience: DESKTOP_HUMAN_AUDIENCE,
  });
}

export async function handleRevokeDesktopHumanSession(
  request: Request,
  env: SecurityEnv,
  sessionId: string,
): Promise<Response> {
  const credential = extractBearerToken(request.headers);
  if (!credential) throw new HttpError(401, "Desktop human session required");
  const now = new Date().toISOString();
  const result = await env.CONCLAVE_DB.prepare(
    `UPDATE desktop_human_sessions SET revoked_at = ?1
      WHERE id = ?2 AND token_hash = ?3 AND revoked_at IS NULL AND expires_at > ?1`,
  )
    .bind(now, sessionId, await hashToken(credential))
    .run();
  if ((result.meta?.changes ?? 0) !== 1)
    throw new HttpError(401, "Desktop human session is invalid or revoked");
  return json({ revoked: true, revokedAt: now });
}

export async function findDesktopHumanSession(
  request: Request,
  env: SecurityEnv,
  sessionId?: string,
) {
  const credential = extractBearerToken(request.headers);
  if (!credential) throw new HttpError(401, "Desktop human session required");
  const now = new Date().toISOString();
  const session = await env.CONCLAVE_DB.prepare(
    `SELECT s.id AS sessionId, s.user_id AS userId, s.created_at AS createdAt,
            s.expires_at AS expiresAt,
            u.email, u.display_name AS displayName
       FROM desktop_human_sessions s JOIN users u ON u.id = s.user_id
      WHERE s.token_hash = ?1 AND s.audience = ?2 AND s.revoked_at IS NULL
        AND s.expires_at > ?3 AND u.status = 'active'
        AND (?4 IS NULL OR s.id = ?4)`,
  )
    .bind(
      await hashToken(credential),
      DESKTOP_HUMAN_AUDIENCE,
      now,
      sessionId ?? null,
    )
    .first<{
      sessionId: string;
      userId: string;
      createdAt: string;
      expiresAt: string;
      email: string;
      displayName: string;
    }>();
  if (!session)
    throw new HttpError(
      401,
      "Desktop human session is invalid, expired, or revoked",
    );
  await env.CONCLAVE_DB.prepare(
    "UPDATE desktop_human_sessions SET last_used_at = ?1 WHERE id = ?2",
  )
    .bind(now, session.sessionId)
    .run();
  return { credential, session, now };
}

export async function handleGetDesktopHumanSession(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const { session } = await findDesktopHumanSession(request, env);
  return json({
    sessionId: session.sessionId,
    user: {
      userId: session.userId,
      displayName: session.displayName,
      email: session.email,
    },
    audience: DESKTOP_HUMAN_AUDIENCE,
    expiresAt: session.expiresAt,
  });
}

export async function handleRotateDesktopHumanSession(
  request: Request,
  env: SecurityEnv,
  sessionId: string,
): Promise<Response> {
  const {
    credential: currentCredential,
    session,
    now,
  } = await findDesktopHumanSession(request, env, sessionId);
  const nextCredential = randomSecret("conclave_dhs_");
  const expiresAt = new Date(
    Date.now() + DESKTOP_HUMAN_SESSION_MS,
  ).toISOString();
  const result = await env.CONCLAVE_DB.prepare(
    `UPDATE desktop_human_sessions SET token_hash = ?1,
       last_used_at = ?2, expires_at = ?3
      WHERE id = ?4 AND token_hash = ?5 AND revoked_at IS NULL`,
  )
    .bind(
      await hashToken(nextCredential),
      now,
      expiresAt,
      session.sessionId,
      await hashToken(currentCredential),
    )
    .run();
  if ((result.meta?.changes ?? 0) !== 1) {
    throw new HttpError(401, "Desktop human session changed or was revoked");
  }
  return json({
    credential: nextCredential,
    user: {
      userId: session.userId,
      displayName: session.displayName,
      email: session.email,
    },
    issuedAt: now,
    expiresAt,
    sessionId: session.sessionId,
    audience: DESKTOP_HUMAN_AUDIENCE,
  });
}

export type WorkspaceBackupQuery = {
  readonly name: string;
  readonly sql: string;
};

const WORKSPACE_BACKUP_QUERIES: readonly WorkspaceBackupQuery[] = [
  {
    name: "workspaces",
    sql: "SELECT * FROM execution_workspaces WHERE id = ?1",
  },
  {
    name: "workspace_project_grants",
    sql: "SELECT * FROM workspace_project_grants WHERE workspace_id = ?1",
  },
  {
    name: "projects",
    sql: "SELECT p.* FROM projects p JOIN workspace_project_grants g ON g.project_id = p.id WHERE g.workspace_id = ?1 AND g.status = 'active'",
  },
  {
    name: "project_memberships",
    sql: "SELECT pm.* FROM project_memberships pm JOIN workspace_project_grants g ON g.project_id = pm.project_id WHERE g.workspace_id = ?1 AND g.status = 'active'",
  },
  { name: "runs", sql: "SELECT * FROM runs WHERE workspace_id = ?1" },
  {
    name: "phases",
    sql: "SELECT ph.* FROM phases ph JOIN runs r ON r.id = ph.run_id WHERE r.workspace_id = ?1",
  },
  {
    name: "tasks",
    sql: "SELECT t.* FROM tasks t JOIN phases ph ON ph.id = t.phase_id JOIN runs r ON r.id = ph.run_id WHERE r.workspace_id = ?1",
  },
  {
    name: "task_dependencies",
    sql: "SELECT td.* FROM task_dependencies td JOIN tasks t ON t.id = td.task_id JOIN phases ph ON ph.id = t.phase_id JOIN runs r ON r.id = ph.run_id WHERE r.workspace_id = ?1",
  },
  { name: "hosts", sql: "SELECT * FROM hosts WHERE workspace_id = ?1" },
  {
    name: "host_enrollments",
    sql: "SELECT * FROM host_enrollments WHERE workspace_id = ?1",
  },
  {
    name: "host_sessions",
    sql: "SELECT * FROM host_sessions WHERE workspace_id = ?1",
  },
  { name: "workers", sql: "SELECT * FROM workers WHERE workspace_id = ?1" },
  {
    name: "attempts",
    sql: "SELECT a.* FROM attempts a JOIN tasks t ON t.id = a.task_id JOIN phases ph ON ph.id = t.phase_id JOIN runs r ON r.id = ph.run_id WHERE r.workspace_id = ?1",
  },
  {
    name: "worker_assignments",
    sql: "SELECT * FROM worker_assignments WHERE workspace_id = ?1",
  },
  {
    name: "completion_criteria",
    sql: "SELECT cc.* FROM completion_criteria cc JOIN goals g ON g.id = cc.goal_id WHERE g.workspace_id = ?1",
  },
  {
    name: "verifications",
    sql: "SELECT * FROM verifications WHERE workspace_id = ?1",
  },
  { name: "artifacts", sql: "SELECT * FROM artifacts WHERE workspace_id = ?1" },
  { name: "findings", sql: "SELECT * FROM findings WHERE workspace_id = ?1" },
  { name: "events", sql: "SELECT * FROM events WHERE workspace_id = ?1" },
  { name: "audit_log", sql: "SELECT * FROM audit_log WHERE workspace_id = ?1" },
  {
    name: "ci_evidence",
    sql: "SELECT * FROM ci_evidence WHERE workspace_id = ?1",
  },
];

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

export function encodeBase64(bytes: Uint8Array): string {
  let value = "";
  for (const byte of bytes) value += String.fromCharCode(byte);
  return btoa(value);
}

export function decodeBase64(value: string): Uint8Array {
  const decoded = atob(value);
  return Uint8Array.from(decoded, (character) => character.charCodeAt(0));
}

export async function workspaceBackupKey(
  secret: string,
  workspaceId: string,
): Promise<CryptoKey> {
  const keyMaterial = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${secret}:${workspaceId}`),
  );
  return await crypto.subtle.importKey(
    "raw",
    keyMaterial,
    { name: "AES-GCM" },
    false,
    ["decrypt"],
  );
}

export async function createEncryptedWorkspaceBackup(
  env: SecurityEnv,
  workspaceId: string,
): Promise<{ key: string; digest: string; sizeBytes: number }> {
  const secret = env.CONCLAVE_SECURITY_KEY;
  const bucket = env.CONCLAVE_ARTIFACTS;
  if (!secret || !bucket) {
    throw new HttpError(503, "Encrypted backup storage is not configured");
  }
  const tables: Record<string, unknown[]> = {};
  for (const query of WORKSPACE_BACKUP_QUERIES) {
    const result = await env.CONCLAVE_DB.prepare(query.sql)
      .bind(workspaceId)
      .all<Record<string, unknown>>();
    tables[query.name] = result.results ?? [];
  }
  const plaintext = JSON.stringify({
    format: "conclave-workspace-backup-p1",
    workspaceId,
    exportedAt: new Date().toISOString(),
    tables,
  });
  const digest = await computePackageDigest(plaintext);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const keyMaterial = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${secret}:${workspaceId}`),
  );
  const key = await crypto.subtle.importKey(
    "raw",
    keyMaterial,
    { name: "AES-GCM" },
    false,
    ["encrypt"],
  );
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    key,
    new TextEncoder().encode(plaintext),
  );
  const envelope = JSON.stringify({
    format: "conclave-encrypted-backup-v1",
    workspaceId,
    digest,
    algorithm: "AES-GCM",
    keyDerivation: "SHA-256(secret:workspaceId)",
    iv: encodeBase64(iv),
    ciphertext: encodeBase64(new Uint8Array(ciphertext)),
  });
  const objectKey = `backups/${workspaceId}/${Date.now()}-${crypto.randomUUID()}.json`;
  await bucket.put(objectKey, envelope, {
    httpMetadata: { contentType: "application/json" },
    customMetadata: {
      workspaceId,
      digest,
      format: "conclave-encrypted-backup-v1",
    },
  });
  return { key: objectKey, digest, sizeBytes: envelope.length };
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
// V6 Workstream Discuss / Work API
// =========================================================================

export function normalizeWorkstreamWorkConfig(value: unknown): {
  config: Record<string, unknown>;
  workerIds: string[];
} {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpError(400, "workConfig must be an object");
  }
  const input = value as Record<string, unknown>;
  if (
    Object.keys(input).some(
      (key) =>
        !["defaultWorkflowId", "workstreamInstructions", "bindings"].includes(
          key,
        ),
    ) ||
    typeof input.defaultWorkflowId !== "string" ||
    !WORKFLOW_IDS.includes(input.defaultWorkflowId as WorkflowId) ||
    !input.bindings ||
    typeof input.bindings !== "object" ||
    Array.isArray(input.bindings)
  ) {
    throw new HttpError(400, "workConfig is invalid");
  }
  const bindings = input.bindings as Record<string, unknown>;
  if (
    Object.keys(bindings).some(
      (bindingId) =>
        !WORKSTREAM_BINDING_IDS.includes(
          bindingId as (typeof WORKSTREAM_BINDING_IDS)[number],
        ),
    )
  ) {
    throw new HttpError(400, "workConfig contains an unsupported binding");
  }
  const workerIds = new Set<string>();
  const normalizedBindings: Record<string, Record<string, unknown>> = {};
  let workstreamInstructions: string | undefined;
  if (input.workstreamInstructions !== undefined) {
    if (
      typeof input.workstreamInstructions !== "string" ||
      input.workstreamInstructions.length > 4000
    ) {
      throw new HttpError(400, "workConfig workstreamInstructions is invalid");
    }
    const instructions = input.workstreamInstructions.trim();
    if (instructions) workstreamInstructions = instructions;
  }
  for (const [bindingId, rawBinding] of Object.entries(bindings)) {
    if (
      !rawBinding ||
      typeof rawBinding !== "object" ||
      Array.isArray(rawBinding)
    ) {
      throw new HttpError(400, `workConfig ${bindingId} binding is invalid`);
    }
    const binding = rawBinding as Record<string, unknown>;
    const normalized: Record<string, unknown> = {};
    if (
      Object.keys(binding).some(
        (key) =>
          ![
            "workerId",
            "model",
            "fallbackWorkerId",
            "additionalInstructions",
          ].includes(key),
      )
    ) {
      throw new HttpError(
        400,
        `workConfig ${bindingId} has unsupported fields`,
      );
    }
    for (const key of ["workerId", "model", "fallbackWorkerId"] as const) {
      if (binding[key] !== undefined) {
        const max = key === "model" ? 160 : 200;
        if (
          typeof binding[key] !== "string" ||
          binding[key].length > max ||
          (binding[key] as string).trim().length === 0
        ) {
          throw new HttpError(400, `workConfig ${key} is invalid`);
        }
        normalized[key] = binding[key].trim();
      }
    }
    if (typeof normalized.workerId !== "string") {
      throw new HttpError(400, `workConfig ${bindingId} requires workerId`);
    }
    workerIds.add(normalized.workerId);
    if (
      normalized.workerId &&
      normalized.workerId === normalized.fallbackWorkerId
    ) {
      throw new HttpError(
        400,
        "A fallback Worker must differ from its primary",
      );
    }
    if (binding.additionalInstructions !== undefined) {
      if (
        typeof binding.additionalInstructions !== "string" ||
        binding.additionalInstructions.length > 4000
      ) {
        throw new HttpError(
          400,
          "workConfig additionalInstructions is invalid",
        );
      }
      const instructions = binding.additionalInstructions.trim();
      if (instructions) normalized.additionalInstructions = instructions;
    }
    if (typeof normalized.fallbackWorkerId === "string")
      workerIds.add(normalized.fallbackWorkerId);
    normalizedBindings[bindingId] = normalized;
  }
  return {
    config: {
      defaultWorkflowId: input.defaultWorkflowId,
      ...(workstreamInstructions ? { workstreamInstructions } : {}),
      bindings: normalizedBindings,
    },
    workerIds: [...workerIds],
  };
}

export function workstreamMetadata(
  row: Record<string, unknown>,
): Record<string, unknown> {
  const accessPolicy = parseJson<Record<string, unknown>>(
    row.accessPolicyJson ?? row.access_policy_json,
    {},
  );
  return {
    id: String(row.id),
    projectId: String(row.projectId ?? row.project_id),
    name: String(row.name),
    status: String(row.status),
    lead: row.leadUserId ?? row.lead_user_id ?? null,
    accessPolicy,
    workConfig: parseJson(row.workConfigJson ?? row.configJson, {
      defaultWorkflowId: "full_cycle",
      bindings: {},
    }),
    primaryWorkspace:
      accessPolicy.primaryWorkspaceId ??
      accessPolicy.primary_workspace_id ??
      null,
    currentCheckpoint: null,
    queueStatus: "Idle",
    createdAt: String(row.createdAt ?? row.created_at),
    updatedAt: String(row.updatedAt ?? row.updated_at),
  };
}

export function sortWorkstreams<T extends Record<string, unknown>>(
  workstreams: T[],
  workstreamOrder?: unknown,
): T[] {
  const hasCustomOrder =
    Array.isArray(workstreamOrder) && workstreamOrder.length > 0;
  const orderMap = new Map<string, number>();
  if (hasCustomOrder) {
    (workstreamOrder as unknown[]).forEach((id, index) => {
      if (typeof id === "string") orderMap.set(id, index);
    });
  }
  return [...workstreams].sort((a, b) => {
    const aId = String(a.id ?? "");
    const bId = String(b.id ?? "");
    if (hasCustomOrder) {
      const aIndex = orderMap.has(aId) ? orderMap.get(aId)! : 999999;
      const bIndex = orderMap.has(bId) ? orderMap.get(bId)! : 999999;
      if (aIndex !== bIndex) {
        return aIndex - bIndex;
      }
    }
    const aCreated = String(a.createdAt ?? a.created_at ?? "");
    const bCreated = String(b.createdAt ?? b.created_at ?? "");
    return aCreated.localeCompare(bCreated);
  });
}

export function discussionReferences(value: unknown): readonly string[] {
  if (value === undefined) return [];
  if (!Array.isArray(value))
    throw new HttpError(400, "references must be an array");
  return value.flatMap((reference) => {
    if (typeof reference === "string" && reference.trim())
      return [reference.trim()];
    if (reference && typeof reference === "object") {
      const id = (reference as Record<string, unknown>).id;
      if (typeof id === "string" && id.trim()) return [id.trim()];
    }
    throw new HttpError(400, "references must contain non-empty identifiers");
  });
}

export type WorkstreamAccess = "view" | "discuss" | "execute" | "manage";

export async function authorizeWorkstreamAccess(
  request: Request,
  env: SecurityEnv,
  workstreamId: string,
  access: WorkstreamAccess,
  accessContext?: ExecutionContext,
): Promise<{
  context: SecurityContext;
  workstream: Workstream;
  projectId: string;
}> {
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT id, project_id AS projectId, name, status,
            access_policy_json AS accessPolicyJson, lead_user_id AS leadUserId,
            created_at AS createdAt, updated_at AS updatedAt
     FROM workstreams WHERE id = ?1`,
  )
    .bind(workstreamId)
    .first<Record<string, unknown>>();
  if (!row) throw new HttpError(404, "Workstream not found");

  const permission: Permission =
    access === "view"
      ? "projects:read"
      : access === "discuss"
        ? "projects:write"
        : access === "execute"
          ? "run.start"
          : "projects:write";
  const context = await authorizeRequest(
    request,
    env,
    permission,
    String(row.projectId),
    accessContext,
  );
  const membership = await env.CONCLAVE_DB.prepare(
    `SELECT id, project_id AS projectId, user_id AS userId, role,
            created_at AS createdAt, updated_at AS updatedAt
     FROM project_memberships WHERE project_id = ?1 AND user_id = ?2`,
  )
    .bind(String(row.projectId), context.userId)
    .first<ProjectMembership>();
  const workstream: Workstream = {
    id: String(row.id),
    projectId: String(row.projectId),
    name: String(row.name),
    status: String(row.status) as Workstream["status"],
    accessPolicy: {
      ...DEFAULT_WORKSTREAM_ACCESS_POLICY,
      ...parseJson(row.accessPolicyJson, {}),
    },
    lead: {
      userId: String(row.leadUserId),
      assignedAt: String(row.createdAt),
      assignedByUserId: String(row.leadUserId),
    },
    createdAt: String(row.createdAt),
    updatedAt: String(row.updatedAt),
  };
  const allowed =
    access === "view"
      ? canViewWorkstream(context.userId, membership, workstream)
      : access === "discuss"
        ? canDiscussWorkstream(context.userId, membership, workstream)
        : access === "execute"
          ? canExecuteWorkstream(context.userId, membership, workstream)
          : canManageWorkstream(context.userId, membership, workstream);
  if (!allowed)
    throw new HttpError(403, `Workstream ${access} access is required`);
  return { context, workstream, projectId: String(row.projectId) };
}

export async function workstreamProjectId(
  env: SecurityEnv,
  workstreamId: string,
): Promise<string> {
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT project_id AS projectId FROM workstreams WHERE id = ?1",
  )
    .bind(workstreamId)
    .first<{ projectId: string }>();
  if (!row) throw new HttpError(404, "Workstream not found");
  return row.projectId;
}

export type WorkEligibilityIssue = {
  stepKind: string;
  workerTypeId: string | null;
  code: string;
  message: string;
};

export function eligibilityMessage(
  stepKind: string,
  workerTypeId: string | null,
  code: string,
  readinessIssueCode?: string | null,
): string {
  const step = stepKind[0]?.toUpperCase() + stepKind.slice(1);
  const worker = workerTypeId
    ? `${workerTypeId === "chatgpt" ? "ChatGPT" : workerTypeId === "gemini" ? "Gemini" : workerTypeId} Worker`
    : "Worker";
  if (code === "binding_missing") return `${step}: choose a Worker.`;
  if (code === "worker_missing")
    return `${step}: the configured Worker is no longer available.`;
  if (code === "project_workspace_grant_missing")
    return `${step}: grant this Project access to the Worker's Workspace.`;
  if (code === "worker_disabled") return `${step}: ${worker} is disabled.`;
  if (code === "worker_not_ready") {
    if (
      readinessIssueCode === "sign_in_required" ||
      readinessIssueCode === "provider_authentication_required"
    ) {
      return `${step}: ${worker} needs sign-in.`;
    }
    return `${step}: ${worker} is not Ready${readinessIssueCode ? ` (${readinessIssueCode.replaceAll("_", " ")})` : ""}.`;
  }
  if (code === "worker_scheduling_disabled")
    return `${step}: ${worker} is not enabled for scheduling.`;
  if (code === "capability_missing")
    return `${step}: ${worker} does not have the capability required by this Step.`;
  if (code === "capability_not_granted")
    return `${step}: the Project Workspace grant does not allow this Step's capability.`;
  if (code === "permission_not_granted")
    return `${step}: the Project Workspace grant does not allow the access this Step needs.`;
  if (code === "worker_not_allowed_by_grant")
    return `${step}: this Worker is not included in the Project Workspace grant.`;
  if (code === "worker_not_allowed_by_workstream")
    return `${step}: this Worker is not allowed by the Workstream execution policy.`;
  if (code === "worker_type_not_allowed_by_workstream")
    return `${step}: this Worker type is not allowed by the Workstream execution policy.`;
  if (code === "workspace_offline")
    return `${step}: the Worker's Workspace is offline.`;
  if (code === "workspace_mismatch")
    return `${step}: all Steps in this Workflow must use Workers from the same Workspace.`;
  if (code === "workspace_not_primary")
    return `${step}: the Worker must be on this Workstream's primary Workspace.`;
  if (code === "engine_profile_unavailable")
    return `${step}: the Worker has no compatible Engine and Tool Profile release.`;
  if (code === "model_not_allowed")
    return `${step}: the selected model is not allowed by this Workstream.`;
  if (code === "model_required")
    return `${step}: choose a model allowed by this Workstream.`;
  if (code === "runtime_coordinator_unavailable")
    return "Workstream execution coordination is unavailable. Try again later.";
  return `${step}: ${worker} is not eligible to run this Work.`;
}

export async function validateWorkflowWorkerEligibility(
  env: SecurityEnv,
  projectId: string,
  workstreamId: string,
  workflow: BuiltinWorkflowDefinition,
  bindings: Record<string, { workerId?: string; model?: string }>,
  attachments: readonly unknown[] = [],
): Promise<{
  issues: WorkEligibilityIssue[];
  primaryWorkspaceId: string | null;
}> {
  const issues: WorkEligibilityIssue[] = [];
  let primaryWorkspaceId: string | null = null;
  const now = new Date().toISOString();
  for (const step of workflow.steps) {
    const bindingId = workflow.id === "direct" ? "direct" : step.kind;
    const binding = bindings[bindingId];
    if (!binding?.workerId) {
      issues.push({
        stepKind: step.kind,
        workerTypeId: null,
        code: "binding_missing",
        message: eligibilityMessage(step.kind, null, "binding_missing"),
      });
      continue;
    }
    const row = await env.CONCLAVE_DB.prepare(
      `SELECT i.workspace_id AS workspaceId, i.worker_type_id AS workerTypeId,
              i.activation_state AS activationState, i.readiness_state AS readinessState,
              i.readiness_issue_code AS readinessIssueCode, i.capabilities_json AS capabilitiesJson,
              i.engine_version AS engineVersion,
              i.profile_definition_id AS profileDefinitionId,
              i.profile_release_version AS profileReleaseVersion,
              vs.state AS schedulingState,
              g.id AS grantId, g.status AS grantStatus, g.expires_at AS grantExpiresAt,
              g.allowed_worker_ids_json AS allowedWorkerIdsJson,
              g.allowed_worker_capabilities_json AS grantCapabilitiesJson,
              g.allowed_permissions_json AS grantPermissionsJson,
              ep.allowed_models_json AS allowedModelsJson,
              ep.primary_workspace_id AS primaryWorkspaceId,
              ep.allowed_configured_worker_ids_json AS allowedWorkstreamWorkerIdsJson,
              ep.allowed_worker_type_ids_json AS allowedWorkstreamWorkerTypesJson,
              ep.allowed_providers_json AS allowedWorkstreamProvidersJson,
              ew.status AS workspaceStatus,
              wri.id AS runtimeIdentityId
         FROM workspace_worker_inventory i
         LEFT JOIN worker_scheduling vs ON vs.worker_id = i.worker_id
         LEFT JOIN workspace_project_grants g
           ON g.workspace_id = i.workspace_id AND g.project_id = ?2
         LEFT JOIN workstream_execution_policies ep ON ep.workstream_id = ?3
         LEFT JOIN execution_workspaces ew ON ew.id = i.workspace_id
         LEFT JOIN workspace_runtime_identities wri ON wri.workspace_id = i.workspace_id AND wri.revoked_at IS NULL
        WHERE i.worker_id = ?1`,
    )
      .bind(binding.workerId, projectId, workstreamId)
      .first<Record<string, unknown>>();
    if (!row) {
      const code = "worker_missing";
      issues.push({
        stepKind: step.kind,
        workerTypeId: null,
        code,
        message: eligibilityMessage(step.kind, null, code),
      });
      continue;
    }
    const workerTypeId = String(row.workerTypeId);
    const push = (code: string) =>
      issues.push({
        stepKind: step.kind,
        workerTypeId,
        code,
        message: eligibilityMessage(
          step.kind,
          workerTypeId,
          code,
          row.readinessIssueCode == null
            ? null
            : String(row.readinessIssueCode),
        ),
      });
    if (
      row.grantId == null ||
      row.grantStatus !== "active" ||
      (row.grantExpiresAt != null && String(row.grantExpiresAt) <= now)
    )
      push("project_workspace_grant_missing");
    if (row.activationState !== "enabled") push("worker_disabled");
    if (row.readinessState !== "ready") push("worker_not_ready");
    if (row.schedulingState !== "enabled") push("worker_scheduling_disabled");
    if (
      typeof row.engineVersion !== "string" ||
      !row.engineVersion ||
      typeof row.profileDefinitionId !== "string" ||
      !row.profileDefinitionId ||
      !Number.isSafeInteger(Number(row.profileReleaseVersion)) ||
      Number(row.profileReleaseVersion) < 1
    )
      push("engine_profile_unavailable");
    if (row.workspaceStatus !== "online") push("workspace_offline");
    if (row.runtimeIdentityId == null) push("workspace_offline");
    const capabilities = parseJson<unknown[]>(row.capabilitiesJson, []).filter(
      (value): value is string => typeof value === "string",
    );
    const requiredCapabilities = [...step.requiredCapabilities];
    if (
      !requiredCapabilities.every((capability) =>
        capabilities.includes(capability),
      )
    )
      push("capability_missing");
    const grantCapabilities = parseJson<unknown[]>(
      row.grantCapabilitiesJson,
      [],
    ).filter((value): value is string => typeof value === "string");
    if (
      grantCapabilities.length > 0 &&
      !requiredCapabilities.every((capability) =>
        grantCapabilities.includes(capability),
      )
    )
      push("capability_not_granted");
    const receivesAttachments =
      step.kind === "research" || step.kind === "implement";
    const requiredInputCapabilities = [
      "text",
      ...(receivesAttachments
        ? attachmentRequiredCapabilities(attachments)
        : []),
    ];
    const availableInputCapabilities = capabilities.filter((capability) =>
      (WORKER_INPUT_CAPABILITIES as readonly string[]).includes(capability),
    );
    for (const capability of requiredInputCapabilities) {
      if (!availableInputCapabilities.includes(capability)) {
        issues.push({
          stepKind: step.kind,
          workerTypeId,
          code: "input_capability_missing",
          message: inputCapabilityMessage(step.kind, workerTypeId, capability),
        });
      }
      if (
        grantCapabilities.length > 0 &&
        !grantCapabilities.includes(capability)
      ) {
        issues.push({
          stepKind: step.kind,
          workerTypeId,
          code: "input_capability_not_granted",
          message: inputCapabilityMessage(
            step.kind,
            workerTypeId,
            capability,
            true,
          ),
        });
      }
    }
    const grantPermissions = parseJson<unknown[]>(
      row.grantPermissionsJson,
      [],
    ).filter((value): value is string => typeof value === "string");
    const requiredPermissions = new Set<string>(["repository:read"]);
    if (step.requiredCapabilities.includes("workstream_write"))
      requiredPermissions.add("repository:write");
    if (step.requiredCapabilities.includes("test_execution"))
      requiredPermissions.add("shell:execute");
    if (
      ![...requiredPermissions].every((permission) =>
        grantPermissions.includes(permission),
      )
    )
      push("permission_not_granted");
    const allowedWorkerIds = parseJson<unknown[]>(
      row.allowedWorkerIdsJson,
      [],
    ).filter((value): value is string => typeof value === "string");
    if (
      allowedWorkerIds.length > 0 &&
      !allowedWorkerIds.includes(binding.workerId)
    )
      push("worker_not_allowed_by_grant");
    const allowedWorkstreamWorkerIds = parseJson<unknown[]>(
      row.allowedWorkstreamWorkerIdsJson,
      [],
    ).filter((value): value is string => typeof value === "string");
    if (
      allowedWorkstreamWorkerIds.length > 0 &&
      !allowedWorkstreamWorkerIds.includes(binding.workerId)
    )
      push("worker_not_allowed_by_workstream");
    const allowedWorkstreamTypes = parseJson<unknown[]>(
      row.allowedWorkstreamWorkerTypesJson,
      [],
    ).filter((value): value is string => typeof value === "string");
    if (
      allowedWorkstreamTypes.length > 0 &&
      !allowedWorkstreamTypes.includes(workerTypeId)
    )
      push("worker_type_not_allowed_by_workstream");
    const allowedProviders = parseJson<unknown[]>(
      row.allowedWorkstreamProvidersJson,
      [],
    ).filter((value): value is string => typeof value === "string");
    if (allowedProviders.length > 0 && !allowedProviders.includes(workerTypeId))
      push("worker_type_not_allowed_by_workstream");
    const allowedModels = parseJson<unknown[]>(
      row.allowedModelsJson,
      [],
    ).filter((value): value is string => typeof value === "string");
    if (allowedModels.length > 0 && !binding.model?.trim())
      push("model_required");
    else if (
      binding.model?.trim() &&
      allowedModels.length > 0 &&
      !allowedModels.includes(binding.model)
    )
      push("model_not_allowed");
    if (primaryWorkspaceId == null)
      primaryWorkspaceId = String(row.workspaceId);
    else if (primaryWorkspaceId !== String(row.workspaceId))
      push("workspace_mismatch");
    if (
      row.primaryWorkspaceId != null &&
      String(row.primaryWorkspaceId) !== String(row.workspaceId)
    )
      push("workspace_not_primary");
  }
  return { issues, primaryWorkspaceId };
}

export function attachmentRequiredCapabilities(
  attachments: readonly unknown[],
): string[] {
  const required = new Set<string>();
  for (const value of attachments) {
    if (!value || typeof value !== "object" || Array.isArray(value)) continue;
    const attachment = value as Record<string, unknown>;
    if (attachment.kind !== "file") continue;
    required.add("local_file");
    const mediaType =
      typeof attachment.mediaType === "string"
        ? attachment.mediaType.toLowerCase()
        : "";
    if (mediaType.startsWith("text/")) required.add("text");
    else if (mediaType.startsWith("image/")) required.add("image");
    else if (mediaType.startsWith("audio/")) required.add("audio");
    else if (mediaType.startsWith("video/")) required.add("video");
  }
  return [...required];
}

export function inputCapabilityMessage(
  stepKind: string,
  workerTypeId: string,
  capability: string,
  grantDenied = false,
): string {
  const step = stepKind[0]?.toUpperCase() + stepKind.slice(1);
  const worker =
    workerTypeId === "chatgpt"
      ? "ChatGPT Worker"
      : workerTypeId === "gemini"
        ? "Gemini Worker"
        : `${workerTypeId} Worker`;
  const input = capability === "local_file" ? "local file" : capability;
  return grantDenied
    ? `${step} ${worker} is not granted ${input} input by the Project Workspace grant.`
    : `${step} ${worker} does not support ${input} input.`;
}

export function summarizeTestCounts(text: string): string | null {
  const counts: string[] = [];
  for (const status of ["failed", "passed", "skipped"] as const) {
    const matches = text.matchAll(
      new RegExp(`\\b(\\d+)\\s+(?:tests?\\s+)?${status}\\b`, "gi"),
    );
    const match = [...matches].at(-1);
    if (match) counts.push(`${match[1]} ${status}`);
  }
  return counts.length > 0 ? counts.join(", ") : null;
}

export async function disconnectWorkspaceRuntime(
  env: SecurityEnv,
  workspaceId: string,
  runtimeId: string,
): Promise<boolean> {
  const gateway = env.CONCLAVE_WORKSPACE_GATEWAY;
  if (!gateway) return false;
  try {
    const response = await gateway
      .getByName(workspaceId)
      .fetch("https://workspace-gateway/disconnect-runtime", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ runtimeId }),
      });
    if (!response.ok) return false;
    return response.ok;
  } catch {
    return false;
  }
}

export async function getWorkspaceGatewayStatus(
  env: SecurityEnv,
  workspaceId: string,
): Promise<{ online: boolean } | null> {
  const gateway = env.CONCLAVE_WORKSPACE_GATEWAY;
  if (!gateway) return null;
  try {
    const response = await gateway
      .getByName(workspaceId)
      .fetch("https://workspace-gateway/status");
    if (!response.ok) return null;
    const status = (await response.json()) as { online?: unknown };
    if (typeof status.online !== "boolean") return null;
    return { online: status.online };
  } catch {
    return null;
  }
}

export function workspaceProjectGrantMetadata(
  row: Record<string, unknown>,
): Record<string, unknown> {
  return {
    id: String(row.id),
    projectId: String(row.project_id),
    workspaceId: String(row.workspace_id),
    workspaceName:
      row.workspace_name == null ? null : String(row.workspace_name),
    workspaceOwnerUserId:
      row.owner_user_id == null ? null : String(row.owner_user_id),
    grantedByUserId: String(row.granted_by_user_id),
    status: String(row.status),
    scope: String(row.scope),
    repositoryMappings: parseJson(row.repository_mappings_json, []),
    pathMappings: parseJson(row.path_mappings_json, []),
    allowedWorkerIds: parseJson(row.allowed_worker_ids_json, []),
    allowedWorkerCapabilities: parseJson(
      row.allowed_worker_capabilities_json,
      [],
    ),
    allowedPermissions: parseJson(row.allowed_permissions_json, []),
    networkPolicy: parseJson(row.network_policy_json, {}),
    concurrency: parseJson(row.concurrency_json, {}),
    budget: parseJson(row.budget_json, null),
    requiresStepUp: Boolean(row.requires_step_up),
    expiresAt: row.expires_at ?? null,
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}

export async function loadWorkspaceProjectGrant(
  env: SecurityEnv,
  grantId: string,
): Promise<Record<string, unknown> | null> {
  return env.CONCLAVE_DB.prepare(
    `SELECT g.*, ew.name AS workspace_name, ew.owner_user_id
     FROM workspace_project_grants g
     JOIN execution_workspaces ew ON ew.id = g.workspace_id
     WHERE g.id = ?1`,
  )
    .bind(grantId)
    .first<Record<string, unknown>>();
}

export function grantJsonArray(value: unknown, field: string): string {
  if (value === undefined) return "[]";
  if (
    !Array.isArray(value) ||
    value.some((item) => typeof item !== "object" || item === null)
  ) {
    throw new HttpError(400, `${field} must be an array of objects`);
  }
  return JSON.stringify(value);
}

export function grantStringArray(value: unknown, field: string): string {
  if (value === undefined) return "[]";
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    throw new HttpError(400, `${field} must be an array of strings`);
  }
  return JSON.stringify(value);
}

export async function grantStepUpIfRequired(
  env: SecurityEnv,
  context: SecurityContext,
  scope: string,
  body: Record<string, unknown>,
): Promise<number> {
  if (scope !== "full_workspace") return 0;
  if (body.confirmFullWorkspace !== true) {
    throw new HttpError(
      400,
      "Full Workspace access requires explicit confirmation",
    );
  }
  const verified = await hasRecentStepUp(
    env.CONCLAVE_DB,
    context.userId,
    context.sessionId,
    SENSITIVE_OPERATIONS.fullWorkspaceGrant,
  );
  if (!verified)
    throw new HttpError(428, "Recent step-up authentication is required");
  return 1;
}

export async function createWorkspaceProjectGrant(
  request: Request,
  env: SecurityEnv,
  context: SecurityContext,
  projectId: string,
  workspaceId: string,
): Promise<Response> {
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const scope = String(body.scope ?? "project_repository");
  if (
    !["project_repository", "selected_paths", "full_workspace"].includes(scope)
  ) {
    throw new HttpError(400, "Unsupported Workspace Project Grant scope");
  }
  const project = await env.CONCLAVE_DB.prepare(
    "SELECT id FROM projects WHERE id = ?1",
  )
    .bind(projectId)
    .first<{ id: string }>();
  if (!project) throw new HttpError(404, "Project not found");
  const workspace = await env.CONCLAVE_DB.prepare(
    "SELECT id, owner_user_id, status FROM execution_workspaces WHERE id = ?1",
  )
    .bind(workspaceId)
    .first<{ id: string; owner_user_id: string; status: string }>();
  if (!workspace) throw new HttpError(404, "Workspace not found");
  if (
    workspace.owner_user_id !== context.userId ||
    workspace.status === "revoked"
  ) {
    throw new HttpError(
      403,
      "Only the Workspace owner can grant this Workspace",
    );
  }
  let membership: { role: string } | null = null;
  try {
    membership = await authorizeProjectMembership(
      env.CONCLAVE_DB,
      context,
      projectId,
      "projects:write",
    );
  } catch {
    // A Workspace owner may grant their own Workspace to a Project without
    // becoming a Project collaborator; the Project still controls use.
  }
  await authorizeWorkspaceOwner(
    env.CONCLAVE_DB,
    context,
    workspaceId,
    "workspace:manage",
  );
  const existingGrant = await env.CONCLAVE_DB.prepare(
    `SELECT id FROM workspace_project_grants
     WHERE project_id = ?1 AND workspace_id = ?2
       AND status IN ('active', 'suspended')
     LIMIT 1`,
  )
    .bind(projectId, workspaceId)
    .first<{ id: string }>();
  if (existingGrant) {
    throw new HttpError(
      409,
      "This Workspace is already connected to the Project",
    );
  }
  if (
    membership?.role === "collaborator" &&
    body.confirmContribution !== true
  ) {
    throw new HttpError(
      400,
      "Collaborators must explicitly confirm Workspace contribution",
    );
  }
  const requiresStepUp = await grantStepUpIfRequired(env, context, scope, body);
  const repositoryMappings = grantJsonArray(
    body.repositoryMappings,
    "repositoryMappings",
  );
  const pathMappings = grantJsonArray(body.pathMappings, "pathMappings");
  const allowedWorkerIds = grantStringArray(
    body.allowedWorkerIds,
    "allowedWorkerIds",
  );
  const allowedWorkerCapabilities = grantStringArray(
    body.allowedWorkerCapabilities,
    "allowedWorkerCapabilities",
  );
  const allowedPermissions = grantStringArray(
    body.allowedPermissions,
    "allowedPermissions",
  );
  const networkPolicy =
    body.networkPolicy === undefined
      ? '{"mode":"deny_all","allowedHosts":[]}'
      : JSON.stringify(body.networkPolicy);
  const concurrency =
    body.concurrency === undefined
      ? '{"maxConcurrentAssignments":1}'
      : JSON.stringify(body.concurrency);
  const budget = body.budget === undefined ? null : JSON.stringify(body.budget);
  const expiresAt = typeof body.expiresAt === "string" ? body.expiresAt : null;
  const now = new Date().toISOString();
  const id = `workspace-project-grant-${crypto.randomUUID().slice(0, 16)}`;
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO workspace_project_grants
       (id, project_id, workspace_id, granted_by_user_id, status, scope,
        repository_mappings_json, path_mappings_json, allowed_worker_ids_json,
        allowed_worker_capabilities_json, allowed_permissions_json,
        network_policy_json, concurrency_json, budget_json, requires_step_up,
        expires_at, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, 'active', ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?16)
     ON CONFLICT(id, project_id, workspace_id) DO NOTHING`,
  )
    .bind(
      id,
      projectId,
      workspaceId,
      context.userId,
      scope,
      repositoryMappings,
      pathMappings,
      allowedWorkerIds,
      allowedWorkerCapabilities,
      allowedPermissions,
      networkPolicy,
      concurrency,
      budget,
      requiresStepUp,
      expiresAt,
      now,
    )
    .run();
  await recordAudit(
    env,
    context,
    "workspace.project_grant.created",
    "workspace_project_grant",
    id,
    {
      projectId,
      workspaceId,
      scope,
      requiresStepUp: Boolean(requiresStepUp),
    },
  );
  const grant = await loadWorkspaceProjectGrant(env, id);
  return json(
    {
      grant: grant
        ? workspaceProjectGrantMetadata(grant)
        : { id, projectId, workspaceId, scope },
    },
    { status: 201 },
  );
}

export function assertSafeProviderMetadata(
  value: unknown,
): Record<string, unknown> {
  if (value === undefined) return {};
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpError(400, "providerMetadata must be an object");
  }
  const forbidden = /secret|token|password|api[_-]?key|private/i;
  const metadata = value as Record<string, unknown>;
  if (Object.keys(metadata).some((key) => forbidden.test(key))) {
    throw new HttpError(400, "providerMetadata cannot contain credentials");
  }
  return metadata;
}

export async function handleWorkspaceGatewayConnect(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const requestId = requestIdFor(request);
  const url = new URL(request.url);
  const workspaceRuntimeId = url.searchParams.get("workspaceRuntimeId");
  const upgradeHeaderPresent =
    request.headers.get("Upgrade")?.toLowerCase() === "websocket";
  const authorizationPresent = request.headers.has("Authorization");
  logStructured(
    "info",
    "GW-01 workspace_gateway_request_received",
    { requestId },
    {
      method: request.method,
      path: url.pathname,
      upgradeHeaderPresent,
      runtimeIdPresent: Boolean(workspaceRuntimeId),
      authorizationPresent,
    },
  );

  if (!upgradeHeaderPresent) {
    logStructured(
      "warn",
      "GW-01 workspace_gateway_upgrade_rejected",
      { requestId },
      { reason: "upgrade_header_missing" },
    );
    return json({ error: "Expected WebSocket upgrade" }, { status: 426 });
  }

  const authToken =
    extractBearerToken(request.headers) ??
    url.searchParams.get("token") ??
    url.searchParams.get("authToken");

  if (!workspaceRuntimeId || !authToken) {
    logStructured(
      "warn",
      "GW-02 runtime_authentication_not_started",
      { requestId },
      {
        runtimeIdPresent: Boolean(workspaceRuntimeId),
        credentialPresent: Boolean(authToken),
      },
    );
    return json(
      { error: "workspaceRuntimeId and authToken are required" },
      { status: 401 },
    );
  }

  logStructured("info", "GW-02 runtime_authentication_started", {
    requestId,
    runtimeId: workspaceRuntimeId,
  });
  let workspace: { workspaceId: string } | null;
  try {
    const tokenHash = await hashToken(authToken);
    workspace = await env.CONCLAVE_DB.prepare(
      `SELECT wri.workspace_id AS workspaceId
       FROM workspace_runtime_identities wri
       JOIN execution_workspaces ew ON ew.id = wri.workspace_id
       WHERE wri.id = ?1 AND wri.credential_token_hash = ?2
         AND wri.revoked_at IS NULL AND ew.status <> 'revoked'`,
    )
      .bind(workspaceRuntimeId, tokenHash)
      .first<{ workspaceId: string }>();
  } catch (error) {
    logStructured(
      "error",
      "GW-03 runtime_authentication_failed",
      { requestId, runtimeId: workspaceRuntimeId },
      { reason: "credential_lookup_failed" },
    );
    throw error;
  }

  if (!workspace) {
    logStructured(
      "warn",
      "GW-03 runtime_authentication_failed",
      { requestId, runtimeId: workspaceRuntimeId },
      { reason: "invalid_or_revoked_credential" },
    );
    return json(
      { error: "Invalid or revoked Workspace runtime credential" },
      { status: 401 },
    );
  }
  logStructured("info", "GW-03 runtime_authenticated", {
    requestId,
    runtimeId: workspaceRuntimeId,
    workspaceId: workspace.workspaceId,
  });

  if (!env.CONCLAVE_WORKSPACE_GATEWAY) {
    logStructured(
      "error",
      "GW-04 workspace_gateway_forward_rejected",
      {
        requestId,
        runtimeId: workspaceRuntimeId,
        workspaceId: workspace.workspaceId,
      },
      { reason: "gateway_binding_missing" },
    );
    return json(
      { error: "Workspace Gateway is not configured" },
      { status: 503 },
    );
  }
  const stub = env.CONCLAVE_WORKSPACE_GATEWAY.getByName(workspace.workspaceId);
  logStructured("info", "GW-04 forwarding_to_workspace_gateway_do", {
    requestId,
    runtimeId: workspaceRuntimeId,
    workspaceId: workspace.workspaceId,
  });
  try {
    // Preserve the original upgrade Request. CF-Ray is already part of it and
    // is used as the shared request ID by the Durable Object.
    const response = await stub.fetch(request);
    logStructured(
      response.status === 101 ? "info" : "warn",
      "GW-04 workspace_gateway_do_response_received",
      {
        requestId,
        runtimeId: workspaceRuntimeId,
        workspaceId: workspace.workspaceId,
      },
      { status: response.status },
    );
    return response;
  } catch (error) {
    logStructured(
      "error",
      "GW-04 workspace_gateway_forward_failed",
      {
        requestId,
        runtimeId: workspaceRuntimeId,
        workspaceId: workspace.workspaceId,
      },
      {
        errorName: error instanceof Error ? error.name : "UnknownError",
      },
    );
    throw error;
  }
}

export async function handleWorkspaceRuntimeTransport(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  if (!env.CONCLAVE_WORKSPACE_GATEWAY)
    return json(
      { error: "Workspace Gateway is not configured" },
      { status: 503 },
    );
  const url = new URL(request.url);
  const body = (await request.json().catch(() => null)) as Record<
    string,
    unknown
  > | null;
  if (!body) return json({ error: "Invalid request body" }, { status: 400 });
  const authToken = extractBearerToken(request.headers);
  if (!authToken)
    return json(
      { error: "Workspace runtime credential required" },
      { status: 401 },
    );
  let workspaceId: string | null = null;
  if (url.pathname === "/api/workspace-runtime/sessions") {
    if (typeof body.workspaceRuntimeId !== "string")
      return json({ error: "workspaceRuntimeId is required" }, { status: 400 });
    const authorized = await env.CONCLAVE_DB.prepare(
      `SELECT wri.workspace_id AS workspaceId FROM workspace_runtime_identities wri
       JOIN execution_workspaces ew ON ew.id = wri.workspace_id
       WHERE wri.id = ?1 AND wri.credential_token_hash = ?2
       AND wri.revoked_at IS NULL AND ew.status <> 'revoked'`,
    )
      .bind(body.workspaceRuntimeId, await hashToken(authToken))
      .first<{ workspaceId: string }>();
    workspaceId = authorized?.workspaceId ?? null;
  } else {
    if (typeof body.sessionId !== "string")
      return json({ error: "sessionId is required" }, { status: 400 });
    const session = await env.CONCLAVE_DB.prepare(
      "SELECT workspace_id AS workspaceId FROM workspace_sessions WHERE id = ?1 AND disconnected_at IS NULL",
    )
      .bind(body.sessionId)
      .first<{ workspaceId: string }>();
    workspaceId = session?.workspaceId ?? null;
  }
  if (!workspaceId)
    return json(
      { error: "Runtime session not found or credential revoked" },
      { status: 401 },
    );
  const stub = env.CONCLAVE_WORKSPACE_GATEWAY.getByName(workspaceId);
  let internalPath = "/runtime/" + url.pathname.split("/").pop();
  if (url.pathname === "/api/workspace-runtime/sessions")
    internalPath = "/runtime/sessions";
  else if (url.pathname.endsWith("/close")) internalPath = "/runtime/close";
  const forwarded = new Request(
    `https://workspace-gateway.internal${internalPath}`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${authToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    },
  );
  return stub.fetch(forwarded);
}

export async function validateAndClaimCiEvidence(
  env: Env,
  runId: string,
  input: unknown,
): Promise<string> {
  let evidence;
  try {
    evidence = parseMachineCheckEvidence(input);
  } catch (error) {
    throw new HttpError(
      400,
      `Invalid CI evidence: ${error instanceof Error ? error.message : "unknown"}`,
    );
  }
  if (evidence.runId !== runId)
    throw new HttpError(409, "CI evidence does not belong to this run");
  const expected = await env.CONCLAVE_DB.prepare(
    `SELECT r.policy_snapshot_json, p.workspace_id
     FROM runs r JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id
     WHERE r.id = ?1`,
  )
    .bind(runId)
    .first<{
      policy_snapshot_json: string;
      workspace_id: string | null;
    }>();
  if (!expected) throw new HttpError(404, "Run not found");
  let policy: Record<string, unknown> = {};
  try {
    const parsed: unknown = JSON.parse(expected.policy_snapshot_json);
    if (typeof parsed === "object" && parsed !== null)
      policy = parsed as Record<string, unknown>;
  } catch {
    throw new HttpError(409, "Run has no valid CI correlation policy");
  }
  const expectedRepository =
    typeof policy.repositoryId === "string" ? policy.repositoryId : undefined;
  const expectedCommitSha =
    typeof policy.expectedCommitSha === "string"
      ? policy.expectedCommitSha
      : undefined;
  const allowedWorkflows = Array.isArray(policy.allowedWorkflows)
    ? policy.allowedWorkflows.filter(
        (value): value is string => typeof value === "string",
      )
    : ["CI"];
  const expectedChecks = Array.isArray(policy.expectedChecks)
    ? policy.expectedChecks.filter(
        (value): value is string => typeof value === "string",
      )
    : [];
  if (!expectedRepository || evidence.repositoryId !== expectedRepository)
    throw new HttpError(409, "CI evidence repository does not match this run");
  if (!expectedCommitSha || evidence.commitSha !== expectedCommitSha)
    throw new HttpError(409, "CI evidence commit SHA does not match this run");
  if (!allowedWorkflows.includes(evidence.workflow))
    throw new HttpError(409, "CI workflow is not allowed for this run");
  const receivedChecks = new Set(evidence.checks.map((check) => check.name));
  for (const expectedCheck of expectedChecks) {
    if (!receivedChecks.has(expectedCheck))
      throw new HttpError(
        409,
        `Expected CI check is missing: ${expectedCheck}`,
      );
  }
  if (!expected.workspace_id)
    throw new HttpError(409, "Run has no workspace correlation");
  try {
    await env.CONCLAVE_DB.prepare(
      `INSERT INTO ci_evidence
       (evidence_id, workspace_id, run_id, repository_id, external_run_id, revision, workflow,
        source, conclusion, checks_json, smoke_tests_json, health_checks_json, raw_payload_json,
        observed_at, status, claimed_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, 'claimed', ?15)`,
    )
      .bind(
        evidence.evidenceId,
        expected.workspace_id,
        runId,
        evidence.repositoryId,
        evidence.externalRunId,
        evidence.commitSha,
        evidence.workflow,
        evidence.source,
        evidence.conclusion,
        JSON.stringify(evidence.checks),
        JSON.stringify(evidence.smokeTests),
        JSON.stringify(evidence.healthChecks),
        JSON.stringify(input),
        evidence.observedAt,
        new Date().toISOString(),
      )
      .run();
  } catch (error) {
    throw new HttpError(
      409,
      `CI evidence was already received: ${errorMessage(error)}`,
    );
  }
  return evidence.evidenceId;
}

export async function authorizeToolProfileAdmin(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
  permission: "profiles:admin" | "profiles:release:manage" = "profiles:admin",
): Promise<SecurityContext> {
  const actor = await securityContext(request, env, ctx);
  const adminUserIds = (env.CONCLAVE_PROFILE_ADMIN_USER_IDS ?? "")
    .split(",")
    .map((userId) => userId.trim())
    .filter(Boolean);
  try {
    authorizeSecurityProfileAdmin(actor, adminUserIds, permission);
  } catch {
    throw new HttpError(403, "Profile administrator authorization is required");
  }
  return actor;
}

export async function readToolProfileAdminBody(
  request: Request,
  allowed: readonly string[],
): Promise<Record<string, unknown>> {
  const maxBytes = 384 * 1024;
  const contentLength = Number(request.headers.get("content-length") ?? 0);
  if (contentLength > maxBytes)
    throw new HttpError(413, "request body is too large");
  const reader = request.body?.getReader();
  if (!reader) throw new HttpError(400, "request body is required");
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxBytes) {
        await reader.cancel();
        throw new HttpError(413, "request body is too large");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new HttpError(400, "request body must be valid JSON");
  }
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    Object.keys(value).some((key) => !allowed.includes(key))
  ) {
    throw new HttpError(400, "request body contains unsupported fields");
  }
  return value as Record<string, unknown>;
}

export function toolProfileReleaseVersion(value: string): number {
  if (!/^\d{1,10}$/.test(value))
    throw new HttpError(400, "releaseVersion is invalid");
  const version = Number(value);
  if (
    !Number.isSafeInteger(version) ||
    version < 1 ||
    version > 2_147_483_647
  ) {
    throw new HttpError(400, "releaseVersion is invalid");
  }
  return version;
}
export { handleSession, handleCompleteStepUp } from "./auth.js";
export {
  handleListProjects,
  handleCreateProject,
  handleGetProject,
  handleUpdateProject,
  handleDeleteProject,
  handleListProjectMembers,
  handleListProjectInvitations,
  handleListProjectAudit,
  handleCreateProjectInvitation,
  handleChangeProjectMemberRole,
  handleRemoveProjectMember,
  handleExpireProjectInvitation,
  handleAcceptProjectInvitation,
} from "./projects.js";
export {
  handleListWorkspaces,
  handleCreateWorkspace,
  handleCreateWorkspacePairingIntent,
  handleCheckWorkspaceOwnership,
  handleDisconnectDesktopWorkspace,
  handleReleaseDesktopWorkspace,
  handleRegisterWorkspaceFromDesktop,
  handleGetWorkspacePairingIntent,
  handleRegenerateWorkspacePairingIntent,
  handleCancelWorkspacePairingIntent,
  handleGetWorkspace,
  handleUpdateWorkspace,
  handleRevokeWorkspace,
  handleExportWorkspaceAudit,
  handleUploadArtifact,
  handleGetArtifact,
  handleVerifyWorkspaceBackup,
  handleCreateWorkspaceBackup,
  handleCreateWorkspaceEnrollment,
  handleListWorkspaceEnrollments,
  handleRevokeWorkspaceEnrollment,
  handleRedeemWorkspaceEnrollment,
  handleUnpairWorkspaceRuntime,
  handleListWorkspaceProjectGrants,
  handleCreateWorkspaceProjectGrant,
  handleListProjectWorkspaces,
  handleRequestProjectWorkspace,
  handleUpdateWorkspaceProjectGrant,
  handleRevokeWorkspaceProjectGrant,
} from "./workspaces.js";
export {
  handleListProjectWorkstreams,
  handleCreateWorkstream,
  handleUpdateWorkstream,
  handleDeleteWorkstream,
  handleListWorkstreamCheckouts,
  handleProvisionWorkstreamCheckout,
  handleListDiscussionMessages,
  handleCreateDiscussionMessage,
  handleEditDiscussionMessage,
} from "./workstreams.js";
export {
  handleValidateWorkRequest,
  handleCreateWorkRequest,
  handleRetryWorkRequest,
  handleGetWorkRequest,
  handleListWorkRequests,
  handleCancelWorkRequest,
  handleStudioSnapshot,
  handleProjectReadModel,
  handleRunCommand,
} from "./work.js";
export {
  handleResolveToolProfileChannels,
  handleSetWorkspaceToolProfileChannel,
  handleCreateToolProfileDefinition,
  handleCreateApprovedLogicalWorker,
  handleCreateDraftToolProfileRelease,
  handleUpdateDraftToolProfileRelease,
  handlePublishDraftToolProfileRelease,
  handlePromoteToolProfileRelease,
  handleChangeToolProfileReleaseLifecycle,
  handleListToolProfileReleases,
  handleListToolProfileReleaseAudit,
  handleListWorkspaceWorkerInventory,
} from "./profiles.js";
export {
  handleGetLatestWorkspaceRelease,
  handleGetWorkspaceRelease,
  handleDownloadWorkspaceRelease,
  handlePublishWorkspaceRelease,
  handleRevokeWorkspaceRelease,
  handleGetReleaseTrustState,
  handleRevokeReleaseSigningKey,
} from "./releases.js";
