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
  createEncryptedWorkspaceBackup,
  createWorkspaceProjectGrant,
  decodeBase64,
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
  testAuthenticationEnabled,
  workspaceProjectGrantMetadata,
  workspaceBackupKey,
  workspaceOwnerContext,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";

export async function handleListWorkspaces(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT id, name,
            CASE
              WHEN status = 'enrolled' AND EXISTS (
                SELECT 1 FROM workspace_runtime_identities identity
                WHERE identity.workspace_id = execution_workspaces.id
                  AND identity.revoked_at IS NULL
              ) THEN 'offline'
              WHEN status IN ('enrolled', 'offline') AND NOT EXISTS (
                SELECT 1 FROM workspace_runtime_identities identity
                WHERE identity.workspace_id = execution_workspaces.id
                  AND identity.revoked_at IS NULL
              ) AND EXISTS (
                SELECT 1 FROM workspace_enrollments e
                WHERE e.workspace_id = execution_workspaces.id
                  AND e.used_at IS NULL AND e.revoked_at IS NULL
                  AND e.expires_at > ?2
              ) THEN 'pairing'
              WHEN status = 'enrolled' AND NOT EXISTS (
                SELECT 1 FROM workspace_runtime_identities identity
                WHERE identity.workspace_id = execution_workspaces.id
                  AND identity.revoked_at IS NULL
              ) THEN 'not_connected'
              ELSE status
            END AS lifecycleStatus,
            status,
            EXISTS (SELECT 1 FROM workspace_runtime_identities identity
                    WHERE identity.workspace_id = execution_workspaces.id
                      AND identity.revoked_at IS NULL) AS hasRuntimeIdentity,
            (SELECT COUNT(*) FROM workspace_worker_inventory worker
              WHERE worker.workspace_id = execution_workspaces.id) AS workerCount,
            (SELECT COUNT(*) FROM worker_assignments assignment
              WHERE assignment.execution_workspace_id = execution_workspaces.id
                AND assignment.status IN ('created', 'dispatched', 'acknowledged', 'running')) AS activeTaskCount,
            CASE
              WHEN NOT EXISTS (SELECT 1 FROM workspace_runtime_identities identity
                               WHERE identity.workspace_id = execution_workspaces.id
                                 AND identity.revoked_at IS NULL) THEN NULL
              WHEN f.updated_at IS NULL OR execution_workspaces.updated_at > f.updated_at
                THEN execution_workspaces.updated_at
              ELSE f.updated_at
            END AS lastSeen,
            f.platform, f.architecture, f.hostname,
            f.app_version AS appVersion,
            f.runtime_capabilities_json AS runtimeCapabilitiesJson,
            f.updated_at AS factsUpdatedAt,
            execution_workspaces.created_at AS createdAt,
            execution_workspaces.updated_at AS updatedAt
       FROM execution_workspaces
       LEFT JOIN workspace_runtime_facts f ON f.workspace_id = execution_workspaces.id
      WHERE owner_user_id = ?1 AND status <> 'revoked'
      ORDER BY name ASC`,
  )
    .bind(context.userId, new Date().toISOString())
    .all();
  const workspaces = await Promise.all(
    (rows.results ?? []).map(async (raw) => {
      const row = raw as Record<string, unknown>;
      const workspaceId = typeof row.id === "string" ? row.id : null;
      let activeTransport: "websocket" | "http_long_poll" | null = null;
      if (
        workspaceId &&
        row.hasRuntimeIdentity &&
        env.CONCLAVE_WORKSPACE_GATEWAY
      ) {
        try {
          const response = await env.CONCLAVE_WORKSPACE_GATEWAY.getByName(
            workspaceId,
          ).fetch("https://workspace-gateway/status");
          if (response.ok) {
            const status = (await response.json()) as {
              online?: boolean;
              activeTransport?: string | null;
            };
            if (
              status.online &&
              (status.activeTransport === "websocket" ||
                status.activeTransport === "http_long_poll")
            ) {
              activeTransport = status.activeTransport;
            }
          }
        } catch {
          // Connection mode is an operational hint; preserve the Workspace
          // row if its Gateway status cannot be read at this moment.
        }
      }
      return {
        ...row,
        activeTransport,
        connectionMode:
          activeTransport === "websocket"
            ? "Connected · WebSocket"
            : activeTransport === "http_long_poll"
              ? "Connected · HTTPS fallback"
              : null,
      };
    }),
  );
  return json({ workspaces });
}

export async function handleCreateWorkspace(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  throw new HttpError(
    410,
    "Workspace creation before pairing is no longer supported. Create a pairing intent and connect Conclave Workspace.",
  );


}

export async function handleCreateWorkspacePairingIntent(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const expiresMinutes = body.expiresMinutes ?? 15;
  if (
    typeof expiresMinutes !== "number" ||
    !Number.isInteger(expiresMinutes) ||
    expiresMinutes < 1 ||
    expiresMinutes > 60
  ) {
    throw new HttpError(400, "expiresMinutes must be an integer from 1 to 60");
  }

  const pairingId = `pair-${crypto.randomUUID()}`;
  const token = `conclave_pair_${crypto.randomUUID().replace(/-/g, "")}`;
  const now = new Date();
  const createdAt = now.toISOString();
  const expiresAt = new Date(
    now.getTime() + expiresMinutes * 60_000,
  ).toISOString();
  await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      `INSERT INTO workspace_pairing_intents
         (pairing_id, owner_user_id, token_hash, created_at, expires_at)
       VALUES (?1, ?2, ?3, ?4, ?5)`,
    ).bind(
      pairingId,
      context.userId,
      await hashToken(token),
      createdAt,
      expiresAt,
    ),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO auth_audit_events
         (id, user_id, session_id, action, outcome, details_json, created_at)
       VALUES (?1, ?2, ?3, 'pairing.created', 'success', ?4, ?5)`,
    ).bind(
      `audit-${crypto.randomUUID()}`,
      context.userId,
      context.sessionId ?? null,
      JSON.stringify({ pairingId, expiresAt }),
      createdAt,
    ),
  ]);

  return json(
    {
      id: pairingId,
      token,
      status: "pending",
      createdAt,
      expiresAt,
    },
    { status: 201 },
  );
}

