import { DESKTOP_WORKSPACE_AUDIENCE, hashToken } from "@conclave/security";

import {
  disconnectWorkspaceRuntime,
  findDesktopHumanSession,
  getWorkspaceGatewayStatus,
  json,
  parseJson,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";
import { hasControlCharacters } from "./workspaces-shared.js";

type WorkspaceOwnershipRow = {
  runtimeId: string;
  workspaceId: string;
  installationId: string | null;
  ownerUserId: string;
  workspaceStatus: string;
  revokedAt: string | null;
};

function currentOwnerOwnership(
  state:
    | "owned_by_current_user"
    | "local_registration_stale"
    | "installation_conflict"
    | "released",
  row: WorkspaceOwnershipRow,
  ownerUserId: string,
) {
  return {
    state,
    workspaceId: row.workspaceId,
    workspaceRuntimeId: row.runtimeId,
    ownerUserId,
    ownerMatchesCurrentSession: true,
    runtimeState: row.workspaceStatus,
  };
}

/** Returns a privacy-preserving ownership read model for the local installation. */
export async function handleCheckWorkspaceOwnership(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const { session } = await findDesktopHumanSession(
    request,
    env,
    undefined,
    DESKTOP_WORKSPACE_AUDIENCE,
  );
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
            i.installation_id AS installationId, w.owner_user_id AS ownerUserId,
            w.status AS workspaceStatus, i.revoked_at AS revokedAt
       FROM workspace_runtime_identities i
       JOIN execution_workspaces w ON w.id = i.workspace_id
      WHERE i.installation_id = ?1 ORDER BY i.created_at DESC, i.id`,
  )
    .bind(installationId)
    .all<WorkspaceOwnershipRow>();
  const boundRows = byInstallation.results ?? [];

  // A foreign owner is represented by one constant response, even when other
  // inconsistent rows would otherwise reveal their IDs or runtime state.
  if (boundRows.some((row) => row.ownerUserId !== session.userId)) {
    return json({ state: "owned_by_other_user" });
  }
  if (new Set(boundRows.map((row) => row.workspaceId)).size > 1) {
    return json({ state: "corrupt_or_ambiguous" });
  }
  const activeBindings = boundRows.filter(
    (row) => row.revokedAt === null && row.workspaceStatus !== "revoked",
  );
  if (activeBindings.length > 1) {
    return json({ state: "corrupt_or_ambiguous" });
  }

  let localRow: WorkspaceOwnershipRow | null = null;
  if (workspaceId && runtimeId) {
    localRow = await env.CONCLAVE_DB.prepare(
      `SELECT i.id AS runtimeId, i.workspace_id AS workspaceId,
              i.installation_id AS installationId, w.owner_user_id AS ownerUserId,
              w.status AS workspaceStatus, i.revoked_at AS revokedAt
         FROM workspace_runtime_identities i
         JOIN execution_workspaces w ON w.id = i.workspace_id
        WHERE i.id = ?1 AND i.workspace_id = ?2`,
    )
      .bind(runtimeId, workspaceId)
      .first<WorkspaceOwnershipRow>();
    if (localRow && localRow.ownerUserId !== session.userId) {
      return json({ state: "owned_by_other_user" });
    }
  }

  const bound = activeBindings[0];
  if (bound) {
    const hasLocalRegistration = Boolean(workspaceId || runtimeId);
    if (
      hasLocalRegistration &&
      (!workspaceId ||
        !runtimeId ||
        workspaceId !== bound.workspaceId ||
        runtimeId !== bound.runtimeId)
    ) {
      const conflictingLocalBinding =
        localRow !== null &&
        localRow.installationId !== null &&
        localRow.installationId !== installationId;
      return json(
        currentOwnerOwnership(
          conflictingLocalBinding
            ? "installation_conflict"
            : "local_registration_stale",
          bound,
          session.userId,
        ),
      );
    }
    return json(
      currentOwnerOwnership("owned_by_current_user", bound, session.userId),
    );
  }

  if (boundRows.length > 0) {
    return json({ state: "corrupt_or_ambiguous" });
  }

  if (localRow) {
    if (
      localRow.installationId === null &&
      localRow.revokedAt !== null &&
      localRow.workspaceStatus === "revoked"
    ) {
      return json(currentOwnerOwnership("released", localRow, session.userId));
    }
    if (localRow.installationId !== null) {
      return json(
        currentOwnerOwnership(
          "installation_conflict",
          localRow,
          session.userId,
        ),
      );
    }
    return json({ state: "corrupt_or_ambiguous" });
  }

  if (workspaceId || runtimeId) {
    return json({ state: "local_registration_stale" });
  }
  const releaseHistory = await env.CONCLAVE_DB.prepare(
    `SELECT 1 AS released
       FROM workspace_audit_log
      WHERE action = 'workspace.ownership.released'
        AND CASE
              WHEN json_valid(details_json) = 1
              THEN json_extract(details_json, '$.installationId')
              ELSE NULL
            END = ?1
      LIMIT 1`,
  )
    .bind(installationId)
    .first<{ released: number }>();
  if (releaseHistory) return json({ state: "released" });
  return json({ state: "unbound" });
}

/** Disconnects runtime participation while retaining the installation owner binding. */
export async function handleDisconnectDesktopWorkspace(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const { session, now } = await findDesktopHumanSession(
    request,
    env,
    undefined,
    DESKTOP_WORKSPACE_AUDIENCE,
  );
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
  const { session, now } = await findDesktopHumanSession(
    request,
    env,
    undefined,
    DESKTOP_WORKSPACE_AUDIENCE,
  );
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
  const { session, now } = await findDesktopHumanSession(
    request,
    env,
    undefined,
    DESKTOP_WORKSPACE_AUDIENCE,
  );
  const body = parseJson<Record<string, unknown>>(await request.text(), {});
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return json(
      { error: "Workspace registration details are invalid" },
      { status: 400 },
    );
  }
  const installationId =
    typeof body.installationId === "string" ? body.installationId.trim() : "";
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
    Object.keys(body).some(
      (key) =>
        ![
          "contractVersion",
          "installationId",
          "proposedWorkspaceName",
          "hostname",
          "platform",
          "architecture",
          "appVersion",
          "runtimeCapabilities",
        ].includes(key),
    ) ||
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
      ORDER BY i.created_at DESC`,
  )
    .bind(installationId)
    .all<{
      runtimeId: string;
      workspaceId: string;
      revokedAt: string | null;
      ownerUserId: string;
      workspaceName: string;
      workspaceStatus: string;
      installationId: string;
    }>();
  const history = bindings.results ?? [];
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
      `INSERT INTO workspace_runtime_identities (id, workspace_id, credential_token_hash, installation_id, created_at, revoked_at) VALUES (?1, ?2, ?3, ?4, ?5, NULL)`,
    ).bind(runtimeId, workspaceId, credentialHash, installationId, now),
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
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error("Workspace registration batch failed:", message);
    return json(
      {
        error: `Workspace registration changed concurrently; retry the request (${message})`,
        code: "registration_conflict",
        details: message,
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
