import {
  HttpError,
  json,
  securityContext,
  type SecurityEnv,
} from "./http-security.js";

/**
 * Workers, models and efforts a Workspace shares with invited members. A
 * Worker that is listed is shared; a null `models`/`efforts` list shares all of
 * them. The Workspace owner is never restricted.
 */
export interface WorkspaceMemberAccessPolicy {
  readonly schemaVersion: 1;
  readonly workers: Readonly<
    Record<
      string,
      {
        readonly models: readonly string[] | null;
        readonly efforts: readonly string[] | null;
      }
    >
  >;
}

const MAX_WORKERS = 50;
const MAX_VALUES = 200;

function stringList(value: unknown, label: string): string[] | null {
  if (value === null || value === undefined) return null;
  if (
    !Array.isArray(value) ||
    value.length > MAX_VALUES ||
    value.some(
      (item) =>
        typeof item !== "string" || item.length === 0 || item.length > 200,
    )
  )
    throw new HttpError(400, `${label} must be a list of identifiers or null`);
  return [...new Set(value as string[])];
}

export function parseWorkspaceMemberAccessPolicy(
  value: unknown,
): WorkspaceMemberAccessPolicy {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new HttpError(400, "Invalid member access policy");
  const workers = (value as { workers?: unknown }).workers;
  if (!workers || typeof workers !== "object" || Array.isArray(workers))
    throw new HttpError(400, "workers must be an object");
  const entries = Object.entries(workers as Record<string, unknown>);
  if (entries.length > MAX_WORKERS)
    throw new HttpError(400, "Too many shared Workers");
  const parsed: Record<
    string,
    { models: string[] | null; efforts: string[] | null }
  > = {};
  for (const [workerId, entry] of entries) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry))
      throw new HttpError(400, "Invalid shared Worker entry");
    const object = entry as Record<string, unknown>;
    if (Object.keys(object).some((key) => !["models", "efforts"].includes(key)))
      throw new HttpError(400, "Unknown shared Worker field");
    parsed[workerId] = {
      models: stringList(object.models, "models"),
      efforts: stringList(object.efforts, "efforts"),
    };
  }
  return { schemaVersion: 1, workers: parsed };
}

export async function loadWorkspaceMemberAccess(
  env: Pick<SecurityEnv, "CONCLAVE_DB">,
  workspaceId: string,
): Promise<WorkspaceMemberAccessPolicy | null> {
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT policy_json AS policyJson FROM workspace_member_access WHERE workspace_id = ?1",
  )
    .bind(workspaceId)
    .first<{ policyJson: string }>();
  return row
    ? (JSON.parse(row.policyJson) as WorkspaceMemberAccessPolicy)
    : null;
}

/** Why a member may not run this selection, or null when it is shared. */
export function memberSelectionError(
  policy: WorkspaceMemberAccessPolicy | null,
  selection: { worker?: string; model?: string; effort?: string },
): string | null {
  if (!policy) return null;
  const shared = selection.worker
    ? policy.workers[selection.worker]
    : undefined;
  if (!shared) return "This Worker is not shared with Space members";
  if (
    shared.models &&
    (!selection.model || !shared.models.includes(selection.model))
  )
    return "Choose one of the models shared with Space members for this Worker";
  if (
    shared.efforts &&
    (!selection.effort || !shared.efforts.includes(selection.effort))
  )
    return "Choose one of the efforts shared with Space members for this Worker";
  return null;
}

type SharedWorker = WorkspaceMemberAccessPolicy["workers"][string];

/**
 * What a member may see of a Worker's execution options: only the shared
 * models, and within them only the shared efforts. Option shapes are the
 * public v1/v2 projections; anything unrecognised is returned untouched.
 */
