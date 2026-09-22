import type { ExecutionPolicyMode } from "./index.js";
import type { Worker } from "./entities.js";

export interface WorkerRoutingRequirement {
  readonly capability: string;
  readonly role?: string;
  readonly maxEstimatedCostMicrosPerAttempt?: number;
}

export type QualityPreset =
  "economy" | "balanced" | "high_assurance" | "exploration" | "custom";

export interface QualityConfig {
  readonly mode: ExecutionPolicyMode;
  readonly candidateCount: number;
  readonly maxParallel: number;
  readonly requireIndependentWorkers: boolean;
  readonly requiresDecisionWorker: boolean;
  readonly maxEstimatedCostMicrosPerAttempt: number | null;
}

export interface QualitySelection {
  readonly preset: QualityPreset;
  readonly config: QualityConfig;
}

export interface CustomQualityConfig {
  readonly mode?: ExecutionPolicyMode;
  readonly candidateCount?: number;
  readonly maxParallel?: number;
  readonly requireIndependentWorkers?: boolean;
  readonly requiresDecisionWorker?: boolean;
  readonly maxEstimatedCostMicrosPerAttempt?: number | null;
}

export class QualityRoutingError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "QualityRoutingError";
  }
}

const presets: Record<Exclude<QualityPreset, "custom">, QualityConfig> = {
  economy: {
    mode: "single",
    candidateCount: 1,
    maxParallel: 1,
    requireIndependentWorkers: false,
    requiresDecisionWorker: false,
    maxEstimatedCostMicrosPerAttempt: 5_000,
  },
  balanced: {
    mode: "parallel",
    candidateCount: 2,
    maxParallel: 2,
    requireIndependentWorkers: true,
    requiresDecisionWorker: false,
    maxEstimatedCostMicrosPerAttempt: 20_000,
  },
  high_assurance: {
    mode: "synthesize",
    candidateCount: 2,
    maxParallel: 2,
    requireIndependentWorkers: true,
    requiresDecisionWorker: true,
    maxEstimatedCostMicrosPerAttempt: 50_000,
  },
  exploration: {
    mode: "synthesize",
    candidateCount: 3,
    maxParallel: 3,
    requireIndependentWorkers: true,
    requiresDecisionWorker: true,
    maxEstimatedCostMicrosPerAttempt: null,
  },
};

function positiveInteger(value: number, field: string): void {
  if (!Number.isInteger(value) || value < 1) {
    throw new QualityRoutingError(`${field} must be a positive integer`);
  }
}

export function resolveQuality(
  preset: QualityPreset,
  custom: CustomQualityConfig = {},
): QualitySelection {
  if (preset !== "custom") return { preset, config: presets[preset] };
  const config: QualityConfig = {
    mode: custom.mode ?? "single",
    candidateCount: custom.candidateCount ?? 1,
    maxParallel: custom.maxParallel ?? custom.candidateCount ?? 1,
    requireIndependentWorkers: custom.requireIndependentWorkers ?? false,
    requiresDecisionWorker: custom.requiresDecisionWorker ?? false,
    maxEstimatedCostMicrosPerAttempt:
      custom.maxEstimatedCostMicrosPerAttempt ?? null,
  };
  positiveInteger(config.candidateCount, "candidateCount");
  positiveInteger(config.maxParallel, "maxParallel");
  if (config.maxParallel > config.candidateCount) {
    throw new QualityRoutingError(
      "maxParallel cannot exceed candidateCount for a custom quality policy",
    );
  }
  if (config.mode === "single" && config.candidateCount !== 1) {
    throw new QualityRoutingError("single mode requires candidateCount = 1");
  }
  if (config.requiresDecisionWorker && config.mode === "single") {
    throw new QualityRoutingError(
      "single mode cannot require a decision worker",
    );
  }
  if (
    config.maxEstimatedCostMicrosPerAttempt !== null &&
    config.maxEstimatedCostMicrosPerAttempt < 0
  ) {
    throw new QualityRoutingError("Cost ceiling cannot be negative");
  }
  return { preset, config };
}

function eligible(
  worker: Worker,
  requirement: WorkerRoutingRequirement,
  ceiling: number | null,
): boolean {
  const cost = worker.costMetadata?.estimatedCostMicrosPerAttempt ?? null;
  return (
    worker.enabled &&
    worker.availability === "available" &&
    worker.capabilities.includes(requirement.capability) &&
    (requirement.role === undefined ||
      worker.roles.includes(requirement.role)) &&
    (ceiling === null || (cost !== null && cost <= ceiling)) &&
    (requirement.maxEstimatedCostMicrosPerAttempt === undefined ||
      (cost !== null && cost <= requirement.maxEstimatedCostMicrosPerAttempt))
  );
}

function workerCost(worker: Worker): number {
  return (
    worker.costMetadata?.estimatedCostMicrosPerAttempt ??
    Number.MAX_SAFE_INTEGER
  );
}

export function routeWorkers(
  workers: readonly Worker[],
  requirement: WorkerRoutingRequirement,
  selection: QualitySelection,
): readonly Worker[] {
  const candidates = workers
    .filter((worker) =>
      eligible(
        worker,
        requirement,
        selection.config.maxEstimatedCostMicrosPerAttempt,
      ),
    )
    .sort(
      (left, right) =>
        workerCost(left) - workerCost(right) || left.id.localeCompare(right.id),
    );
  const selected: Worker[] = [];
  const independenceKeys = new Set<string>();
  for (const candidate of candidates) {
    if (
      selection.config.requireIndependentWorkers &&
      independenceKeys.has(candidate.independenceKey)
    ) {
      continue;
    }
    selected.push(candidate);
    independenceKeys.add(candidate.independenceKey);
    if (selected.length === selection.config.candidateCount) break;
  }
  if (selected.length < selection.config.candidateCount) {
    throw new QualityRoutingError(
      `Quality preset ${selection.preset} requires ${selection.config.candidateCount} eligible independent workers; found ${selected.length}`,
    );
  }
  return selected;
}

export function estimatedSelectionCost(
  workers: readonly Worker[],
): number | null {
  let total = 0;
  for (const worker of workers) {
    const cost = worker.costMetadata?.estimatedCostMicrosPerAttempt ?? null;
    if (cost === null) return null;
    total += cost;
  }
  return total;
}

export function workerCostEstimate(worker: Worker): number | null {
  return worker.costMetadata?.estimatedCostMicrosPerAttempt ?? null;
}
