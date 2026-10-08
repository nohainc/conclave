import {
  BUILTIN_WORKFLOW_CATALOG,
  DomainInvariantError,
  parseUserWorkflowConfiguration,
  resolveUserWorkflowConfiguration,
  validateWorkerExecutionSelection,
  type UserWorkflowConfiguration,
} from "@conclave/core";
import {
  HttpError,
  json,
  securityContext,
  type SecurityEnv,
} from "./http-security.js";
import { handleListWorkspaceWorkerInventory } from "./profiles.js";
import type { WorkerExecutionOptions } from "@conclave/core";

function definitionFor(id: string) {
  const definition = Object.values(BUILTIN_WORKFLOW_CATALOG)
    .filter((entry) => entry.id === id)
    .sort((a, b) => b.version - a.version)[0];
  if (!definition) throw new HttpError(404, "Unknown workflow");
  return definition;
}

export async function handleWorkflowConfigurations(
  request: Request,
  env: SecurityEnv,
  workflowId?: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const db = env.CONCLAVE_DB;
  if (request.method === "GET") {
    if (workflowId) definitionFor(workflowId);
    const rows = await db
      .prepare(
        `SELECT configuration_json FROM user_workflow_configurations
      WHERE user_id = ?1 AND (?2 IS NULL OR workflow_id = ?2)`,
      )
      .bind(context.userId, workflowId ?? null)
      .all<{ configuration_json: string }>();
    return json({
      schemaVersion: 1,
      configurations: rows.results.map((row) =>
        JSON.parse(row.configuration_json),
      ),
    });
  }
  if (!workflowId)
    throw new HttpError(405, "Choose a workflow for this operation");
  const definition = definitionFor(workflowId);
  const reset = async () => {
    await db
      .prepare(
        "DELETE FROM user_workflow_configurations WHERE user_id = ?1 AND workflow_id = ?2",
      )
      .bind(context.userId, workflowId)
      .run();
  };
  if (request.method === "DELETE") {
    await reset();
    return json({
      configuration: parseUserWorkflowConfiguration(definition, {
        schemaVersion: 1,
        workflowId,
        enabled: true,
        defaults: {},
        stepOverrides: {},
      }),
    });
  }
  if (request.method !== "PUT") throw new HttpError(405, "Unsupported method");
  let configuration: UserWorkflowConfiguration;
  try {
    configuration = parseUserWorkflowConfiguration(
      definition,
      await request.json(),
    );
  } catch (error) {
    if (error instanceof DomainInvariantError || error instanceof SyntaxError)
      throw new HttpError(400, error.message);
    throw error;
  }
  const inventoryResponse = await handleListWorkspaceWorkerInventory(
    new Request(new URL("/api/workers/inventory", request.url), {
      headers: request.headers,
    }),
    env,
    ctx,
  );
  const inventory = (await inventoryResponse.json()) as {
    workers: { id: string; executionOptions: WorkerExecutionOptions | null }[];
  };
  const previous = await db
    .prepare(
      "SELECT configuration_json FROM user_workflow_configurations WHERE user_id = ?1 AND workflow_id = ?2",
    )
    .bind(context.userId, workflowId)
    .first<{ configuration_json: string }>();
  const priorConfiguration: UserWorkflowConfiguration | undefined = previous
    ? JSON.parse(previous.configuration_json)
    : undefined;
  const old: Record<
    string,
    import("@conclave/core").WorkflowSelection | undefined
  > = {
    ...resolveUserWorkflowConfiguration(definition, priorConfiguration).steps,
    defaults: priorConfiguration?.defaults,
  };
  for (const [stepId, selection] of Object.entries({
    ...resolveUserWorkflowConfiguration(definition, configuration).steps,
    defaults: configuration.defaults,
  })) {
    if (!selection.worker) {
      // Auto Worker resolves later; check choices against at least one owned Profile.
      if (!selection.model && !selection.effort) continue;
      if (
        inventory.workers.some(
          (worker) =>
            worker.executionOptions &&
            !validateWorkerExecutionSelection(
              worker.executionOptions,
              selection.model ?? null,
              selection.effort ?? null,
            ),
        )
      )
        continue;
      throw new HttpError(
        400,
        "No owned Worker supports the selected model/effort",
      );
    }
    const worker = inventory.workers.find(
      (worker) => worker.id === selection.worker,
    );
    // Removing a step override may restore already-saved defaults even while
    // the Worker/Profile is unavailable. It does not invent a new selection.
    const inherited =
      stepId !== "defaults" &&
      !configuration.stepOverrides[
        stepId as keyof typeof configuration.stepOverrides
      ];
    const prior = inherited ? priorConfiguration?.defaults : old[stepId];
    // Unavailable inventory/Profile must not erase unchanged user intent.
    if (
      (!worker || !worker.executionOptions) &&
      prior?.worker === selection.worker &&
      prior?.model === selection.model &&
      prior?.effort === selection.effort
    )
      continue;
    if (!worker)
      throw new HttpError(400, "Worker is not owned by the current user");
    if (!selection.model && !selection.effort) continue;
    if (!worker.executionOptions)
      throw new HttpError(400, "Worker Profile capabilities are unavailable");
    const error = validateWorkerExecutionSelection(
      worker.executionOptions,
      selection.model ?? null,
      selection.effort ?? null,
    );
    if (error) throw new HttpError(400, error);
  }
  if (
    configuration.enabled &&
    !Object.keys(configuration.defaults).length &&
    !Object.keys(configuration.stepOverrides).length
  ) {
    await reset();
  } else {
    await db
      .prepare(
        `INSERT INTO user_workflow_configurations
      (user_id, workflow_id, schema_version, configuration_json, updated_at) VALUES (?1, ?2, 1, ?3, ?4)
      ON CONFLICT(user_id, workflow_id) DO UPDATE SET configuration_json = excluded.configuration_json, updated_at = excluded.updated_at`,
      )
      .bind(
        context.userId,
        workflowId,
        JSON.stringify(configuration),
        new Date().toISOString(),
      )
      .run();
  }
  return json({ configuration });
}
