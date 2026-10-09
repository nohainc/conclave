import { loadSpaceWorkflowConfigurations } from "./space-workflow-configurations.js";
import {
  parseUserWorkflowConfiguration,
  resolveUserWorkflowConfiguration,
  type BuiltinWorkflowDefinition,
} from "@conclave/core";
import { HttpError, type SecurityEnv } from "./http-security.js";
import { validateWorkflowWorkerEligibility } from "./handlers.js";

/** Resolve Auto once at acceptance, using the same admission rules as execution. */
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
) {
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
  const rejectionReasons = new Set<string>();
  for (const step of definition.steps) {
    const id = definition.id === "direct" ? "direct" : step.kind;
    const selection = effective.steps[step.kind] ?? {};
    const instructions = stepInstructions[id]?.additionalInstructions;
    if (
      selection.worker &&
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
  // Evaluate whole-workflow feasibility before freezing Auto. A greedy choice
  // for the first step must not hide a Workspace able to execute every step.
  const workspaces = pinnedWorkspace
    ? [pinnedWorkspace]
    : [...new Set(inventory.results.map((worker) => worker.workspaceId))];
  for (const workspaceId of workspaces) {
    const bindings: typeof requested = {};
    let eligible = true;
    for (const step of definition.steps) {
      const id = definition.id === "direct" ? "direct" : step.kind;
      const value = { ...requested[id] };
      if (!value.workerId) {
        for (const candidate of inventory.results.filter(
          (worker) => worker.workspaceId === workspaceId,
        )) {
          const proposed = { ...value, workerId: candidate.workerId };
          const admission = await validateWorkflowWorkerEligibility(
            env,
            spaceId,
            threadId,
            { ...definition, steps: [step] },
            { [id]: proposed },
            attachments,
          );
          for (const issue of admission.issues) {
            if (issue.message.trim()) rejectionReasons.add(issue.message);
          }
          if (
            !admission.issues.length &&
            admission.primaryWorkspaceId === workspaceId
          ) {
            value.workerId = candidate.workerId;
            break;
          }
        }
        if (!value.workerId) {
          eligible = false;
          break;
        }
      }
      bindings[id] = value;
    }
    if (eligible) return bindings;
  }
  const details = [...rejectionReasons].slice(0, 8);
  throw new HttpError(
    422,
    `No eligible Space Workers support this workflow configuration in one Workspace${details.length ? `: ${details.join(" ")}` : ""}`,
  );
}
