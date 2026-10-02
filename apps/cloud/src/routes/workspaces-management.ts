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
  await securityContext(request, env, accessContext);
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
  const matches = byInstallation.results ?? [];
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
    hasControlCharacters(name) ||
    !hostname ||
    hostname.length > 253 ||
    hasControlCharacters(hostname) ||
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

  // These tables were introduced by unreleased compatibility migrations. A
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
  await workspaceOwnerContext(
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
            created_at AS createdAt
     FROM workspace_audit_log
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
      createdAt: row.createdAt,
    })),
  });
}
