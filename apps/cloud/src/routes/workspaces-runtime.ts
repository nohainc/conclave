import { logStructured, requestIdFor } from "../observability.js";
import { MAX_ARTIFACT_UPLOAD_BYTES } from "./handlers.js";
import { SENSITIVE_OPERATIONS } from "../auth/index.js";
import {
  extractBearerToken,
  hashToken,
  computePackageDigest,
  authorizeProjectMembership,
  authorizeWorkspaceOwner,
} from "@conclave/security";
import { createEventPublisher } from "../event-publisher.js";
import {
  HttpError,
  artifactMetadata,
  artifactName,
  authorizeRequest,
  createWorkspaceProjectGrant,
  disconnectWorkspaceRuntime,
  findDesktopHumanSession,
  getWorkspaceGatewayStatus,
  grantStepUpIfRequired,
  json,
  loadWorkspaceProjectGrant,
  parseJson,
  recordAudit,
  recordPairingAuditEvent,
  requireRecentStepUp,
  requireWorkspaceContext,
  requiredString,
  securityContext,
  workspaceProjectGrantMetadata,
  workspaceOwnerContext,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";
import { hasControlCharacters } from "./workspaces-shared.js";

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

export async function handleCreateWorkspaceEnrollment(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  await requireWorkspaceContext(context, env, workspaceId);

  const body = parseJson<{ expiresHours?: number }>(await request.text(), {});
  const enrollmentId = `enr-${crypto.randomUUID().slice(0, 12)}`;
  const token = `conclave_enroll_${crypto.randomUUID().replace(/-/g, "")}`;
  const tokenHash = await hashToken(token);
  const now = new Date();
  const expiresHours = body.expiresHours ?? 24;
  if (
    !Number.isInteger(expiresHours) ||
    expiresHours < 1 ||
    expiresHours > 168
  ) {
    return json(
      { error: "expiresHours must be an integer between 1 and 168" },
      { status: 400 },
    );
  }
  const expiresAt = new Date(
    now.getTime() + expiresHours * 3600 * 1000,
  ).toISOString();
  const createdAt = now.toISOString();

  await env.CONCLAVE_DB.prepare(
    `INSERT INTO workspace_enrollments (id, workspace_id, token_hash, created_by_user_id, expires_at, created_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
  )
    .bind(
      enrollmentId,
      workspaceId,
      tokenHash,
      context.userId,
      expiresAt,
      createdAt,
    )
    .run();

  await recordAudit(
    env,
    context,
    "workspace.enrollment.created",
    "workspace_enrollment",
    enrollmentId,
    { expiresAt, oneTime: true },
    workspaceId,
  );

  return json(
    {
      id: enrollmentId,
      token,
      workspaceId,
      expiresAt,
      createdAt,
    },
    { status: 201 },
  );
}

export async function handleListWorkspaceEnrollments(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  await requireWorkspaceContext(context, env, workspaceId);

  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT id, workspace_id as workspaceId, created_by_user_id as createdByUserId, expires_at as expiresAt, used_at as usedAt, revoked_at as revokedAt, created_at as createdAt
     FROM workspace_enrollments WHERE workspace_id = ?1 ORDER BY created_at DESC`,
  )
    .bind(workspaceId)
    .all();

  return json({ enrollments: rows.results ?? [] });
}

export async function handleRevokeWorkspaceEnrollment(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  enrollmentId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  await requireWorkspaceContext(context, env, workspaceId);
  await requireRecentStepUp(
    env,
    context,
    SENSITIVE_OPERATIONS.workspaceEnrollmentRevoke,
  );

  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `UPDATE workspace_enrollments SET revoked_at = ?1 WHERE id = ?2 AND workspace_id = ?3`,
  )
    .bind(now, enrollmentId, workspaceId)
    .run();

  await recordAudit(
    env,
    context,
    "workspace.enrollment.revoked",
    "workspace_enrollment",
    enrollmentId,
  );

  return json({ ok: true, revokedAt: now });
}