/** Verifies and migrates a desktop's existing binding without rotating runtime credentials. */
export async function handleCheckWorkspaceOwnership(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const { session } = await findDesktopHumanSession(request, env);
  const body = parseJson<Record<string, unknown>>(await request.text(), {});
  const installationId =
    typeof body.installationId === "string" ? body.installationId.trim() : "";
  const workspaceId =
    typeof body.workspaceId === "string" ? body.workspaceId.trim() : "";
  const runtimeId =
    typeof body.runtimeId === "string" ? body.runtimeId.trim() : "";
  if (
    body.contractVersion !== "1.0" ||
    !/^install_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      installationId,
    )
  ) {
    return json(
      {
        error: "Workspace installation identity is invalid",
        code: "invalid_installation_id",
      },
      { status: 400 },
    );
  }

  const byInstallation = await env.CONCLAVE_DB.prepare(
    `SELECT i.id AS runtimeId, i.workspace_id AS workspaceId,
            i.installation_id AS installationId, w.owner_user_id AS ownerUserId
       FROM workspace_runtime_identities i
       JOIN execution_workspaces w ON w.id = i.workspace_id
      WHERE i.installation_id = ?1 ORDER BY i.created_at DESC`,
  )
    .bind(installationId)
    .all<{
      runtimeId: string;
      workspaceId: string;
      installationId: string | null;
      ownerUserId: string;
    }>();
  let matches = byInstallation.results ?? [];
  let legacyBinding = false;
  if (workspaceId || runtimeId) {
    if (!workspaceId || !runtimeId) {
      return json(
        {
          error:
            "This Workspace belongs to another Conclave account. Disconnect and release it from the current account before switching users.",
          code: "installation_already_owned",
        },
        { status: 409 },
      );
    }
    const legacy = await env.CONCLAVE_DB.prepare(
      `SELECT i.id AS runtimeId, i.workspace_id AS workspaceId,
              i.installation_id AS installationId, w.owner_user_id AS ownerUserId
         FROM workspace_runtime_identities i
         JOIN execution_workspaces w ON w.id = i.workspace_id
        WHERE i.id = ?1 AND i.workspace_id = ?2`,
    )
      .bind(runtimeId, workspaceId)
      .all<{
        runtimeId: string;
        workspaceId: string;
        installationId: string | null;
        ownerUserId: string;
      }>();
    const localBinding = legacy.results ?? [];
    if (localBinding.length === 0) {
      return json(
        {
          error:
            "This Workspace belongs to another Conclave account. Disconnect and release it from the current account before switching users.",
          code: "installation_already_owned",
        },
        { status: 409 },
      );
    }
    for (const binding of localBinding) {
      if (!matches.some((item) => item.runtimeId === binding.runtimeId)) {
        matches.push(binding);
      }
    }
    legacyBinding = localBinding.some((item) => item.installationId === null);
  }
  if (matches.some((item) => item.ownerUserId !== session.userId)) {
    return json(
      {
        error:
          "This Workspace belongs to another Conclave account. Disconnect and release it from the current account before switching users.",
        code: "installation_already_owned",
      },
      { status: 409 },
    );
  }
  if (new Set(matches.map((item) => item.workspaceId)).size > 1) {
    return json(
      {
        error:
          "This Workspace belongs to another Conclave account. Disconnect and release it from the current account before switching users.",
        code: "installation_already_owned",
      },
      { status: 409 },
    );
  }
  if (
    matches.some(
      (item) =>
        item.installationId !== null && item.installationId !== installationId,
    )
  ) {
    return json(
      {
        error:
          "This Workspace belongs to another Conclave account. Disconnect and release it from the current account before switching users.",
        code: "installation_already_owned",
      },
      { status: 409 },
    );
  }
  if (legacyBinding) {
    const legacy = matches.find((item) => item.runtimeId === runtimeId)!;
    if (
      legacy.installationId !== null &&
      legacy.installationId !== installationId
    ) {
      return json(
        {
          error:
            "This Workspace belongs to another Conclave account. Disconnect and release it from the current account before switching users.",
          code: "installation_already_owned",
        },
        { status: 409 },
      );
    }
    const conflict = await env.CONCLAVE_DB.prepare(
      `SELECT 1 AS found FROM workspace_runtime_identities
        WHERE installation_id = ?1 AND id <> ?2 LIMIT 1`,
    )
      .bind(installationId, runtimeId)
      .first<{ found: number }>();
    if (conflict) {
      return json(
        {
          error: "Workspace installation ownership changed concurrently",
          code: "installation_already_owned",
        },
        { status: 409 },
      );
    }
    const linked = await env.CONCLAVE_DB.prepare(
      `UPDATE workspace_runtime_identities SET installation_id = ?1
        WHERE id = ?2 AND workspace_id = ?3 AND installation_id IS NULL`,
    )
      .bind(installationId, runtimeId, workspaceId)
      .run();
    if ((linked.meta?.changes ?? 0) !== 1) {
      return json(
        {
          error: "Workspace installation ownership changed concurrently",
          code: "installation_already_owned",
        },
        { status: 409 },
      );
    }
  }
  return json({ registered: matches.length > 0, ownerUserId: session.userId });
}

