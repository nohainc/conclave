/** Product-safe options projected from a signed Profile, never CLI instructions. */
export interface WorkerEffortOptions {
  readonly supported: boolean;
  readonly values: readonly string[];
  readonly defaultValue: string | null;
}
export interface WorkerModelOption {
  readonly id: string;
  readonly name: string;
  readonly badge?: string;
  readonly description?: string;
  readonly effort: WorkerEffortOptions;
}
export interface WorkerExecutionOptions {
  readonly schemaVersion: 1;
  readonly models: {
    readonly supported: boolean;
    /** Current qualified source; live provider discovery is not inferred. */
    readonly discovery: "profile_catalog";
    readonly allowsCustomModel: boolean;
    readonly allowedModelIds: readonly string[];
    /** null means provider Default; it is not a resolved provider model. */
    readonly defaultModelId: string | null;
    readonly options: readonly WorkerModelOption[];
  };
  readonly modelSwitch: { readonly supported: boolean };
  /** Options for Default or a pass-through model without a catalog override. */
  readonly effort: WorkerEffortOptions;
}

export function workerEffortOptionsForModel(
  options: WorkerExecutionOptions,
  modelId: string | null,
): WorkerEffortOptions {
  return (
    options.models.options.find(
      (model) => model.id === (modelId ?? options.models.defaultModelId),
    )?.effort ?? options.effort
  );
}

export function validateWorkerExecutionSelection(
  options: WorkerExecutionOptions,
  modelId: string | null,
  effort: string | null,
): string | null {
  if (
    modelId !== null &&
    (!options.models.supported ||
      (!options.models.allowsCustomModel &&
        !options.models.allowedModelIds.includes(modelId)))
  ) {
    return "The selected model is not available for this Worker Profile";
  }
  const supported = workerEffortOptionsForModel(options, modelId);
  if (
    effort !== null &&
    (!supported.supported || !supported.values.includes(effort))
  ) {
    return "The selected effort is not available for this model and Worker Profile";
  }
  return null;
}
