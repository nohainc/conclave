import type { GoalSummary } from "@conclave/core";

export interface RuntimeConfig {
  readonly environment: string;
  readonly apiBaseUrl: URL;
}

export function loadRuntimeConfig(
  env: Record<string, string | undefined>,
): RuntimeConfig {
  const environment = env.CONCLAVE_ENVIRONMENT ?? "development";
  const apiBaseUrl = new URL(
    env.CONCLAVE_API_BASE_URL ?? "http://localhost:8787",
  );
  return { environment, apiBaseUrl };
}

export function describeRuntimeGoal(goal: GoalSummary): string {
  return `${goal.id}: ${goal.objective} [${goal.status}]`;
}