/** Disconnects runtime participation while retaining the installation owner binding. */
export async function handleDisconnectDesktopWorkspace(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const { session, now } = await findDesktopHumanSession(request, env);
  const body = parseJson<Record<string, unknown>>(await request.text(), {});
  const installationId =
    typeof body.installationId === "string" ? body.installationId.trim() : "";
  const workspaceId =
    typeof body.workspaceId === "string" ? body.workspaceId.trim() : "";
  const runtimeId =
    typeof body.runtimeId === "string" ? body.runtimeId.trim() : "";
  if (!installationId || !workspaceId || !runtimeId) {
    return json(
      {
        error: "Workspace disconnect identity is incomplete",
        code: "invalid_disconnect_identity",
      },
      { status: 400 },
    );
  }
  const owned = await env.CONCLAVE_DB.prepare(
    `SELECT i.id AS runtimeId, i.workspace_id AS workspaceId, i.credential_token_hash AS credentialHash,
            i.installation_id AS installationId, i.revoked_at AS revokedAt,
            w.owner_user_id AS ownerUserId, w.status AS workspaceStatus
       FROM workspace_runtime_identities i JOIN execution_workspaces w ON w.id = i.workspace_id
      WHERE i.installation_id = ?1 AND i.workspace_id = ?2 AND i.id = ?3`,
  )
    .bind(installationId, workspaceId, runtimeId)
    .first<{
      runtimeId: string;
      workspaceId: string;
      credentialHash: string;
      installationId: string;
      revokedAt: string | null;
      ownerUserId: string;
      workspaceStatus: string;
    }>();
  if (!owned || owned.ownerUserId !== session.userId) {
    return json(
      {
        error:
          "This Workspace belongs to another Conclave account. Disconnect and release it from the current account before switching users.",
        code: "installation_already_owned",
      },
      { status: 409 },
    );
  }
  if (owned.revokedAt !== null)
    return json({ disconnected: true, workspaceId, installationId });

  const active = await env.CONCLAVE_DB.prepare(
    `SELECT COUNT(*) AS count FROM worker_assignments
      WHERE execution_workspace_id = ?1 AND status IN ('created', 'dispatched', 'acknowledged', 'running')`,
  )
    .bind(workspaceId)
    .first<{ count: number }>();
  if ((active?.count ?? 0) > 0) {
    return json(
      {
        error: "Finish active Workspace assignments before disconnecting",
        code: "active_work",
      },
      { status: 409 },
    );
  }

  const disconnectedAt = now;
  const result = await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      `UPDATE workspace_runtime_identities SET revoked_at = ?1
        WHERE id = ?2 AND workspace_id = ?3 AND installation_id = ?4 AND revoked_at IS NULL`,
    ).bind(disconnectedAt, runtimeId, workspaceId, installationId),
    env.CONCLAVE_DB.prepare(
      `UPDATE execution_workspaces SET status = 'offline', updated_at = ?1
        WHERE id = ?2 AND owner_user_id = ?3 AND status <> 'revoked'`,
    ).bind(disconnectedAt, workspaceId, session.userId),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO workspace_audit_log
        (id, workspace_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
       VALUES (?1, ?2, 'user', ?3, 'workspace.disconnected', 'workspace_runtime', ?4, ?5, ?6)`,
    ).bind(
      `audit-${crypto.randomUUID()}`,
      workspaceId,
      session.userId,
      runtimeId,
      JSON.stringify({ installationId, disconnectedAt }),
      disconnectedAt,
    ),
  ]);
  if ((result[0]?.meta?.changes ?? 0) !== 1) {
    return json(
      {
        error: "Workspace runtime state changed concurrently",
        code: "runtime_state_conflict",
      },
      { status: 409 },
    );
  }
  const gatewayDisconnected = await disconnectWorkspaceRuntime(
    env,
    workspaceId,
    runtimeId,
  );
  return json({
    disconnected: true,
    workspaceId,
    installationId,
    disconnectedAt,
    gatewayDisconnected,
  });
}

/** Releases Cloud ownership only after a fresh same-owner human session. */
export async function handleReleaseDesktopWorkspace(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const { session, now } = await findDesktopHumanSession(request, env);
  const sessionCreatedAt = Date.parse(session.createdAt);
  if (
    !Number.isFinite(sessionCreatedAt) ||
    sessionCreatedAt < Date.now() - 5 * 60_000
  ) {
    return json(
      {
        error: "Fresh sign-in is required to release this Workspace",
        code: "fresh_auth_required",
      },
      { status: 403 },
    );
  }
  const body = parseJson<Record<string, unknown>>(await request.text(), {});
  const installationId =
    typeof body.installationId === "string" ? body.installationId.trim() : "";
  const workspaceId =
    typeof body.workspaceId === "string" ? body.workspaceId.trim() : "";
  const runtimeId =
    typeof body.runtimeId === "string" ? body.runtimeId.trim() : "";
  if (!installationId || !workspaceId || !runtimeId) {
    return json(
      {
        error: "Workspace release identity is incomplete",
        code: "invalid_release_identity",
      },
      { status: 400 },
    );
  }
  const owned = await env.CONCLAVE_DB.prepare(
    `SELECT i.id AS runtimeId, i.workspace_id AS workspaceId,
            w.owner_user_id AS ownerUserId, w.status AS workspaceStatus
       FROM workspace_runtime_identities i
       JOIN execution_workspaces w ON w.id = i.workspace_id
      WHERE i.installation_id = ?1 AND i.workspace_id = ?2 AND i.id = ?3`,
  )
    .bind(installationId, workspaceId, runtimeId)
    .first<{
      runtimeId: string;
      workspaceId: string;
      ownerUserId: string;
      workspaceStatus: string;
    }>();
  if (!owned || owned.ownerUserId !== session.userId) {
    return json(
      {
        error:
          "This Workspace belongs to another Conclave account. Disconnect and release it from the current account before switching users.",
        code: "installation_already_owned",
      },
      { status: 409 },
    );
  }

  const gatewayStatus = await getWorkspaceGatewayStatus(env, workspaceId);
  if (
    gatewayStatus === null ||
    gatewayStatus.online ||
    owned.workspaceStatus === "online"
  ) {
    return json(
      {
        error: "Disconnect the Workspace runtime before releasing ownership",
        code: "runtime_connected",
      },
      { status: 409 },
    );
  }

  const active = await env.CONCLAVE_DB.prepare(
    `SELECT COUNT(*) AS count FROM worker_assignments
      WHERE execution_workspace_id = ?1
        AND status IN ('created', 'dispatched', 'acknowledged', 'running')`,
  )
    .bind(workspaceId)
    .first<{ count: number }>();
  if ((active?.count ?? 0) > 0) {
    return json(
      {
        error: "Finish active Workspace assignments before releasing ownership",
        code: "active_work",
      },
      { status: 409 },
    );
  }

  const reserved = await env.CONCLAVE_DB.prepare(
    `UPDATE execution_workspaces SET status = 'revoked', updated_at = ?1
      WHERE id = ?2 AND owner_user_id = ?3 AND status = ?4`,
  )
    .bind(now, workspaceId, session.userId, owned.workspaceStatus)
    .run();
  if ((reserved.meta?.changes ?? 0) !== 1) {
    return json(
      {
        error: "Workspace ownership changed concurrently",
        code: "installation_already_owned",
      },
      { status: 409 },
    );
  }

  await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      `UPDATE workspace_runtime_identities
          SET revoked_at = COALESCE(revoked_at, ?1), installation_id = NULL
        WHERE workspace_id = ?2`,
    ).bind(now, workspaceId),
    env.CONCLAVE_DB.prepare(
      `UPDATE workspace_project_grants SET status = 'revoked', updated_at = ?1
        WHERE workspace_id = ?2 AND status IN ('active', 'suspended')`,
    ).bind(now, workspaceId),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO workspace_audit_log
        (id, workspace_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
       VALUES (?1, ?2, 'user', ?3, 'workspace.ownership.released', 'workspace_runtime', ?4, ?5, ?6)`,
    ).bind(
      `audit-${crypto.randomUUID()}`,
      workspaceId,
      session.userId,
      runtimeId,
      JSON.stringify({ installationId, releasedAt: now }),
      now,
    ),
  ]);
  return json({ released: true, workspaceId, installationId, releasedAt: now });
}

