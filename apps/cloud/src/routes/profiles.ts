import { extractBearerToken, hashToken } from "@conclave/security";
import {
  changeToolProfileLifecycle,
  createDraftToolProfileRelease,
  createToolProfileDefinition,
  createApprovedLogicalWorker,
  listToolProfileReleaseAudit,
  listToolProfileReleases,
  promoteToolProfileRelease,
  publishDraftToolProfileRelease,
  resolveToolProfileChannels,
  setWorkspaceToolProfileChannel,
  updateDraftToolProfilePayload,
  type ToolProfileChannel,
} from "../tool-profile-registry.js";
import {
  HttpError,
  authorizeToolProfileAdmin,
  json,
  readToolProfileAdminBody,
  recordAudit,
  requireWorkspaceContext,
  securityContext,
  toolProfileReleaseVersion,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";
import { WORKER_INPUT_CAPABILITIES } from "@conclave/core";

export async function handleListWorkspaceWorkerInventory(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const workspaceId = new URL(request.url).searchParams.get("workspaceId");
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT i.worker_id, i.workspace_id,
            i.worker_type_id, i.activation_state, i.readiness_state,
            i.readiness_issue_code, i.capabilities_json,
            i.local_concurrency_limit, i.engine_version,
            i.profile_definition_id, i.profile_release_version,
            i.provider_tool_name, i.provider_tool_version, i.last_seen_at
       FROM workspace_worker_inventory i
      WHERE i.owner_user_id = ?1
        AND (?2 IS NULL OR i.workspace_id = ?2)
      ORDER BY i.workspace_id, i.worker_type_id, i.worker_id`,
  )
    .bind(context.userId, workspaceId)
    .all<Record<string, unknown>>();
  const parseArray = (value: unknown): unknown[] => {
    try {
      const decoded: unknown = JSON.parse(String(value ?? "[]"));
      return Array.isArray(decoded) ? decoded : [];
    } catch {
      return [];
    }
  };
  return json({
    workers: (rows.results ?? []).map((row) => ({
      id: String(row.worker_id),
      workspaceId: String(row.workspace_id),
      workerTypeId: String(row.worker_type_id),
      activationState: String(row.activation_state),
      readinessState: String(row.readiness_state),
      readinessIssueCode:
        row.readiness_issue_code == null
          ? null
          : String(row.readiness_issue_code),
      capabilities: parseArray(row.capabilities_json),
      inputCapabilities: parseArray(row.capabilities_json).filter(
        (capability): capability is string =>
          typeof capability === "string" &&
          (WORKER_INPUT_CAPABILITIES as readonly string[]).includes(capability),
      ),
      localConcurrencyLimit: Number(row.local_concurrency_limit),
      engineVersion:
        row.engine_version == null ? null : String(row.engine_version),
      profileDefinitionId:
        row.profile_definition_id == null
          ? null
          : String(row.profile_definition_id),
      profileReleaseVersion:
        row.profile_release_version == null
          ? null
          : Number(row.profile_release_version),
      providerToolName:
        row.provider_tool_name == null ? null : String(row.provider_tool_name),
      providerToolVersion:
        row.provider_tool_version == null
          ? null
          : String(row.provider_tool_version),
      lastSeenAt: String(row.last_seen_at),
    })),
  });
}

export async function handleResolveToolProfileChannels(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const url = new URL(request.url);
  const workerTypeId = url.searchParams.get("workerTypeId") ?? undefined;
  if (url.searchParams.has("channel")) {
    throw new HttpError(400, "Profile channel is selected by Conclave Cloud");
  }
  const runtimeId = url.searchParams.get("workspaceRuntimeId");
  const credential = extractBearerToken(request.headers);
  if (!runtimeId || !credential) {
    throw new HttpError(401, "Workspace runtime credentials are required");
  }
  const runtime = await env.CONCLAVE_DB.prepare(
    `SELECT wri.workspace_id AS workspaceId
       FROM workspace_runtime_identities wri
       JOIN execution_workspaces ew ON ew.id = wri.workspace_id
      WHERE wri.id = ?1 AND wri.credential_token_hash = ?2
        AND wri.revoked_at IS NULL AND ew.status <> 'revoked'`,
  )
    .bind(runtimeId, await hashToken(credential))
    .first<{ workspaceId: string }>();
  if (!runtime)
    throw new HttpError(401, "Workspace runtime credential is invalid");
  const channelRow = await env.CONCLAVE_DB.prepare(
    `SELECT channel FROM workspace_tool_profile_channels WHERE workspace_id = ?1`,
  )
    .bind(runtime.workspaceId)
    .first<{ channel: ToolProfileChannel }>();
  const channel = channelRow?.channel ?? "stable";
  const result = await resolveToolProfileChannels(
    env.CONCLAVE_DB,
    workerTypeId,
    channel,
  );
  return json({ ...result, channel });
}

export async function handleSetWorkspaceToolProfileChannel(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const actor = await authorizeToolProfileAdmin(request, env, ctx);
  await requireWorkspaceContext(actor, env, workspaceId);
  const body = await readToolProfileAdminBody(request, ["channel"]);
  if (
    typeof body.channel !== "string" ||
    !["testing", "beta", "stable"].includes(body.channel)
  ) {
    throw new HttpError(400, "channel must be testing, beta, or stable");
  }
  const updated = await setWorkspaceToolProfileChannel(env.CONCLAVE_DB, {
    workspaceId,
    channel: body.channel as ToolProfileChannel,
    actorUserId: actor.userId,
  });
  await recordAudit(
    env,
    actor,
    "workspace.tool_profile_channel.updated",
    "workspace",
    workspaceId,
    {
      channel: updated.channel,
    },
  );
  return json(updated);
}

export async function handleCreateToolProfileDefinition(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const actor = await authorizeToolProfileAdmin(request, env, ctx);
  const body = await readToolProfileAdminBody(request, [
    "profileDefinitionId",
    "workerTypeId",
    "displayName",
    "providerToolName",
  ]);
  if (
    typeof body.profileDefinitionId !== "string" ||
    typeof body.workerTypeId !== "string" ||
    typeof body.displayName !== "string" ||
    typeof body.providerToolName !== "string"
  ) {
    throw new HttpError(400, "Tool Profile definition fields are required");
  }
  await createToolProfileDefinition(env.CONCLAVE_DB, {
    profileDefinitionId: body.profileDefinitionId,
    workerTypeId: body.workerTypeId,
    displayName: body.displayName,
    providerToolName: body.providerToolName,
    actorUserId: actor.userId,
  });
  return json(
    { profileDefinitionId: body.profileDefinitionId, status: "created" },
    { status: 201 },
  );
}

export async function handleCreateApprovedLogicalWorker(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const actor = await authorizeToolProfileAdmin(request, env, ctx);
  const body = await readToolProfileAdminBody(request, [
    "workerTypeId",
    "profileDefinitionId",
    "displayName",
    "description",
    "providerToolName",
    "releaseStage",
    "capabilities",
    "sortOrder",
  ]);
  if (
    typeof body.workerTypeId !== "string" ||
    typeof body.profileDefinitionId !== "string" ||
    typeof body.displayName !== "string" ||
    typeof body.description !== "string" ||
    typeof body.providerToolName !== "string" ||
    typeof body.releaseStage !== "string" ||
    !Array.isArray(body.capabilities) ||
    !body.capabilities.every((item) => typeof item === "string") ||
    typeof body.sortOrder !== "number"
  ) {
    throw new HttpError(400, "Logical Worker catalog fields are required");
  }
  await createApprovedLogicalWorker(env.CONCLAVE_DB, {
    workerTypeId: body.workerTypeId,
    profileDefinitionId: body.profileDefinitionId,
    displayName: body.displayName,
    description: body.description,
    providerToolName: body.providerToolName,
    releaseStage: body.releaseStage as ToolProfileChannel,
    capabilities: body.capabilities as string[],
    sortOrder: body.sortOrder,
    actorUserId: actor.userId,
  });
  await recordAudit(
    env,
    actor,
    "worker_catalog.entry.approved",
    "logical_worker",
    body.workerTypeId,
    { profileDefinitionId: body.profileDefinitionId },
  );
  return json(
    {
      workerTypeId: body.workerTypeId,
      profileDefinitionId: body.profileDefinitionId,
      status: "created",
    },
    { status: 201 },
  );
}

export async function handleCreateDraftToolProfileRelease(
  request: Request,
  env: SecurityEnv,
  profileDefinitionId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const actor = await authorizeToolProfileAdmin(request, env, ctx);
  const body = await readToolProfileAdminBody(request, [
    "releaseVersion",
    "profile",
  ]);
  if (
    !Number.isSafeInteger(body.releaseVersion) ||
    body.profile === undefined
  ) {
    throw new HttpError(400, "releaseVersion and profile are required");
  }
  const result = await createDraftToolProfileRelease(
    env.CONCLAVE_DB,
    { profileDefinitionId, releaseVersion: body.releaseVersion as number },
    body.profile,
    actor.userId,
  );
  return json(result, { status: 201 });
}

export async function handleUpdateDraftToolProfileRelease(
  request: Request,
  env: SecurityEnv,
  profileDefinitionId: string,
  versionText: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const actor = await authorizeToolProfileAdmin(request, env, ctx);
  const body = await readToolProfileAdminBody(request, ["profile"]);
  if (body.profile === undefined)
    throw new HttpError(400, "profile is required");
  return json(
    await updateDraftToolProfilePayload(
      env.CONCLAVE_DB,
      {
        profileDefinitionId,
        releaseVersion: toolProfileReleaseVersion(versionText),
      },
      body.profile,
      actor.userId,
    ),
  );
}

export async function handlePublishDraftToolProfileRelease(
  request: Request,
  env: SecurityEnv,
  profileDefinitionId: string,
  versionText: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const actor = await authorizeToolProfileAdmin(request, env, ctx);
  const body = await readToolProfileAdminBody(request, [
    "signature",
    "signingKeyId",
  ]);
  if (
    typeof body.signature !== "string" ||
    typeof body.signingKeyId !== "string"
  ) {
    throw new HttpError(400, "signature and signingKeyId are required");
  }
  return json(
    await publishDraftToolProfileRelease(
      env,
      {
        profileDefinitionId,
        releaseVersion: toolProfileReleaseVersion(versionText),
      },
      body.signature,
      body.signingKeyId,
      actor.userId,
    ),
  );
}

export async function handlePromoteToolProfileRelease(
  request: Request,
  env: SecurityEnv,
  profileDefinitionId: string,
  versionText: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const actor = await authorizeToolProfileAdmin(request, env, ctx);
  const body = await readToolProfileAdminBody(request, [
    "channel",
    "acceptanceEvidence",
  ]);
  if (
    typeof body.channel !== "string" ||
    !["testing", "beta", "stable"].includes(body.channel)
  ) {
    throw new HttpError(400, "channel is invalid");
  }
  if (body.channel === "stable" && body.acceptanceEvidence === undefined) {
    throw new HttpError(
      400,
      "Real Profile acceptance evidence is required for stable promotion",
    );
  }
  if (body.channel !== "stable" && body.acceptanceEvidence !== undefined) {
    throw new HttpError(
      400,
      "Acceptance evidence is only accepted for stable promotion",
    );
  }
  return json(
    await promoteToolProfileRelease(
      env.CONCLAVE_DB,
      {
        profileDefinitionId,
        releaseVersion: toolProfileReleaseVersion(versionText),
      },
      body.channel as ToolProfileChannel,
      actor.userId,
      body.acceptanceEvidence,
    ),
  );
}

export async function handleChangeToolProfileReleaseLifecycle(
  request: Request,
  env: SecurityEnv,
  profileDefinitionId: string,
  versionText: string,
  lifecycle: "retired" | "revoked",
  ctx?: ExecutionContext,
): Promise<Response> {
  const actor = await authorizeToolProfileAdmin(request, env, ctx);
  const body = await readToolProfileAdminBody(request, ["reason"]);
  if (typeof body.reason !== "string")
    throw new HttpError(400, "reason is required");
  return json(
    await changeToolProfileLifecycle(
      env.CONCLAVE_DB,
      {
        profileDefinitionId,
        releaseVersion: toolProfileReleaseVersion(versionText),
      },
      lifecycle,
      actor.userId,
      body.reason,
    ),
  );
}

export async function handleListToolProfileReleases(
  request: Request,
  env: SecurityEnv,
  profileDefinitionId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  await authorizeToolProfileAdmin(request, env, ctx);
  return json(
    await listToolProfileReleases(env.CONCLAVE_DB, profileDefinitionId),
  );
}

export async function handleListToolProfileReleaseAudit(
  request: Request,
  env: SecurityEnv,
  profileDefinitionId: string,
  versionText: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  await authorizeToolProfileAdmin(request, env, ctx);
  return json(
    await listToolProfileReleaseAudit(env.CONCLAVE_DB, {
      profileDefinitionId,
      releaseVersion: toolProfileReleaseVersion(versionText),
    }),
  );
}