export async function handleRedeemWorkspaceEnrollment(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const body = parseJson<{
    token?: string;
    name?: string;
    hostname?: string;
    installationId?: string;
    allowRecovery?: boolean;
    platform?: string;
    architecture?: string;
    appVersion?: string;
    runtimeCapabilities?: unknown;
  }>(await request.text(), {});

  const token = body.token?.trim();
  if (!token) {
    await recordPairingAuditEvent(env, null, "pairing.rejected", "failure", {
      reason: "missing_token",
    });
    return json({ error: "Enrollment token is required" }, { status: 400 });
  }

  const tokenHash = await hashToken(token);
  const now = new Date().toISOString();
  const pairingIntent = await env.CONCLAVE_DB.prepare(
    `SELECT pairing_id AS pairingId, owner_user_id AS ownerUserId,
            expires_at AS expiresAt, cancelled_at AS cancelledAt,
            used_at AS usedAt, claimed_workspace_id AS claimedWorkspaceId
       FROM workspace_pairing_intents
      WHERE token_hash = ?1`,
  )
    .bind(tokenHash)
    .first<{
      pairingId: string;
      ownerUserId: string;
      expiresAt: string;
      cancelledAt: string | null;
      usedAt: string | null;
      claimedWorkspaceId: string | null;
    }>();
  if (pairingIntent) {
    if (pairingIntent.expiresAt <= now) {
      await recordPairingAuditEvent(
        env,
        pairingIntent.ownerUserId,
        "pairing.rejected",
        "failure",
        { pairingId: pairingIntent.pairingId, reason: "expired" },
      );
      return json(
        { error: "Pairing code has expired", code: "pairing_code_expired" },
        { status: 410 },
      );
    }
    if (pairingIntent.cancelledAt) {
      await recordPairingAuditEvent(
        env,
        pairingIntent.ownerUserId,
        "pairing.rejected",
        "failure",
        { pairingId: pairingIntent.pairingId, reason: "cancelled" },
      );
      return json(
        { error: "Pairing code was cancelled", code: "pairing_code_cancelled" },
        { status: 409 },
      );
    }
    if (pairingIntent.usedAt) {
      await recordPairingAuditEvent(
        env,
        pairingIntent.ownerUserId,
        "pairing.rejected",
        "failure",
        { pairingId: pairingIntent.pairingId, reason: "already_claimed" },
      );
      return json(
        {
          error:
            "Pairing code was already claimed; retry cannot create another Workspace",
          code: "pairing_already_claimed",
          workspaceId: pairingIntent.claimedWorkspaceId,
        },
        { status: 409 },
      );
    }

    const owner = await env.CONCLAVE_DB.prepare(
      "SELECT status FROM users WHERE id = ?1",
    )
      .bind(pairingIntent.ownerUserId)
      .first<{ status: string }>();
    if (!owner || owner.status !== "active") {
      await recordPairingAuditEvent(
        env,
        pairingIntent.ownerUserId,
        "pairing.rejected",
        "denied",
        { pairingId: pairingIntent.pairingId, reason: "owner_inactive" },
      );
      return json(
        { error: "Pairing owner is no longer active", code: "account_revoked" },
        { status: 403 },
      );
    }

    const installationId = body.installationId?.trim();
    const name = body.name?.trim();
    if (
      !installationId ||
      !/^install_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
        installationId,
      )
    ) {
      await recordPairingAuditEvent(
        env,
        pairingIntent.ownerUserId,
        "pairing.rejected",
        "failure",
        {
          pairingId: pairingIntent.pairingId,
          reason: "invalid_installation_id",
        },
      );
      return json(
        { error: "A valid stable installationId is required to claim pairing" },
        { status: 400 },
      );
    }
    const installationHistory = await env.CONCLAVE_DB.prepare(
      `SELECT identity.workspace_id AS workspaceId,
              identity.revoked_at AS revokedAt,
              workspace.status AS workspaceStatus,
              workspace.owner_user_id AS ownerUserId
         FROM workspace_runtime_identities identity
         JOIN execution_workspaces workspace
           ON workspace.id = identity.workspace_id
        WHERE identity.installation_id = ?1
        ORDER BY identity.created_at DESC`,
    )
      .bind(installationId)
      .all<{
        workspaceId: string;
        revokedAt: string | null;
        workspaceStatus: string;
        ownerUserId: string;
      }>();
    const historicalBindings = installationHistory.results ?? [];
    const activeBinding = historicalBindings.find(
      (binding) =>
        binding.revokedAt === null && binding.workspaceStatus !== "revoked",
    );
    if (activeBinding) {
      const sameOwner = activeBinding.ownerUserId === pairingIntent.ownerUserId;
      await recordPairingAuditEvent(
        env,
        pairingIntent.ownerUserId,
        "pairing.rejected",
        "denied",
        {
          pairingId: pairingIntent.pairingId,
          reason: "installation_already_paired",
          workspaceId: activeBinding.workspaceId,
        },
      );
      return json(
        {
          error: sameOwner
            ? "This installation is already paired to a Workspace owned by this account. Reconnect with its saved runtime credential."
            : "This Conclave Workspace installation is already paired. Disconnect it before pairing with another account.",
          code: "installation_already_paired",
          workspaceId: activeBinding.workspaceId,
        },
        { status: 409 },
      );
    }
    if (historicalBindings.length > 0) {
      if (body.allowRecovery !== true) {
        await recordPairingAuditEvent(
          env,
          pairingIntent.ownerUserId,
          "pairing.rejected",
          "denied",
          {
            pairingId: pairingIntent.pairingId,
            reason: "installation_recovery_required",
            workspaceId: historicalBindings[0]?.workspaceId,
          },
        );
        return json(
          {
            error:
              "This installation was previously paired. Explicitly unpair it in Conclave Workspace before recovering its pairing",
            code: "installation_recovery_required",
            workspaceId: historicalBindings[0]?.workspaceId,
          },
          { status: 409 },
        );
      }
    }

    const hostname = body.hostname?.trim();
    const platform = body.platform?.trim().toLowerCase();
    const architecture = body.architecture?.trim().toLowerCase();
    const appVersion = body.appVersion?.trim();
    if (
      !hostname ||
      hostname.length > 253 ||
      hasControlCharacters(hostname) ||
      !["macos", "linux", "windows"].includes(platform ?? "") ||
      !["arm64", "x64"].includes(architecture ?? "") ||
      !appVersion ||
      appVersion.length > 64 ||
      !/^[0-9A-Za-z.+-]+$/.test(appVersion)
    ) {
      await recordPairingAuditEvent(
        env,
        pairingIntent.ownerUserId,
        "pairing.rejected",
        "failure",
        {
          pairingId: pairingIntent.pairingId,
          reason: "invalid_machine_metadata",
        },
      );
      return json(
        { error: "Machine metadata is invalid or exceeds supported bounds" },
        { status: 400 },
      );
    }
    if (!name || name.length > 120 || hasControlCharacters(name)) {
      await recordPairingAuditEvent(
        env,
        pairingIntent.ownerUserId,
        "pairing.rejected",
        "failure",
        {
          pairingId: pairingIntent.pairingId,
          reason: "invalid_workspace_name",
        },
      );
      return json(
        { error: "Workspace name is invalid or exceeds 120 characters" },
        { status: 400 },
      );
    }

    const capabilities = body.runtimeCapabilities ?? {
      os: platform,
      arch: architecture,
      appVersion,
      supportedRuntimes: ["dart"],
      maxConcurrentWorkers: 1,
    };
    if (
      capabilities === null ||
      typeof capabilities !== "object" ||
      Array.isArray(capabilities)
    ) {
      await recordPairingAuditEvent(
        env,
        pairingIntent.ownerUserId,
        "pairing.rejected",
        "failure",
        {
          pairingId: pairingIntent.pairingId,
          reason: "invalid_runtime_capabilities",
        },
      );
      return json(
        { error: "Runtime capabilities must be an object" },
        { status: 400 },
      );
    }
    const capabilityObject = capabilities as Record<string, unknown>;
    const capabilityKeys = Object.keys(capabilityObject);
    const supportedRuntimes = capabilityObject.supportedRuntimes;
    if (
      capabilityKeys.some(
        (key) =>
          ![
            "os",
            "arch",
            "appVersion",
            "supportedRuntimes",
            "maxConcurrentWorkers",
          ].includes(key),
      ) ||
      JSON.stringify(capabilityObject).length > 4096 ||
      capabilityObject.os !== platform ||
      capabilityObject.arch !== architecture ||
      capabilityObject.appVersion !== appVersion ||
      !Array.isArray(supportedRuntimes) ||
      supportedRuntimes.length > 16 ||
      supportedRuntimes.some(
        (runtime) =>
          typeof runtime !== "string" ||
          runtime.length === 0 ||
          runtime.length > 32 ||
          !/^[a-z0-9_-]+$/i.test(runtime),
      ) ||
      !Number.isInteger(capabilityObject.maxConcurrentWorkers) ||
      (capabilityObject.maxConcurrentWorkers as number) < 1 ||
      (capabilityObject.maxConcurrentWorkers as number) > 256
    ) {
      await recordPairingAuditEvent(
        env,
        pairingIntent.ownerUserId,
        "pairing.rejected",
        "failure",
        {
          pairingId: pairingIntent.pairingId,
          reason: "invalid_runtime_capabilities",
        },
      );
      return json(
        {
          error: "Runtime capabilities are invalid or exceed supported bounds",
        },
        { status: 400 },
      );
    }

    const workspaceId = `ws-${crypto.randomUUID()}`;
    const runtimeId = `runtime-${crypto.randomUUID()}`;
    const authToken = `conclave_workspace_tok_${crypto.randomUUID().replace(/-/g, "")}`;
    const authTokenHash = await hashToken(authToken);
    const results = await env.CONCLAVE_DB.batch([
      env.CONCLAVE_DB.prepare(
        `INSERT INTO execution_workspaces
           (id, owner_user_id, name, status, created_at, updated_at)
         SELECT ?1, ?2, ?3, 'offline', ?4, ?4
          WHERE EXISTS (
            SELECT 1 FROM workspace_pairing_intents
             WHERE pairing_id = ?5 AND token_hash = ?6
               AND owner_user_id = ?2 AND used_at IS NULL
               AND cancelled_at IS NULL AND expires_at > ?4
               AND EXISTS (SELECT 1 FROM users WHERE id = ?2 AND status = 'active')
          )
         UNION ALL
         SELECT NULL, NULL, NULL, NULL, NULL, NULL
          WHERE NOT EXISTS (
            SELECT 1 FROM workspace_pairing_intents
             WHERE pairing_id = ?5 AND token_hash = ?6
               AND owner_user_id = ?2 AND used_at IS NULL
               AND cancelled_at IS NULL AND expires_at > ?4
               AND EXISTS (SELECT 1 FROM users WHERE id = ?2 AND status = 'active')
          )`,
      ).bind(
        workspaceId,
        pairingIntent.ownerUserId,
        name,
        now,
        pairingIntent.pairingId,
        tokenHash,
      ),
      env.CONCLAVE_DB.prepare(
        `UPDATE workspace_pairing_intents SET used_at = ?1,
              claimed_workspace_id = ?2
          WHERE pairing_id = ?3 AND token_hash = ?4 AND owner_user_id = ?5
            AND used_at IS NULL AND cancelled_at IS NULL AND expires_at > ?1
            AND EXISTS (SELECT 1 FROM execution_workspaces WHERE id = ?2)`,
      ).bind(
        now,
        workspaceId,
        pairingIntent.pairingId,
        tokenHash,
        pairingIntent.ownerUserId,
      ),
      env.CONCLAVE_DB.prepare(
        `INSERT INTO workspace_runtime_identities
           (id, workspace_id, credential_key_ref, credential_token_hash,
            installation_id, created_at, revoked_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL)`,
      ).bind(
        runtimeId,
        workspaceId,
        `workspace-runtime:${runtimeId}`,
        authTokenHash,
        installationId,
        now,
      ),
      env.CONCLAVE_DB.prepare(
        `INSERT INTO workspace_runtime_facts
           (workspace_id, platform, architecture, hostname, app_version,
            runtime_capabilities_json, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
      ).bind(
        workspaceId,
        platform,
        architecture,
        hostname,
        appVersion,
        JSON.stringify(capabilityObject),
        now,
      ),
      env.CONCLAVE_DB.prepare(
        `INSERT INTO workspace_audit_log
           (id, workspace_id, actor_type, actor_id, action, target_type,
            target_id, details_json, created_at)
         SELECT ?1, ?2, 'workspace', ?3, 'workspace.runtime.paired',
                'workspace_runtime', ?3, ?4, ?5
          WHERE EXISTS (
            SELECT 1 FROM workspace_runtime_identities WHERE id = ?3
          )`,
      ).bind(
        `audit-${crypto.randomUUID()}`,
        workspaceId,
        runtimeId,
        JSON.stringify({
          pairingId: pairingIntent.pairingId,
          installationId,
          recoveredFromWorkspaceIds: historicalBindings.map(
            (binding) => binding.workspaceId,
          ),
          hostname,
          platform,
          architecture,
          appVersion,
        }),
        now,
      ),
      env.CONCLAVE_DB.prepare(
        `INSERT INTO workspace_audit_log
           (id, workspace_id, actor_type, actor_id, action, target_type,
            target_id, details_json, created_at)
         VALUES (?1, ?2, 'user', ?3, 'pairing.claimed',
                 'workspace_pairing_intent', ?4, ?5, ?6)`,
      ).bind(
        `audit-${crypto.randomUUID()}`,
        workspaceId,
        pairingIntent.ownerUserId,
        pairingIntent.pairingId,
        JSON.stringify({ installationId, runtimeId }),
        now,
      ),
      env.CONCLAVE_DB.prepare(
        `INSERT INTO workspace_audit_log
           (id, workspace_id, actor_type, actor_id, action, target_type,
            target_id, details_json, created_at)
         VALUES (?1, ?2, 'user', ?3, 'workspace.created', 'workspace', ?2, ?4, ?5)`,
      ).bind(
        `audit-${crypto.randomUUID()}`,
        workspaceId,
        pairingIntent.ownerUserId,
        JSON.stringify({ pairingId: pairingIntent.pairingId, name }),
        now,
      ),
      env.CONCLAVE_DB.prepare(
        `INSERT INTO workspace_audit_log
           (id, workspace_id, actor_type, actor_id, action, target_type,
            target_id, details_json, created_at)
         VALUES (?1, ?2, 'workspace', ?3, 'runtime.enrolled', 'workspace_runtime', ?3, ?4, ?5)`,
      ).bind(
        `audit-${crypto.randomUUID()}`,
        workspaceId,
        runtimeId,
        JSON.stringify({ installationId }),
        now,
      ),
    ]);
    if (
      (results[0]?.meta?.changes ?? 0) !== 1 ||
      (results[1]?.meta?.changes ?? 0) !== 1
    ) {
      await recordPairingAuditEvent(
        env,
        pairingIntent.ownerUserId,
        "pairing.rejected",
        "failure",
        {
          pairingId: pairingIntent.pairingId,
          reason: "claim_race_or_invalidated",
        },
      );
      return json(
        { error: "Pairing code was already used or is no longer valid" },
        { status: 409 },
      );
    }
    return json(
      {
        workspaceRuntimeId: runtimeId,
        workspaceId,
        workspaceName: name,
        authToken,
      },
      { status: 201 },
    );
  }

  const enrollment = await env.CONCLAVE_DB.prepare(
    `SELECT e.id, e.workspace_id AS workspaceId, ew.name AS workspaceName,
            ew.owner_user_id AS ownerUserId
       FROM workspace_enrollments e
       JOIN execution_workspaces ew ON ew.id = e.workspace_id
      WHERE e.token_hash = ?1
        AND e.revoked_at IS NULL
        AND e.used_at IS NULL
        AND e.expires_at > ?2
        AND ew.status <> 'revoked'`,
  )
    .bind(tokenHash, now)
    .first<{
      id: string;
      workspaceId: string;
      workspaceName: string;
      ownerUserId: string;
    }>();

  if (!enrollment) {
    await recordPairingAuditEvent(env, null, "pairing.rejected", "failure", {
      reason: "invalid_token",
    });
    return json(
      {
        error: "Invalid, expired, revoked, or already used enrollment token",
        code: "invalid_pairing_code",
      },
      { status: 401 },
    );
  }

  const legacyInstallationId = body.installationId?.trim();
  if (
    !legacyInstallationId ||
    !/^install_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      legacyInstallationId,
    )
  ) {
    return json(
      { error: "A valid stable installationId is required to claim pairing" },
      { status: 400 },
    );
  }
  const legacyBindings = await env.CONCLAVE_DB.prepare(
    `SELECT identity.workspace_id AS workspaceId,
            identity.revoked_at AS revokedAt,
            workspace.status AS workspaceStatus
       FROM workspace_runtime_identities identity
       JOIN execution_workspaces workspace
         ON workspace.id = identity.workspace_id
      WHERE identity.installation_id = ?1
      ORDER BY identity.created_at DESC`,
  )
    .bind(legacyInstallationId)
    .all<{
      workspaceId: string;
      revokedAt: string | null;
      workspaceStatus: string;
    }>();
  const priorBindings = legacyBindings.results ?? [];
  const activePriorBinding = priorBindings.find(
    (binding) =>
      binding.revokedAt === null && binding.workspaceStatus !== "revoked",
  );
  if (activePriorBinding) {
    return json(
      {
        error:
          activePriorBinding.workspaceId === enrollment.workspaceId
            ? "This installation is already paired to a Workspace owned by this account. Reconnect with its saved runtime credential."
            : "This Conclave Workspace installation is already paired. Disconnect it before pairing with another account.",
        code: "installation_already_paired",
        workspaceId: activePriorBinding.workspaceId,
      },
      { status: 409 },
    );
  }
  if (priorBindings.length > 0 && body.allowRecovery !== true) {
    return json(
      {
        error:
          "This installation was previously paired. Explicitly unpair it in Conclave Workspace before recovering its pairing",
        code: "installation_recovery_required",
      },
      { status: 409 },
    );
  }

  // Claim the one-time code before minting a long-lived runtime credential.
  // The conditional update makes two concurrent redemption attempts race
  // safely: only one may change used_at from NULL.
  const claimed = await env.CONCLAVE_DB.prepare(
    `UPDATE workspace_enrollments
        SET used_at = ?1
      WHERE id = ?2
        AND used_at IS NULL
        AND revoked_at IS NULL
        AND expires_at > ?1`,
  )
    .bind(now, enrollment.id)
    .run();
  if ((claimed.meta?.changes ?? 0) !== 1) {
    return json(
      { error: "Enrollment token was already used or is no longer valid" },
      { status: 409 },
    );
  }

  const runtimeId = `runtime-${crypto.randomUUID()}`;
  const authToken = `conclave_workspace_tok_${crypto.randomUUID().replace(/-/g, "")}`;
  const authTokenHash = await hashToken(authToken);

  // One normal Conclave Workspace runtime owns one execution Workspace.
  // Re-pairing revokes an older runtime credential while preserving the
  // machine's local Project/Workstream data, whose path does not depend on
  // Workspace/runtime identity.
  await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      `UPDATE workspace_runtime_identities
          SET revoked_at = ?1
        WHERE workspace_id = ?2
          AND revoked_at IS NULL`,
    ).bind(now, enrollment.workspaceId),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO workspace_runtime_identities
        (id, workspace_id, credential_key_ref, credential_token_hash,
         installation_id, created_at, revoked_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL)`,
    ).bind(
      runtimeId,
      enrollment.workspaceId,
      `workspace-runtime:${runtimeId}`,
      authTokenHash,
      body.installationId?.trim() || null,
      now,
    ),
    env.CONCLAVE_DB.prepare(
      `UPDATE execution_workspaces
          SET status = 'offline',
              name = COALESCE(?3, name),
              updated_at = ?1
        WHERE id = ?2 AND status <> 'revoked'`,
    ).bind(now, enrollment.workspaceId, body.name?.trim() || null),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO workspace_audit_log
        (id, workspace_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
       VALUES (?1, ?2, 'workspace', ?3, 'workspace.runtime.enrolled', 'workspace_runtime', ?3, ?4, ?5)`,
    ).bind(
      `audit-${crypto.randomUUID()}`,
      enrollment.workspaceId,
      runtimeId,
      JSON.stringify({
        name: body.name ?? null,
        hostname: body.hostname ?? null,
        platform: body.platform ?? null,
        architecture: body.architecture ?? null,
        appVersion: body.appVersion ?? null,
      }),
      now,
    ),
  ]);

  const effectiveWorkspaceName = body.name?.trim() || enrollment.workspaceName;

  return json(
    {
      workspaceRuntimeId: runtimeId,
      workspaceId: enrollment.workspaceId,
      workspaceName: effectiveWorkspaceName,
      authToken,
    },
    { status: 201 },
  );
}

export async function handleUnpairWorkspaceRuntime(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const token = extractBearerToken(request.headers);
  if (!token)
    return json(
      { error: "Workspace runtime credential is required" },
      { status: 401 },
    );

  const tokenHash = await hashToken(token);
  const runtime = await env.CONCLAVE_DB.prepare(
    `SELECT id, workspace_id AS workspaceId, revoked_at AS revokedAt
       FROM workspace_runtime_identities
      WHERE credential_token_hash = ?1`,
  )
    .bind(tokenHash)
    .first<{ id: string; workspaceId: string; revokedAt: string | null }>();
  if (!runtime) {
    return json(
      { error: "Invalid or already revoked Workspace credential" },
      { status: 401 },
    );
  }
  if (runtime.revokedAt) {
    const gatewayDisconnected = await disconnectWorkspaceRuntime(
      env,
      runtime.workspaceId,
      runtime.id,
    );
    return json({
      unpaired: true,
      alreadyUnpaired: true,
      workspaceId: runtime.workspaceId,
      gatewayDisconnected,
    });
  }

  const now = new Date().toISOString();
  await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      `UPDATE workspace_runtime_identities SET revoked_at = ?1
        WHERE id = ?2 AND credential_token_hash = ?3 AND revoked_at IS NULL`,
    ).bind(now, runtime.id, tokenHash),
    env.CONCLAVE_DB.prepare(
      `UPDATE execution_workspaces SET status = 'offline', updated_at = ?1
        WHERE id = ?2 AND status <> 'revoked'
          AND NOT EXISTS (
            SELECT 1 FROM workspace_runtime_identities
             WHERE workspace_id = ?2 AND revoked_at IS NULL
          )`,
    ).bind(now, runtime.workspaceId),
    env.CONCLAVE_DB.prepare(
      `UPDATE worker_assignments SET status = 'cancelled', error_json = ?1, updated_at = ?2
        WHERE execution_workspace_id = ?3 AND status IN ('created', 'dispatched')`,
    ).bind(
      JSON.stringify({
        code: "workspace_unpaired",
        message: "Workspace runtime unpaired",
      }),
      now,
      runtime.workspaceId,
    ),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO workspace_audit_log
        (id, workspace_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
       VALUES (?1, ?2, 'workspace', ?3, 'workspace.unpaired', 'workspace_runtime', ?3, ?4, ?5)`,
    ).bind(
      `audit-${crypto.randomUUID()}`,
      runtime.workspaceId,
      runtime.id,
      JSON.stringify({ unpairedAt: now }),
      now,
    ),
  ]);
  const gatewayDisconnected = await disconnectWorkspaceRuntime(
    env,
    runtime.workspaceId,
    runtime.id,
  );
  return json({
    unpaired: true,
    workspaceId: runtime.workspaceId,
    completedAt: now,
    gatewayDisconnected,
  });
}