export async function handleRegisterWorkspaceFromDesktop(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const { session, now } = await findDesktopHumanSession(request, env);
  const body = parseJson<Record<string, unknown>>(await request.text(), {});
  const installationId =
    typeof body.installationId === "string" ? body.installationId.trim() : "";
  const existingWorkspaceId =
    typeof body.existingWorkspaceId === "string"
      ? body.existingWorkspaceId.trim()
      : "";
  const existingRuntimeId =
    typeof body.existingRuntimeId === "string"
      ? body.existingRuntimeId.trim()
      : "";
  const name =
    typeof body.proposedWorkspaceName === "string"
      ? body.proposedWorkspaceName.trim()
      : "";
  const hostname =
    typeof body.hostname === "string" ? body.hostname.trim() : "";
  const platform = body.platform;
  const architecture = body.architecture;
  const appVersion =
    typeof body.appVersion === "string" ? body.appVersion.trim() : "";
  const capabilities = body.runtimeCapabilities;
  if (
    body.contractVersion !== "1.0" ||
    !/^install_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      installationId,
    ) ||
    !name ||
    name.length > 120 ||
    /[\u0000-\u001f\u007f]/.test(name) ||
    !hostname ||
    hostname.length > 253 ||
    /[\u0000-\u001f\u007f]/.test(hostname) ||
    !["macos", "linux", "windows"].includes(String(platform)) ||
    !["arm64", "x64", "x86"].includes(String(architecture)) ||
    !appVersion ||
    appVersion.length > 64 ||
    !/^[0-9A-Za-z.+-]+$/.test(appVersion) ||
    !capabilities ||
    typeof capabilities !== "object" ||
    Array.isArray(capabilities)
  ) {
    return json(
      { error: "Workspace registration details are invalid" },
      { status: 400 },
    );
  }
  const caps = capabilities as Record<string, unknown>;
  const supported = caps.supportedRuntimes;
  if (
    Object.keys(caps).some(
      (key) =>
        ![
          "os",
          "arch",
          "appVersion",
          "supportedRuntimes",
          "maxConcurrentWorkers",
        ].includes(key),
    ) ||
    caps.os !== platform ||
    caps.arch !== architecture ||
    caps.appVersion !== appVersion ||
    !Array.isArray(supported) ||
    supported.length > 16 ||
    supported.some(
      (x) => typeof x !== "string" || !/^[a-z0-9_-]{1,32}$/i.test(x),
    ) ||
    !Number.isInteger(caps.maxConcurrentWorkers) ||
    (caps.maxConcurrentWorkers as number) < 1 ||
    (caps.maxConcurrentWorkers as number) > 256
  ) {
    return json({ error: "Runtime capabilities are invalid" }, { status: 400 });
  }
  const bindings = await env.CONCLAVE_DB.prepare(
    `SELECT i.id AS runtimeId, i.workspace_id AS workspaceId, i.installation_id AS installationId,
            i.revoked_at AS revokedAt,
            w.owner_user_id AS ownerUserId, w.name AS workspaceName, w.status AS workspaceStatus
       FROM workspace_runtime_identities i JOIN execution_workspaces w ON w.id = i.workspace_id
      WHERE i.installation_id = ?1
         OR (i.id = ?2 AND i.workspace_id = ?3)
      ORDER BY i.created_at DESC`,
  )
    .bind(
      installationId,
      existingRuntimeId || null,
      existingWorkspaceId || null,
    )
    .all<{
      runtimeId: string;
      workspaceId: string;
      revokedAt: string | null;
      ownerUserId: string;
      workspaceName: string;
      workspaceStatus: string;
      installationId: string | null;
    }>();
  const history = bindings.results ?? [];
  if ((existingWorkspaceId || existingRuntimeId) && history.length === 0) {
    return json(
      {
        error:
          "This Workspace belongs to another Conclave account. Disconnect and release it from the current account before switching users.",
        code: "installation_already_owned",
      },
      { status: 409 },
    );
  }
  const active = history.find(
    (item) => item.revokedAt === null && item.workspaceStatus !== "revoked",
  );
  if (history.some((item) => item.ownerUserId !== session.userId)) {
    return json(
      {
        error:
          "This Workspace belongs to another Conclave account. Disconnect and release it from the current account before switching users.",
        code: "installation_already_owned",
      },
      { status: 409 },
    );
  }
  if (
    history.some(
      (item) =>
        item.installationId !== null && item.installationId !== installationId,
    )
  ) {
    return json(
      {
        error:
          "This Workspace belongs to another Conclave account. Disconnect and release it from the current account before switching users.",
        code: "installation_already_owned",
      },
      { status: 409 },
    );
  }
  const existing = active ?? history[0];
  const outcome = existing ? "recovered" : "created";
  const workspaceId = existing?.workspaceId ?? `ws-${crypto.randomUUID()}`;
  const workspaceName =
    name && name.trim().length > 0
      ? name.trim()
      : (existing?.workspaceName ?? name);
  const runtimeId = `runtime-${crypto.randomUUID()}`;
  const credential = `conclave_workspace_tok_${crypto.randomUUID().replace(/-/g, "")}`;
  const credentialHash = await hashToken(credential);
  const auditId = `audit-${crypto.randomUUID()}`;
  const statements = [];
  if (existing && existing.installationId === null)
    statements.push(
      env.CONCLAVE_DB.prepare(
        `UPDATE workspace_runtime_identities SET installation_id = ?1
      WHERE id = ?2 AND workspace_id = ?3 AND installation_id IS NULL`,
      ).bind(installationId, existing.runtimeId, existing.workspaceId),
    );
  if (
    existing &&
    name &&
    name.trim().length > 0 &&
    name.trim() !== existing.workspaceName
  ) {
    statements.push(
      env.CONCLAVE_DB.prepare(
        `UPDATE execution_workspaces SET name = ?1, updated_at = ?2 WHERE id = ?3`,
      ).bind(workspaceName, now, workspaceId),
    );
  }
  if (!existing)
    statements.push(
      env.CONCLAVE_DB.prepare(
        `INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES (?1, ?2, ?3, 'offline', ?4, ?4)`,
      ).bind(workspaceId, session.userId, workspaceName, now),
    );
  if (active)
    statements.push(
      env.CONCLAVE_DB.prepare(
        `UPDATE workspace_runtime_identities SET revoked_at = ?1 WHERE installation_id = ?2 AND revoked_at IS NULL`,
      ).bind(now, installationId),
    );
  statements.push(
    env.CONCLAVE_DB.prepare(
      `INSERT INTO workspace_runtime_identities (id, workspace_id, credential_key_ref, credential_token_hash, installation_id, created_at, revoked_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL)`,
    ).bind(
      runtimeId,
      workspaceId,
      `workspace-runtime:${runtimeId}`,
      credentialHash,
      installationId,
      now,
    ),
  );
  statements.push(
    env.CONCLAVE_DB.prepare(
      `INSERT INTO workspace_runtime_facts (workspace_id, platform, architecture, hostname, app_version, runtime_capabilities_json, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) ON CONFLICT(workspace_id) DO UPDATE SET platform=excluded.platform, architecture=excluded.architecture, hostname=excluded.hostname, app_version=excluded.app_version, runtime_capabilities_json=excluded.runtime_capabilities_json, updated_at=excluded.updated_at`,
    ).bind(
      workspaceId,
      platform,
      architecture,
      hostname,
      appVersion,
      JSON.stringify(caps),
      now,
    ),
  );
  statements.push(
    env.CONCLAVE_DB.prepare(
      `INSERT INTO workspace_audit_log (id, workspace_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at) VALUES (?1, ?2, 'user', ?3, ?4, 'workspace_runtime', ?5, ?6, ?7)`,
    ).bind(
      auditId,
      workspaceId,
      session.userId,
      outcome === "created" ? "workspace.registered" : "workspace.recovered",
      runtimeId,
      JSON.stringify({
        installationId,
        hostname,
        platform,
        architecture,
        appVersion,
      }),
      now,
    ),
  );
  try {
    await env.CONCLAVE_DB.batch(statements);
  } catch {
    return json(
      {
        error: "Workspace registration changed concurrently; retry the request",
        code: "registration_conflict",
      },
      { status: 409 },
    );
  }
  const completedAt = new Date().toISOString();
  return json(
    {
      outcome,
      workspaceId,
      workspaceRuntimeId: runtimeId,
      workspaceName,
      ownerUserId: session.userId,
      runtimeCredential: credential,
      credentialIssuedAt: completedAt,
      credentialExpiresAt: null,
      completedAt,
    },
    { status: 201 },
  );
}

