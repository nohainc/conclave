import type { ToolProfileV1 } from "@conclave/tool-profile";
import type {
  WorkerExecutionOptions,
  WorkerEffortOptions,
} from "@conclave/core";
/** Expose selection metadata only, never CLI commands or credential configuration. */
export function projectModelOptions(
  payload: unknown,
  providerVersion?: unknown,
) {
  let profile: Record<string, unknown>;
  try {
    profile = JSON.parse(String(payload));
  } catch {
    return null;
  }
  const model = profile?.model as Record<string, unknown> | undefined;
  if (!model || model.supported !== true) return null;
  const efforts = (value: unknown) =>
    Array.isArray(value)
      ? value.filter((item): item is string => typeof item === "string")
      : [];
  const version = (value: unknown) =>
    typeof value === "string" && /^\d+\.\d+\.\d+(?:[-+].*)?$/.test(value)
      ? value.split(/[.+-]/).slice(0, 3).map(Number)
      : null;
  const installed = version(providerVersion);
  const compatible = (entry: Record<string, unknown>) => {
    for (const key of ["minProviderVersion", "maxProviderVersion"] as const) {
      if (entry[key] === undefined) continue;
      const bound = version(entry[key]);
      if (!installed || !bound) return false;
      let comparison = 0;
      for (let i = 0; i < 3; i++) {
        if (installed[i] !== bound[i]) {
          comparison = installed[i]! - bound[i]!;
          break;
        }
      }
      if (
        (key === "minProviderVersion" && comparison < 0) ||
        (key === "maxProviderVersion" && comparison > 0)
      )
        return false;
    }
    return true;
  };
  const allowlist = efforts(model.allowlist);
  const catalog = Array.isArray(model.catalog) ? model.catalog : [];
  return {
    supportedReasoningEfforts: efforts(model.supportedReasoningEfforts),
    defaultReasoningEffort:
      typeof model.defaultReasoningEffort === "string"
        ? model.defaultReasoningEffort
        : null,
    catalog: catalog
      .filter(
        (entry) =>
          entry &&
          typeof entry.id === "string" &&
          compatible(entry) &&
          (model.unknownModelPolicy !== "profile_allowlist" ||
            allowlist.includes(entry.id)),
      )
      .map((entry) => ({
        id: entry.id,
        name: entry.name,
        badge: entry.badge,
        description: entry.description,
        minProviderVersion: entry.minProviderVersion,
        maxProviderVersion: entry.maxProviderVersion,
        defaultReasoningEffort: entry.defaultReasoningEffort,
        supportedReasoningEfforts:
          entry.supportedReasoningEfforts === undefined
            ? efforts(model.supportedReasoningEfforts)
            : efforts(entry.supportedReasoningEfforts),
      })),
  };
}

/** Normalized, versioned public capabilities; provider mappings remain signed/local. */
export function projectWorkerExecutionOptions(
  payload: unknown,
  providerVersion?: unknown,
): WorkerExecutionOptions | null {
  let profile: Partial<ToolProfileV1>;
  try {
    profile = JSON.parse(String(payload));
  } catch {
    return null;
  }
  const model = profile?.model;
  if (!model || typeof model.supported !== "boolean") return null;
  const declared = model.executionOptions;
  if (
    declared &&
    (declared.schemaVersion !== 1 || declared.discovery !== "profile_catalog")
  )
    return null;
  const projection = projectModelOptions(payload, providerVersion);
  const normalizeEffort = (
    values: unknown,
    defaultValue: unknown,
  ): WorkerEffortOptions => {
    const choices =
      declared?.effortSupported === false || !Array.isArray(values)
        ? []
        : [
            ...new Set(
              values.filter(
                (value): value is string => typeof value === "string",
              ),
            ),
          ];
    return {
      supported: choices.length > 0,
      values: choices,
      defaultValue:
        typeof defaultValue === "string" && choices.includes(defaultValue)
          ? defaultValue
          : null,
    };
  };
  const catalog = projection?.catalog ?? [];
  const defaultModel =
    typeof declared?.defaultModelId === "string" &&
    catalog.some((entry) => entry.id === declared.defaultModelId)
      ? declared.defaultModelId
      : null;
  return {
    schemaVersion: 1,
    models: {
      supported: model.supported,
      discovery: "profile_catalog",
      allowsCustomModel:
        model.supported && model.unknownModelPolicy === "pass_through",
      allowedModelIds: model.supported
        ? model.unknownModelPolicy === "profile_allowlist"
          ? Array.isArray(model.allowlist)
            ? model.allowlist.filter(
                (id) =>
                  typeof id === "string" &&
                  (!Array.isArray(model.catalog) ||
                    !model.catalog.some((entry) => entry.id === id) ||
                    catalog.some((entry) => entry.id === id)),
              )
            : []
          : catalog.map((entry) => entry.id)
        : [],
      defaultModelId: defaultModel,
      options: catalog.map((entry) => ({
        id: entry.id,
        name: entry.name,
        ...(typeof entry.badge === "string" ? { badge: entry.badge } : {}),
        ...(typeof entry.description === "string"
          ? { description: entry.description }
          : {}),
        effort: normalizeEffort(
          entry.supportedReasoningEfforts,
          entry.defaultReasoningEffort ?? projection?.defaultReasoningEffort,
        ),
      })),
    },
    modelSwitch: {
      supported:
        model.supported &&
        profile.session?.supported === true &&
        declared?.modelSwitchSupported !== false,
    },
    effort: normalizeEffort(
      model.supportedReasoningEfforts,
      model.defaultReasoningEffort,
    ),
  };
}
