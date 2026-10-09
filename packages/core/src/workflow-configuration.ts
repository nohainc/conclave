import { DomainInvariantError } from "./domain-error.js";
import type {
  BuiltinWorkflowDefinition,
  WorkflowId,
  StepKind,
} from "./thread.js";

/** Worker is explicit when present; model and effort may be Auto/omitted. */
export interface WorkflowSelection {
  readonly worker?: string;
  readonly model?: string;
  readonly effort?: string;
}
export interface UserWorkflowConfiguration {
  readonly schemaVersion: 1;
  readonly workflowId: WorkflowId;
  readonly enabled: boolean;
  readonly defaults: WorkflowSelection;
  readonly stepOverrides: Readonly<
    Partial<Record<StepKind, WorkflowSelection>>
  >;
}
export interface EffectiveWorkflowConfiguration {
  readonly definition: BuiltinWorkflowDefinition;
  readonly enabled: boolean;
  readonly steps: Readonly<Partial<Record<StepKind, WorkflowSelection>>>;
}

/** A pure overlay boundary; execution authorization/readiness remains separate. */
export function resolveUserWorkflowConfiguration(
  definition: BuiltinWorkflowDefinition,
  configuration?: UserWorkflowConfiguration,
): EffectiveWorkflowConfiguration {
  if (configuration && configuration.workflowId !== definition.id)
    throw new DomainInvariantError("Workflow configuration identity mismatch");
  return {
    definition,
    enabled: configuration?.enabled ?? true,
    steps: Object.fromEntries(
      definition.steps.map((step) => [
        step.kind,
        {
          ...configuration?.defaults,
          ...configuration?.stepOverrides[step.kind],
        },
      ]),
    ),
  };
}

/** Strict versioned write boundary. null/Auto normalize to omission for model/effort. */
export function parseUserWorkflowConfiguration(
  definition: BuiltinWorkflowDefinition,
  input: unknown,
): UserWorkflowConfiguration {
  const object = (value: unknown): Record<string, unknown> => {
    if (!value || typeof value !== "object" || Array.isArray(value))
      throw new DomainInvariantError("Expected configuration object");
    return value as Record<string, unknown>;
  };
  const keys = (value: Record<string, unknown>, allowed: readonly string[]) => {
    if (Object.keys(value).some((key) => !allowed.includes(key)))
      throw new DomainInvariantError("Unknown configuration field");
  };
  const selection = (input: unknown): WorkflowSelection => {
    const value = object(input);
    keys(value, ["worker", "model", "effort"]);
    const result: Record<string, string> = {};
    for (const key of ["worker", "model", "effort"] as const) {
      const choice = value[key];
      if (choice === undefined || choice === null) continue;
      if (choice === "Auto" || choice === "Automatic") {
        if (key === "worker")
          throw new DomainInvariantError("Worker must be selected explicitly");
        if (choice === "Automatic")
          throw new DomainInvariantError("Use Auto for model and effort defaults");
        continue;
      }
      if (typeof choice !== "string" || !choice.trim() || choice.length > 200)
        throw new DomainInvariantError(`Invalid ${key} selection`);
      result[key] = choice.trim();
    }
    return result;
  };
  const value = object(input);
  keys(value, [
    "schemaVersion",
    "workflowId",
    "enabled",
    "defaults",
    "stepOverrides",
  ]);
  if (
    value.schemaVersion !== 1 ||
    value.workflowId !== definition.id ||
    typeof value.enabled !== "boolean"
  )
    throw new DomainInvariantError(
      "Invalid configuration version, identity or enabled flag",
    );
  const overrides = object(value.stepOverrides ?? {});
  keys(
    overrides,
    definition.steps.map((step) => step.kind),
  );
  return {
    schemaVersion: 1,
    workflowId: definition.id,
    enabled: value.enabled,
    defaults: selection(value.defaults ?? {}),
    stepOverrides: Object.fromEntries(
      Object.entries(overrides)
        .map(([id, value]) => [id, selection(value)] as const)
        .filter(([, value]) => Object.keys(value).length > 0),
    ),
  };
}