export async function handleGetWorkspacePairingIntent(
  request: Request,
  env: SecurityEnv,
  pairingId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT pairing_id AS id, created_at AS createdAt,
            expires_at AS expiresAt, used_at AS usedAt,
            cancelled_at AS cancelledAt,
            claimed_workspace_id AS workspaceId
       FROM workspace_pairing_intents
      WHERE pairing_id = ?1 AND owner_user_id = ?2`,
  )
    .bind(pairingId, context.userId)
    .first<{
      id: string;
      createdAt: string;
      expiresAt: string;
      usedAt: string | null;
      cancelledAt: string | null;
      workspaceId: string | null;
    }>();
  if (!row) throw new HttpError(404, "Pairing intent not found");
  const status = row.usedAt
    ? "claimed"
    : row.cancelledAt
      ? "cancelled"
      : row.expiresAt <= new Date().toISOString()
        ? "expired"
        : "pending";
  return json({
    pairingIntent: {
      id: row.id,
      status,
      createdAt: row.createdAt,
      expiresAt: row.expiresAt,
      claimedAt: row.usedAt,
      workspaceId: row.workspaceId,
    },
  });
}

export async function handleRegenerateWorkspacePairingIntent(
  request: Request,
  env: SecurityEnv,
  pairingId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const existing = await env.CONCLAVE_DB.prepare(
    `SELECT pairing_id, used_at FROM workspace_pairing_intents
      WHERE pairing_id = ?1 AND owner_user_id = ?2`,
  )
    .bind(pairingId, context.userId)
    .first<{ pairing_id: string; used_at: string | null }>();
  if (!existing) throw new HttpError(404, "Pairing intent not found");
  if (existing.used_at) {
    throw new HttpError(409, "A claimed pairing intent cannot be regenerated");
  }

  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const expiresMinutes = body.expiresMinutes ?? 15;
  if (
    typeof expiresMinutes !== "number" ||
    !Number.isInteger(expiresMinutes) ||
    expiresMinutes < 1 ||
    expiresMinutes > 60
  ) {
    throw new HttpError(400, "expiresMinutes must be an integer from 1 to 60");
  }

  const replacementId = `pair-${crypto.randomUUID()}`;
  const token = `conclave_pair_${crypto.randomUUID().replace(/-/g, "")}`;
  const now = new Date();
  const createdAt = now.toISOString();
  const expiresAt = new Date(
    now.getTime() + expiresMinutes * 60_000,
  ).toISOString();
  await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      `UPDATE workspace_pairing_intents SET cancelled_at = ?1
        WHERE pairing_id = ?2 AND owner_user_id = ?3 AND used_at IS NULL`,
    ).bind(createdAt, pairingId, context.userId),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO workspace_pairing_intents
         (pairing_id, owner_user_id, token_hash, created_at, expires_at)
       VALUES (?1, ?2, ?3, ?4, ?5)`,
    ).bind(
      replacementId,
      context.userId,
      await hashToken(token),
      createdAt,
      expiresAt,
    ),
  ]);

  return json(
    {
      id: replacementId,
      token,
      status: "pending",
      createdAt,
      expiresAt,
    },
    { status: 201 },
  );
}

export async function handleCancelWorkspacePairingIntent(
  request: Request,
  env: SecurityEnv,
  pairingId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const existing = await env.CONCLAVE_DB.prepare(
    `SELECT used_at, cancelled_at, expires_at
       FROM workspace_pairing_intents
      WHERE pairing_id = ?1 AND owner_user_id = ?2`,
  )
    .bind(pairingId, context.userId)
    .first<{
      used_at: string | null;
      cancelled_at: string | null;
      expires_at: string;
    }>();
  if (!existing) throw new HttpError(404, "Pairing intent not found");
  if (existing.used_at) {
    throw new HttpError(409, "A claimed pairing intent cannot be cancelled");
  }
  if (
    existing.cancelled_at ||
    existing.expires_at <= new Date().toISOString()
  ) {
    return json({
      ok: true,
      status: existing.cancelled_at ? "cancelled" : "expired",
    });
  }
  const cancelledAt = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `UPDATE workspace_pairing_intents SET cancelled_at = ?1
      WHERE pairing_id = ?2 AND owner_user_id = ?3 AND used_at IS NULL
        AND cancelled_at IS NULL`,
  )
    .bind(cancelledAt, pairingId, context.userId)
    .run();
  return json({ ok: true, status: "cancelled", cancelledAt });
}

export async function handleGetWorkspace(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  await requireWorkspaceContext(context, env, workspaceId);
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT id, name, status, created_at AS createdAt, updated_at AS updatedAt FROM execution_workspaces WHERE id = ?1 AND owner_user_id = ?2",
  )
    .bind(workspaceId, context.userId)
    .first<{
      id: string;
      name: string;
      status: string;
      createdAt: string;
      updatedAt: string;
    }>();
  if (!row) throw new HttpError(404, "Workspace not found");
  return json({ workspace: row });
}

