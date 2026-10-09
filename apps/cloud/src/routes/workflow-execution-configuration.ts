import { loadSpaceWorkflowConfigurations } from "./space-workflow-configurations.js";
import {
  parseUserWorkflowConfiguration,
  resolveUserWorkflowConfiguration,
  type WorkflowSelection,
  type BuiltinWorkflowDefinition,
} from "@conclave/core";
import { HttpError, type SecurityEnv } from "./http-security.js";
import { validateWorkflowWorkerEligibility } from "./handlers.js";

export interface WorkflowExecutionSelectionOverride {
  readonly workerId?: string | null;
  readonly model?: string | null;
  readonly reasoningEffort?: string | null;
}

export function parseWorkflowExecutionSelection(
  value: unknown,
): WorkflowExecutionSelectionOverride | undefined {
  if (value === undefined) return undefined;
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new HttpError(400, "executionSelection must be an object");
  const object = value as Record<string, unknown>;
  if (
    Object.keys(object).some(
      (key) => !["workerId", "model", "reasoningEffort"].includes(key),
    )
  )
    throw new HttpError(400, "executionSelection contains an unknown field");
  const stringOrNull = (key: string) => {
    const selected = object[key];
    if (selected === undefined || selected === null) return selected;
    if (typeof selected !== "string" || selected.trim().length === 0)
      throw new HttpError(400, `executionSelection.${key} is invalid`);
    if (selected.length > 200)
      throw new HttpError(400, `executionSelection.${key} is too long`);
    if (selected === "Auto" || selected === "Automatic") {
      if (key === "workerId")
        throw new HttpError(400, "Worker must be selected explicitly");
      if (selected === "Automatic")
        throw new HttpError(400, "Use Auto for model and effort defaults");
      return null;
    }
    return selected.trim();
  };
  return {
    ...(Object.hasOwn(object, "workerId")
      ? { workerId: stringOrNull("workerId") }
      : {}),
    ...(Object.hasOwn(object, "model") ? { model: stringOrNull("model") } : {}),
    ...(Object.hasOwn(object, "reasoningEffort")
      ? { reasoningEffort: stringOrNull("reasoningEffort") }
      : {}),
  };
}

/** Resolve configured Workers at acceptance, using the same admission rules as execution. */
export async function resolveWorkflowExecutionBindings(
  env: SecurityEnv,
  userId: string,
  spaceId: string,
  threadId: string,
  definition: BuiltinWorkflowDefinition,
  stepInstructions: Record<
    string,
    {
      additionalInstructions?: string;
    }
  >,
  attachments: readonly unknown[],
  executionSelection?: unknown,
) {
  const override = parseWorkflowExecutionSelection(executionSelection);
  if (override && definition.steps.length !== 1)
    throw new HttpError(
      400,
      "Execution overrides are available only for one-step Workflows",
    );
  const space = await loadSpaceWorkflowConfigurations(
    env,
    spaceId,
    definition.id,
  );
  if (!space.workspaceId)
    throw new HttpError(
      422,
      "Choose a Workspace in Workflows before sending a request",
    );
  const configuration = space.configurations[0]
    ? parseUserWorkflowConfiguration(definition, space.configurations[0])
    : undefined;
  const effective = resolveUserWorkflowConfiguration(definition, configuration);
  if (!effective.enabled)
    throw new HttpError(422, "Workflow is disabled in this Space");
  const inventory = await env.CONCLAVE_DB.prepare(
    `SELECT i.worker_id AS workerId, i.workspace_id AS workspaceId
     FROM workspace_worker_inventory i
     WHERE i.workspace_id = ?1 ORDER BY i.workspace_id, i.worker_id`,
  )
    .bind(space.workspaceId)
    .all<{ workerId: string; workspaceId: string }>();
  const requested: Record<
    string,
    {
      workerId?: string;
      model?: string;
      reasoningEffort?: string;
      additionalInstructions?: string;
    }
  > = {};
  let pinnedWorkspace: string | null = null;
  for (const step of definition.steps) {
    const id = definition.id === "direct" ? "direct" : step.kind;
    const configuredSelection = effective.steps[step.kind] ?? {};
    const selection: WorkflowSelection = {
      ...configuredSelection,
      ...(override && Object.hasOwn(override, "workerId")
        ? { worker: override.workerId ?? undefined }
        : {}),
      ...(override && Object.hasOwn(override, "model")
        ? { model: override.model ?? undefined }
        : {}),
      ...(override && Object.hasOwn(override, "reasoningEffort")
        ? { effort: override.reasoningEffort ?? undefined }
        : {}),
    };
    const instructions = stepInstructions[id]?.additionalInstructions;
    if (!selection.worker)
      throw new HttpError(
        422,
        `${step.kind}: Select a Worker before sending this Workflow`,
      );
    if (
      !inventory.results.some(
        (candidate) => candidate.workerId === selection.worker,
      )
    )
      throw new HttpError(
        422,
        `${step.kind}: Configured Worker is unavailable for this Space`,
      );
    const value = {
      ...(selection.worker ? { workerId: selection.worker } : {}),
      ...(selection.model ? { model: selection.model } : {}),
      ...(selection.effort ? { reasoningEffort: selection.effort } : {}),
      ...(instructions ? { additionalInstructions: instructions } : {}),
    };
    requested[id] = value;
    if (value.workerId) {
      const admission = await validateWorkflowWorkerEligibility(
        env,
        spaceId,
        threadId,
        { ...definition, steps: [step] },
        { [id]: value },
        attachments,
      );
      if (admission.issues.length)
        throw new HttpError(
          422,
          admission.issues.map((issue) => issue.message).join(" "),
        );
      if (pinnedWorkspace && admission.primaryWorkspaceId !== pinnedWorkspace)
        throw new HttpError(
          422,
          "Workflow Workers must execute in the same Workspace",
      );
      pinnedWorkspace = admission.primaryWorkspaceId;
    }
  }
  return requested;
}
