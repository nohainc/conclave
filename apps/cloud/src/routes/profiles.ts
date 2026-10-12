import {
  spaceModelOptions,
  spaceWorkerExecutionOptions,
} from "../worker-execution-options.js";
export {
  spaceModelOptions,
  spaceWorkerExecutionOptions,
} from "../worker-execution-options.js";
import { extractBearerToken } from "@conclave/security";
import { listWorkerProfiles } from "../worker-profile-registry.js";
import { HttpError, json, securityContext } from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";
import { WorkspaceRuntimeAuthenticator } from "../workspace-gateway/runtime-authenticator.js";

export async function handleListWorkspaceWorkerInventory(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const workspaceId = new URL(request.url).searchParams.get("workspaceId");
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT i.worker_id, i.workspace_id, ew.name AS workspace_name,
            i.worker_type_id, i.activation_state, i.readiness_state,
            i.readiness_issue_code, i.local_concurrency_limit,
            i.engine_version, i.profile_definition_id,
            i.profile_release_version, i.provider_tool_name,
            i.provider_tool_version, i.last_seen_at,
            catalog.display_name AS catalog_display_name,
            catalog.description AS catalog_description,
            catalog.lifecycle_state AS catalog_lifecycle_state,
            catalog.visibility_state AS catalog_visibility_state,
            COALESCE(current_profile.profile_json, history.profile_json) AS model_profile_json,
            COALESCE(current_profile.digest, history.digest) AS model_profile_digest,
            i.model_catalog_json
       FROM workspace_worker_inventory i
       JOIN execution_workspaces ew ON ew.id = i.workspace_id
       LEFT JOIN worker_catalog catalog ON catalog.worker_type_id = i.worker_type_id
       LEFT JOIN worker_profiles current_profile
         ON current_profile.worker_type_id = i.worker_type_id
        AND current_profile.revision = i.profile_release_version
       LEFT JOIN worker_profile_history history
         ON history.worker_type_id = i.worker_type_id
        AND history.revision = i.profile_release_version
      WHERE i.owner_user_id = ?1
        AND (?2 IS NULL OR i.workspace_id = ?2)
      ORDER BY i.workspace_id, i.worker_type_id, i.worker_id`,
  )
    .bind(context.userId, workspaceId)
    .all<Record<string, unknown>>();
  return json({
    workers: (rows.results ?? []).map((row) => ({
      executionOptions: spaceWorkerExecutionOptions(
        row.model_profile_json,
        row.provider_tool_version,
        row.model_catalog_json,
        row.model_profile_digest,
      ),
      modelOptions: spaceModelOptions(
        row.model_profile_json,
        row.provider_tool_version,
        row.model_catalog_json,
        row.model_profile_digest,
      ),
      id: String(row.worker_id),
      workspaceId: String(row.workspace_id),
      workspaceName: String(row.workspace_name),
      workerTypeId: String(row.worker_type_id),
      displayName:
        row.catalog_display_name == null
          ? String(row.worker_type_id)
          : String(row.catalog_display_name),
      description:
        row.catalog_description == null
          ? null
          : String(row.catalog_description),
      catalogLifecycleState:
        row.catalog_lifecycle_state == null
          ? "retired"
          : String(row.catalog_lifecycle_state),
      catalogVisibilityState:
        row.catalog_visibility_state == null
          ? "hidden"
          : String(row.catalog_visibility_state),
      activationState: String(row.activation_state),
      readinessState: String(row.readiness_state),
      readinessIssueCode:
        row.readiness_issue_code == null
          ? null
          : String(row.readiness_issue_code),
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

async function requireWorkspaceRuntime(
  request: Request,
  env: SecurityEnv,
): Promise<void> {
  const url = new URL(request.url);
  const runtimeId = url.searchParams.get("workspaceRuntimeId");
  const credential = extractBearerToken(request.headers);
  if (!runtimeId || !credential)
    throw new HttpError(401, "Workspace runtime credentials are required");
  const runtime = await new WorkspaceRuntimeAuthenticator(
    env.CONCLAVE_DB,
  ).authenticateRuntime(runtimeId, credential);
  if (!runtime)
    throw new HttpError(401, "Workspace runtime credential is invalid");
}

export async function handleListWorkspaceWorkerCatalog(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  await requireWorkspaceRuntime(request, env);
  return json(await listWorkerProfiles(env.CONCLAVE_DB));
}

export async function handleListWorkerCatalog(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  await securityContext(request, env, ctx);
  return json(await listWorkerProfiles(env.CONCLAVE_DB));
}