export async function handleUpdateWorkspace(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await workspaceOwnerContext(
    request,
    env,
    workspaceId,
    "workspace:manage",
    accessContext,
  );
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const name = typeof body.name === "string" ? body.name.trim() : "";
  if (name.length < 1 || name.length > 120) {
    throw new HttpError(400, "Workspace name must be 1 to 120 characters");
  }
  const now = new Date().toISOString();
  const result = await env.CONCLAVE_DB.prepare(
    "UPDATE execution_workspaces SET name = ?1, updated_at = ?2 WHERE id = ?3 AND owner_user_id = ?4 AND status <> 'revoked'",
  )
    .bind(name, now, workspaceId, context.userId)
    .run();
  if (!result.success || result.meta.changes === 0) {
    throw new HttpError(404, "Workspace not found");
  }
  await recordAudit(
    env,
    context,
    "workspace.updated",
    "workspace",
    workspaceId,
    {
      name,
    },
    workspaceId,
  );
  return json({ workspace: { id: workspaceId, name, updatedAt: now } });
}

export async function handleRevokeWorkspace(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const workspace = await env.CONCLAVE_DB.prepare(
    "SELECT id, status FROM execution_workspaces WHERE id = ?1 AND owner_user_id = ?2",
  )
    .bind(workspaceId, context.userId)
    .first<{ id: string; status: string }>();
  if (!workspace) throw new HttpError(404, "Workspace not found");

  const now = new Date().toISOString();
  const alreadyRevoked = workspace.status === "revoked";
  if (!alreadyRevoked) {
    const workspaceUpdate = await env.CONCLAVE_DB.prepare(
      "UPDATE execution_workspaces SET status = 'revoked', updated_at = ?1 WHERE id = ?2 AND owner_user_id = ?3",
    )
      .bind(now, workspaceId, context.userId)
      .run();
    if (!workspaceUpdate.success || workspaceUpdate.meta.changes === 0) {
      throw new HttpError(404, "Workspace not found");
    }
  }

  await env.CONCLAVE_DB.prepare(
    "UPDATE workspace_project_grants SET status = 'revoked', updated_at = ?1 WHERE workspace_id = ?2 AND status IN ('active', 'suspended')",
  )
    .bind(now, workspaceId)
    .run();

  // These tables were introduced by later configured-Worker migrations. A
  // partially migrated development/preview database must still be able to
  // revoke the canonical Workspace and its Project grants.
  for (const statement of [
    env.CONCLAVE_DB.prepare(
      "UPDATE workspace_runtime_identities SET revoked_at = ?1 WHERE workspace_id = ?2 AND revoked_at IS NULL",
    ).bind(now, workspaceId),
  ]) {
    await statement.run().catch(() => undefined);
  }

  if (!alreadyRevoked) {
    await recordAudit(
      env,
      context,
      "workspace.revoked",
      "workspace",
      workspaceId,
      { revokedAt: now },
      workspaceId,
    );
  }
  return json({ ok: true, revokedAt: now, alreadyRevoked });
}

