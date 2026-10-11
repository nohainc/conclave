import { WorkspaceWorkerInventoryEntrySchema } from "@conclave/workspace-runtime-protocol";
import type { ToolProfileV1 } from "@conclave/tool-profile";
import type {
  WorkerExecutionOptions,
  WorkerEffortOptions,
} from "@conclave/core";
/** Expose selection metadata only, never CLI commands or credential configuration. */
export function spaceModelOptions(
  payload: unknown,
  providerVersion?: unknown,
  discoveredCatalog?: unknown,
  profileDigest?: unknown,
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
  // A discovery-backed profile has no signed fallback catalog. The local
  // Workspace is the authority for the models and effort values available on
  // that installation; until it publishes a matching catalog, no choices are
  // exposed to AX.
  let catalog = model.discovery
    ? []
    : Array.isArray(model.catalog)
      ? model.catalog
      : [];
  if (model.discovery) {
    const spec = model.discovery as { idPrefix?: string };
    let rawCatalog: unknown;
    try {
      rawCatalog =
        typeof discoveredCatalog === "string"
          ? JSON.parse(discoveredCatalog)
          : discoveredCatalog;
    } catch {
      rawCatalog = null;
    }
    const parsedCatalog =
      WorkspaceWorkerInventoryEntrySchema.shape.modelCatalog.safeParse(
        rawCatalog,
      );
    const discovered = parsedCatalog.success ? parsedCatalog.data : null;
    // Local metadata cannot widen an unrelated or retired signed release.
    catalog =
      discovered &&
      discovered.profileDigest === profileDigest &&
      discovered.providerToolVersion === providerVersion &&
      typeof spec.idPrefix === "string"
        ? discovered.models
            .filter(
              (entry) =>
                (spec.idPrefix!.length === 0 ||
                  entry.id.startsWith(spec.idPrefix!)) &&
                entry.status !== "unavailable",
            )
            .map((entry) => ({
              id: entry.id,
              name: entry.name,
              badge: entry.status === "verified" ? "Verified" : "Listed",
              ...(entry.supportedReasoningEfforts
                ? {
                    supportedReasoningEfforts: entry.supportedReasoningEfforts,
                  }
                : {}),
              ...(entry.defaultReasoningEffort
                ? { defaultReasoningEffort: entry.defaultReasoningEffort }
                : {}),
            }))
        : [];
  }
  return {
    supportedReasoningEfforts: model.discovery
      ? []
      : efforts(model.supportedReasoningEfforts),
    defaultReasoningEffort: model.discovery
      ? null
      : typeof model.defaultReasoningEffort === "string"
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

/** Normalized, versioned public execution options; provider mappings remain signed/local. */
export function spaceWorkerExecutionOptions(
  payload: unknown,
  providerVersion?: unknown,
  discoveredCatalog?: unknown,
  profileDigest?: unknown,
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
  const projection = spaceModelOptions(
    payload,
    providerVersion,
    discoveredCatalog,
    profileDigest,
  );
  const normalizeEffort = (
    values: unknown,
    defaultValue: unknown,
  ): WorkerEffortOptions => {
    const choices =
      (!model.discovery && declared?.effortSupported === false) ||
      !Array.isArray(values)
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
      discovery: model.discovery ? "provider_catalog" : "profile_catalog",
      allowsCustomModel:
        model.supported &&
        !model.discovery &&
        model.unknownModelPolicy === "pass_through",
      allowedModelIds: model.supported
        ? model.discovery
          ? catalog.map((entry) => entry.id)
          : model.unknownModelPolicy === "profile_allowlist"
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