export function restrictExecutionOptions<T>(
  options: T,
  shared: SharedWorker,
): T {
  if (!options || typeof options !== "object") return options;
  const source = options as Record<string, unknown>;
  const keepEffort = (values: unknown) =>
    Array.isArray(values)
      ? values.filter(
          (value) =>
            typeof value === "string" &&
            (!shared.efforts || shared.efforts.includes(value)),
        )
      : values;
  const restrictEffort = (effort: unknown) => {
    if (!effort || typeof effort !== "object") return effort;
    const current = effort as Record<string, unknown>;
    const values = keepEffort(current.values) as unknown[];
    return {
      ...current,
      values,
      supported: current.supported === true && values.length > 0,
      defaultValue: values.includes(current.defaultValue)
        ? current.defaultValue
        : null,
    };
  };
  const models = source.models as Record<string, unknown> | undefined;
  if (!models || !Array.isArray(models.options)) return options;
  const allowed = (model: Record<string, unknown>) =>
    !shared.models || shared.models.includes(String(model.id));
  const restrictedOptions = (models.options as Record<string, unknown>[])
    .filter(allowed)
    .map((model): Record<string, unknown> => {
      if (Array.isArray(model.efforts)) {
        const efforts = keepEffort(model.efforts) as unknown[];
        return {
          ...model,
          efforts,
          defaultEffort: efforts.includes(model.defaultEffort)
            ? model.defaultEffort
            : null,
        };
      }
      return { ...model, effort: restrictEffort(model.effort) };
    });
  const ids = restrictedOptions.map((model) => model.id);
  return {
    ...source,
    effort: restrictEffort(source.effort),
    models: {
      ...models,
      options: restrictedOptions,
      allowedModelIds: Array.isArray(models.allowedModelIds)
        ? models.allowedModelIds.filter((id) => ids.includes(id))
        : models.allowedModelIds,
      defaultModelId: ids.includes(models.defaultModelId)
        ? models.defaultModelId
        : null,
      // A member may not type a model the owner did not share.
      allowsCustomModel: shared.models ? false : models.allowsCustomModel,
    },
  } as T;
}

/** Owner-only read and replace of a Workspace's member access policy. */
export async function handleWorkspaceMemberAccess(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const workspace = await env.CONCLAVE_DB.prepare(
    "SELECT id FROM execution_workspaces WHERE id = ?1 AND owner_user_id = ?2 AND status != 'revoked'",
  )
    .bind(workspaceId, context.userId)
    .first();
  if (!workspace) throw new HttpError(404, "Workspace not found");
  if (request.method === "GET") {
    const policy = await loadWorkspaceMemberAccess(env, workspaceId);
    return json({ restricted: policy !== null, policy });
  }
  if (request.method !== "PUT") throw new HttpError(405, "Unsupported method");
  const body = (await request.json().catch(() => null)) as Record<
    string,
    unknown
  > | null;
  if (
    !body ||
    typeof body.restricted !== "boolean" ||
    Object.keys(body).some((key) => !["restricted", "workers"].includes(key))
  )
    throw new HttpError(400, "Invalid member access request");
  if (!body.restricted) {
    await env.CONCLAVE_DB.prepare(
      "DELETE FROM workspace_member_access WHERE workspace_id = ?1",
    )
      .bind(workspaceId)
      .run();
    return json({ restricted: false, policy: null });
  }
  const policy = parseWorkspaceMemberAccessPolicy({ workers: body.workers });
  const inventory = await env.CONCLAVE_DB.prepare(
    "SELECT worker_id AS workerId FROM workspace_worker_inventory WHERE workspace_id = ?1",
  )
    .bind(workspaceId)
    .all<{ workerId: string }>();
  const known = new Set(inventory.results.map((row) => row.workerId));
  if (Object.keys(policy.workers).some((id) => !known.has(id)))
    throw new HttpError(400, "Worker is outside this Workspace");
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO workspace_member_access(workspace_id,policy_json,updated_at) VALUES(?1,?2,?3)
     ON CONFLICT(workspace_id) DO UPDATE SET policy_json=excluded.policy_json,updated_at=excluded.updated_at`,
  )
    .bind(workspaceId, JSON.stringify(policy), new Date().toISOString())
    .run();
  return json({ restricted: true, policy });
}