export async function handleExportWorkspaceAudit(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await workspaceOwnerContext(
    request,
    env,
    workspaceId,
    "audit:read",
    accessContext,
  );
  const url = new URL(request.url);
  const requestedLimit = Number.parseInt(
    url.searchParams.get("limit") ?? "100",
    10,
  );
  const limit = Number.isFinite(requestedLimit)
    ? Math.min(Math.max(requestedLimit, 1), 500)
    : 100;
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT id, workspace_id AS workspaceId, actor_type AS actorType,
            actor_id AS actorId, action, target_type AS targetType,
            target_id AS targetId, details_json AS detailsJson,
            ip_address AS ipAddress, created_at AS createdAt
     FROM audit_log
     WHERE workspace_id = ?1
     ORDER BY created_at DESC, id DESC
     LIMIT ?2`,
  )
    .bind(workspaceId, limit)
    .all<{
      id: string;
      workspaceId: string;
      actorType: string;
      actorId: string;
      action: string;
      targetType: string;
      targetId: string;
      detailsJson: string;
      ipAddress: string | null;
      createdAt: string;
    }>();
  return json({
    format: "conclave-audit-log-v1",
    workspaceId,
    exportedAt: new Date().toISOString(),
    entries: (rows.results ?? []).map((row) => ({
      id: row.id,
      workspaceId: row.workspaceId,
      actorType: row.actorType,
      actorId: row.actorId,
      action: row.action,
      targetType: row.targetType,
      targetId: row.targetId,
      details: parseJson<Record<string, unknown>>(row.detailsJson, {}),
      ipAddress: row.ipAddress,
      createdAt: row.createdAt,
    })),
  });
}

export async function handleUploadArtifact(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const url = new URL(request.url);
  const projectId = url.searchParams.get("projectId");
  const runId = url.searchParams.get("runId");
  const taskId = url.searchParams.get("taskId");
  const attemptId = url.searchParams.get("attemptId");
  const assignmentId = url.searchParams.get("assignmentId");
  if (!projectId || !runId) {
    throw new HttpError(400, "projectId and runId are required");
  }
  const context = await workspaceOwnerContext(
    request,
    env,
    workspaceId,
    "projects:read",
    accessContext,
  );
  const scope = await env.CONCLAVE_DB.prepare(
    `SELECT p.workspace_id AS workspaceId
       FROM projects p JOIN runs r ON r.project_id = p.id
      WHERE p.id = ?1 AND r.id = ?2 AND p.workspace_id = ?3`,
  )
    .bind(projectId, runId, workspaceId)
    .first<{ workspaceId: string }>();
  if (!scope) throw new HttpError(404, "Artifact scope not found");
  const lengthHeader = request.headers.get("content-length");
  const declaredLength = lengthHeader ? Number(lengthHeader) : null;
  if (
    declaredLength !== null &&
    (!Number.isSafeInteger(declaredLength) ||
      declaredLength > MAX_ARTIFACT_UPLOAD_BYTES)
  ) {
    throw new HttpError(413, "Artifact exceeds the 64 MiB upload limit");
  }
  const artifactId =
    url.searchParams.get("artifactId") ??
    request.headers.get("x-artifact-id") ??
    `artifact-${crypto.randomUUID()}`;
  const existing = await env.CONCLAVE_DB.prepare(
    "SELECT * FROM artifacts WHERE id = ?1",
  )
    .bind(artifactId)
    .first<Record<string, unknown>>();
  if (existing) {
    if (String(existing.workspace_id) !== workspaceId) {
      throw new HttpError(409, "Artifact upload identity is already in use");
    }
    return json({ artifact: artifactMetadata(existing), deduplicated: true });
  }
  const body = await request.arrayBuffer();
  if (body.byteLength > MAX_ARTIFACT_UPLOAD_BYTES) {
    throw new HttpError(413, "Artifact exceeds the 64 MiB upload limit");
  }
  const mediaType =
    request.headers.get("content-type")?.split(";", 1)[0]?.trim() ||
    "application/octet-stream";
  const name = artifactName(
    url.searchParams.get("name") ?? request.headers.get("x-artifact-name"),
  );
  const computedDigest = await computePackageDigest(body);
  const suppliedDigest = request.headers.get("x-content-digest");
  if (suppliedDigest && suppliedDigest !== computedDigest) {
    throw new HttpError(422, "Artifact content digest does not match payload");
  }
  const digest = suppliedDigest ?? computedDigest;
  const storageKey = `artifact-objects/${workspaceId}/${crypto.randomUUID()}`;
  const bucket = env.CONCLAVE_ARTIFACTS;
  if (!bucket) throw new HttpError(503, "Artifact storage is not configured");
  await bucket.put(storageKey, body, {
    httpMetadata: { contentType: mediaType },
    customMetadata: { artifactId, workspaceId, digest },
  });
  const now = new Date().toISOString();
  try {
    await env.CONCLAVE_DB.prepare(
      `INSERT INTO artifacts
       (id, workspace_id, project_id, run_id, task_id, attempt_id, assignment_id,
        media_type, content_digest, storage_kind, storage_key, inline_content,
        size_bytes, provenance_json, created_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'r2', ?10, NULL, ?11, ?12, ?13)`,
    )
      .bind(
        artifactId,
        workspaceId,
        projectId,
        runId,
        taskId,
        attemptId,
        assignmentId,
        mediaType,
        digest,
        storageKey,
        body.byteLength,
        JSON.stringify({ name }),
        now,
      )
      .run();
  } catch (error) {
    await bucket.delete(storageKey).catch(() => undefined);
    throw error;
  }
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT * FROM artifacts WHERE id = ?1",
  )
    .bind(artifactId)
    .first<Record<string, unknown>>();
  if (!row) throw new HttpError(500, "Artifact record was not created");
  await createEventPublisher(env).publish({
    type: "artifact.created",
    workspaceId,
    projectId,
    runId,
    taskId: taskId ?? undefined,
    assignmentId: assignmentId ?? undefined,
    payload: {
      artifactId,
      entityId: artifactId,
      status: "available",
      summary: `${name} is ready to download`,
    },
  });
  await recordAudit(env, context, "artifact.created", "artifact", artifactId, {
    projectId,
    runId,
    sizeBytes: body.byteLength,
    mediaType,
  });
  return json({ artifact: artifactMetadata(row) }, { status: 201 });
}

export async function handleGetArtifact(
  request: Request,
  env: SecurityEnv,
  artifactId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT * FROM artifacts WHERE id = ?1",
  )
    .bind(artifactId)
    .first<Record<string, unknown>>();
  if (!row) throw new HttpError(404, "Artifact not found");
  const context = await authorizeRequest(
    request,
    env,
    "projects:read",
    String(row.project_id),
    accessContext,
  );
  if (false) {
    throw new HttpError(404, "Artifact not found");
  }
  if (request.method === "HEAD") {
    return new Response(null, {
      status: 200,
      headers: {
        "content-type": String(row.media_type),
        "content-length": String(row.size_bytes),
      },
    });
  }
  if (row.storage_kind === "inline") {
    return new Response(String(row.inline_content ?? ""), {
      headers: { "content-type": String(row.media_type) },
    });
  }
  const object = await env.CONCLAVE_ARTIFACTS.get(String(row.storage_key));
  if (!object) throw new HttpError(404, "Artifact content not found");
  const provenance = parseJson<Record<string, unknown>>(
    row.provenance_json,
    {},
  );
  return new Response(object.body, {
    headers: {
      "content-type": String(row.media_type),
      "content-length": String(row.size_bytes),
      "content-disposition": `inline; filename="${artifactName(typeof provenance.name === "string" ? provenance.name : null)}"`,
      "cache-control": "private, no-store",
    },
  });
}

export async function handleVerifyWorkspaceBackup(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await workspaceOwnerContext(
    request,
    env,
    workspaceId,
    "audit:read",
    accessContext,
  );
  const bucket = env.CONCLAVE_ARTIFACTS;
  const secret = env.CONCLAVE_SECURITY_KEY;
  if (!bucket || !secret) {
    throw new HttpError(503, "Encrypted backup storage is not configured");
  }
  const body = (await request.json()) as Record<string, unknown>;
  const storageKey = requiredString(body.storageKey, "storageKey");
  const expectedPrefix = `backups/${workspaceId}/`;
  if (!storageKey.startsWith(expectedPrefix)) {
    throw new HttpError(404, "Backup not found");
  }
  const object = await bucket.get(storageKey);
  if (!object) throw new HttpError(404, "Backup not found");
  let envelope: Record<string, unknown>;
  try {
    envelope = JSON.parse(await object.text()) as Record<string, unknown>;
  } catch {
    throw new HttpError(422, "Backup envelope is invalid");
  }
  if (
    envelope.format !== "conclave-encrypted-backup-v1" ||
    envelope.workspaceId !== workspaceId ||
    envelope.algorithm !== "AES-GCM" ||
    typeof envelope.digest !== "string" ||
    typeof envelope.iv !== "string" ||
    typeof envelope.ciphertext !== "string"
  ) {
    throw new HttpError(422, "Backup envelope does not match this workspace");
  }
  let payload: Record<string, unknown>;
  try {
    const plaintext = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: decodeBase64(envelope.iv) as BufferSource },
      await workspaceBackupKey(secret, workspaceId),
      decodeBase64(envelope.ciphertext) as BufferSource,
    );
    payload = JSON.parse(new TextDecoder().decode(plaintext)) as Record<
      string,
      unknown
    >;
  } catch {
    throw new HttpError(422, "Backup decryption failed");
  }
  if (
    payload.format !== "conclave-workspace-backup-p1" ||
    payload.workspaceId !== workspaceId ||
    typeof payload.tables !== "object" ||
    payload.tables === null
  ) {
    throw new HttpError(422, "Backup payload is invalid");
  }
  const payloadText = JSON.stringify(payload);
  const digest = await computePackageDigest(payloadText);
  if (digest !== envelope.digest) {
    throw new HttpError(422, "Backup digest mismatch");
  }
  const tables = payload.tables as Record<string, unknown>;
  const tableCounts = Object.fromEntries(
    Object.entries(tables).map(([name, rows]) => [
      name,
      Array.isArray(rows) ? rows.length : 0,
    ]),
  );
  await recordAudit(
    env,
    context,
    "workspace.backup.restore_verified",
    "workspace",
    workspaceId,
    { digest, storageKey, tableCounts },
  );
  return json({
    format: "conclave-backup-restore-drill-v1",
    workspaceId,
    storageKey,
    digest,
    tableCounts,
    validatedAt: new Date().toISOString(),
  });
}

export async function handleCreateWorkspaceBackup(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await workspaceOwnerContext(
    request,
    env,
    workspaceId,
    "audit:read",
    accessContext,
  );
  const backup = await createEncryptedWorkspaceBackup(env, workspaceId);
  await recordAudit(
    env,
    context,
    "workspace.backup.exported",
    "workspace",
    workspaceId,
    {
      digest: backup.digest,
      storageKey: backup.key,
      sizeBytes: backup.sizeBytes,
    },
  );
  return json(
    {
      format: "conclave-encrypted-backup-v1",
      workspaceId,
      storageKey: backup.key,
      digest: backup.digest,
      sizeBytes: backup.sizeBytes,
    },
    { status: 201 },
  );
}

// =========================================================================
// Agent Enrollment & Fleet Handlers
// =========================================================================

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
  await requireRecentStepUp(env, context, SENSITIVE_OPERATIONS.workspaceEnrollmentRevoke);

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
      /[\u0000-\u001f\u007f]/.test(hostname) ||
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
    if (!name || name.length > 120 || /[\u0000-\u001f\u007f]/.test(name)) {
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

export async function handleListWorkspaceProjectGrants(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  await authorizeWorkspaceOwner(
    env.CONCLAVE_DB,
    context,
    workspaceId,
    "workspace:manage",
  );
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT g.*, ew.name AS workspace_name, ew.owner_user_id
     FROM workspace_project_grants g JOIN execution_workspaces ew ON ew.id = g.workspace_id
     WHERE g.workspace_id = ?1 ORDER BY g.created_at DESC`,
  )
    .bind(workspaceId)
    .all<Record<string, unknown>>();
  return json({ grants: (rows.results ?? []).map(workspaceProjectGrantMetadata) });
}

