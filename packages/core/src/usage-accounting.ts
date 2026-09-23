export type BillingCategory = "subscription" | "api" | "local" | "unknown";

export interface UsageAttribution {
  readonly requesterUserId: string;
  readonly projectId: string;
  readonly workerId: string;
  readonly provider: string | null;
  readonly model: string | null;
  readonly credentialProfileId: string;
  readonly credentialProfileOwnerType: "user" | "workspace";
  readonly credentialProfileOwnerId: string;
  readonly hostId: string;
  readonly inputTokens: number;
  readonly outputTokens: number;
  /** Null means the provider did not supply a monetary amount. */
  readonly costMicros: number | null;
  readonly durationMs: number;
  readonly billingCategory: BillingCategory;
}

export interface BudgetLimits {
  readonly maxInputTokens: number | null;
  readonly maxOutputTokens: number | null;
  readonly maxCostMicros: number | null;
}

export interface BudgetUsage {
  readonly inputTokens: number;
  readonly outputTokens: number;
  readonly knownCostMicros: number;
}

export type BudgetDecision =
  | { readonly allowed: true }
  | {
      readonly allowed: false;
      readonly reason:
        "input_tokens" | "output_tokens" | "cost" | "cost_unknown";
    };

/**
 * Checks a proposed usage event without manufacturing a price for subscription
 * providers whose billing data is unavailable.
 */
export function evaluateBudget(
  limits: BudgetLimits,
  current: BudgetUsage,
  proposed: Pick<
    UsageAttribution,
    "inputTokens" | "outputTokens" | "costMicros"
  >,
): BudgetDecision {
  if (
    limits.maxInputTokens !== null &&
    current.inputTokens + proposed.inputTokens > limits.maxInputTokens
  ) {
    return { allowed: false, reason: "input_tokens" };
  }
  if (
    limits.maxOutputTokens !== null &&
    current.outputTokens + proposed.outputTokens > limits.maxOutputTokens
  ) {
    return { allowed: false, reason: "output_tokens" };
  }
  if (limits.maxCostMicros !== null) {
    if (proposed.costMicros === null) {
      return { allowed: false, reason: "cost_unknown" };
    }
    if (current.knownCostMicros + proposed.costMicros > limits.maxCostMicros) {
      return { allowed: false, reason: "cost" };
    }
  }
  return { allowed: true };
}

export function budgetUsageDelta(
  usage: Pick<UsageAttribution, "inputTokens" | "outputTokens" | "costMicros">,
): BudgetUsage {
  return {
    inputTokens: usage.inputTokens,
    outputTokens: usage.outputTokens,
    knownCostMicros: usage.costMicros ?? 0,
  };
}