export async function handleCreateWorkspaceProjectGrant(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  projectId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  return createWorkspaceProjectGrant(
    request,
    env,
    context,
    projectId,
    workspaceId,
  );
}

export async function handleListProjectWorkspaces(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  await authorizeProjectMembership(
    env.CONCLAVE_DB,
    context,
    projectId,
    "projects:read",
  );
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT g.*, ew.name AS workspace_name, ew.owner_user_id
     FROM workspace_project_grants g JOIN execution_workspaces ew ON ew.id = g.workspace_id
     WHERE g.project_id = ?1 AND g.status IN ('active', 'suspended')
       AND (g.expires_at IS NULL OR g.expires_at > ?2)
     ORDER BY ew.name`,
  )
    .bind(projectId, new Date().toISOString())
    .all<Record<string, unknown>>();
  return json({ workspaces: (rows.results ?? []).map(workspaceProjectGrantMetadata) });
}

export async function handleRequestProjectWorkspace(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  await authorizeProjectMembership(
    env.CONCLAVE_DB,
    context,
    projectId,
    "projects:write",
  );
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const workspaceId = requiredString(body.workspaceId, "workspaceId");
  const replayableRequest = new Request(request, {
    body: JSON.stringify(body),
  });
  return createWorkspaceProjectGrant(
    replayableRequest,
    env,
    context,
    projectId,
    workspaceId,
  );
}

export async function handleUpdateWorkspaceProjectGrant(
  request: Request,
  env: SecurityEnv,
  grantId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const existing = await loadWorkspaceProjectGrant(env, grantId);
  if (!existing) throw new HttpError(404, "Workspace Project Grant not found");
  await authorizeWorkspaceOwner(
    env.CONCLAVE_DB,
    context,
    String(existing.workspace_id),
    "workspace:manage",
  );
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const scope =
    body.scope === undefined ? String(existing.scope) : String(body.scope);
  if (
    !["project_repository", "selected_paths", "full_workspace"].includes(scope)
  )
    throw new HttpError(400, "Unsupported Workspace Project Grant scope");
  const requiresStepUp = await grantStepUpIfRequired(env, context, scope, body);
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `UPDATE workspace_project_grants SET scope = ?1, requires_step_up = ?2,
       status = COALESCE(?3, status), expires_at = COALESCE(?4, expires_at), updated_at = ?5
     WHERE id = ?6`,
  )
    .bind(
      scope,
      requiresStepUp,
      body.status === undefined ? null : String(body.status),
      typeof body.expiresAt === "string" ? body.expiresAt : null,
      now,
      grantId,
    )
    .run();
  await recordAudit(
    env,
    context,
    "workspace.project_grant.updated",
    "workspace_project_grant",
    grantId,
    { scope, status: body.status ?? existing.status },
  );
  const updated = await loadWorkspaceProjectGrant(env, grantId);
  return json({ grant: updated ? workspaceProjectGrantMetadata(updated) : null });
}

export async function handleRevokeWorkspaceProjectGrant(
  request: Request,
  env: SecurityEnv,
  grantId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const existing = await loadWorkspaceProjectGrant(env, grantId);
  if (!existing) throw new HttpError(404, "Workspace Project Grant not found");
  await authorizeWorkspaceOwner(
    env.CONCLAVE_DB,
    context,
    String(existing.workspace_id),
    "workspace:manage",
  );
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      "UPDATE workspace_project_grants SET status = 'revoked', updated_at = ?1 WHERE id = ?2",
    ).bind(now, grantId),
    env.CONCLAVE_DB.prepare(
      "UPDATE worker_assignments SET status = 'cancelled', error_json = ?1, updated_at = ?2 WHERE workspace_project_grant_id = ?3 AND status IN ('created', 'dispatched')",
    ).bind(
      JSON.stringify({
        code: "workspace_project_grant_revoked",
        cancelledAt: now,
      }),
      now,
      grantId,
    ),
  ]);
  await recordAudit(
    env,
    context,
    "workspace.project_grant.revoked",
    "workspace_project_grant",
    grantId,
    { projectId: existing.project_id, workspaceId: existing.workspace_id },
  );
  return json({ ok: true, revokedAt: now });
}
