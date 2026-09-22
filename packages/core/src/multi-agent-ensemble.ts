/**
 * Conclave AX Architecture v2 - Multi-Agent & Multi-Worker Ensemble Execution Engine.
 *
 * Coordinates execution of candidate workers residing on disparate physical machines,
 * agent hosts, and runtimes (e.g. MacBook, Linux server, Web worker) across ensemble modes:
 * - single: 1 worker on 1 agent
 * - parallel: N candidate workers running concurrently across machines
 * - synthesize: N candidate workers across machines + 1 independent synthesizer worker
 * - compare_and_select: N candidate workers across machines + 1 independent selector worker
 * - competitive_implementation: N candidate implementers on isolated workspaces + independent reviewer verification
 */

import {
  DecisionResultSchema,
  type DecisionResult,
  type TaskRequest,
} from "@conclave/protocol";

export type MultiAgentEnsembleMode =
  | "single"
  | "parallel"
  | "synthesize"
  | "compare_and_select"
  | "competitive_implementation";

export interface MultiAgentTaskRequest {
  readonly taskId: string;
  readonly role: string;
  readonly objective: string;
  readonly requiredCapabilities?: readonly string[];
  readonly input?: Record<string, unknown>;
  readonly contextArtifactIds?: readonly string[];
  readonly timeoutMs?: number;
  readonly goalId?: string;
  readonly runId?: string;
}

export interface MultiAgentCandidateExecutionResult {
  readonly status: "succeeded" | "failed" | "timed_out";
  readonly output: Record<string, unknown> | null;
  readonly rawOutput?: string | null;
  readonly artifactIds?: readonly string[];
  readonly findings?: readonly unknown[];
  readonly usage?: {
    readonly inputTokens?: number | null;
    readonly outputTokens?: number | null;
    readonly totalTokens?: number | null;
  };
  readonly error?: {
    readonly code: string;
    readonly message: string;
    readonly retryable: boolean;
  } | null;
  readonly executionTimeMs?: number;
}

export interface MultiAgentWorkerDescriptor {
  readonly workerId: string;
  readonly agentId: string;
  readonly pluginId: string;
  readonly name: string;
  readonly role: string;
  readonly capabilities: readonly string[];
  readonly independenceKey: string;
  readonly execute: (
    task: MultiAgentTaskRequest,
  ) => Promise<MultiAgentCandidateExecutionResult>;
}

export interface MultiAgentEnsemblePolicy {
  readonly mode: MultiAgentEnsembleMode;
  /** Maximum number of candidate workers running concurrently. */
  readonly maxParallel?: number;
  /** Timeout per candidate worker in milliseconds. */
  readonly timeoutMs?: number;
  /** Minimum number of successful candidates required for synthesis / comparison. Defaults to 1. */
  readonly minSuccessfulCandidates?: number;
  /** Optional custom synthesis instructions. */
  readonly synthesisPrompt?: string;
  /** Optional evaluation criteria for compare_and_select. */
  readonly evaluationCriteria?: readonly string[];
  /** Hard per-attempt cost ceiling used by cloud schedulers when routing Workers. */
  readonly maxEstimatedCostMicrosPerAttempt?: number;
  /** Billing modes to prefer, in order, when several Workers are eligible. */
  readonly preferredBillingModes?: readonly string[];
}

export interface MultiAgentCandidateResult {
  readonly workerId: string;
  readonly agentId: string;
  readonly pluginId: string;
  readonly name: string;
  readonly independenceKey: string;
  readonly workspaceRepositoryId?: string;
  readonly result: MultiAgentCandidateExecutionResult;
}

export interface MultiAgentVerificationResult {
  readonly candidateWorkerId: string;
  readonly reviewerWorkerId: string;
  readonly reviewerAgentId: string;
  readonly passed: boolean;
  readonly score: number;
  readonly feedback: string;
}

export interface MultiAgentEnsembleResult {
  readonly mode: MultiAgentEnsembleMode;
  readonly candidates: readonly MultiAgentCandidateResult[];
  /** The consolidated decision or synthesis output, if applicable. */
  readonly decisionResult: MultiAgentCandidateExecutionResult | null;
  readonly decision: DecisionResult | null;
  readonly decisionTask: TaskRequest | null;
  /** For selection policies: winning candidate index and identifiers. */
  readonly selectedCandidateIndex?: number | null;
  readonly selectedWorkerId?: string | null;
  readonly selectedAgentId?: string | null;
  /** Verification outcomes for competitive_implementation mode. */
  readonly verifications?: readonly MultiAgentVerificationResult[];
  readonly totalInputTokens: number;
  readonly totalOutputTokens: number;
  readonly summary: string;
}

export class MultiAgentEnsembleError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "MultiAgentEnsembleError";
  }
}

export interface MultiAgentEnsembleInput {
  readonly policy: MultiAgentEnsemblePolicy;
  readonly task: MultiAgentTaskRequest;
  readonly candidates: readonly MultiAgentWorkerDescriptor[];
  /** Required by `synthesize`. Must have independenceKey distinct from all candidates. */
  readonly synthesizer?: MultiAgentWorkerDescriptor;
  /** Required by `compare_and_select`. Must have independenceKey distinct from all candidates. */
  readonly selector?: MultiAgentWorkerDescriptor;
  /** Reviewers used to independently verify candidates in `competitive_implementation`. */
  readonly reviewers?: readonly MultiAgentWorkerDescriptor[];
  /** Workspaces / worktrees per candidate for competitive implementation. */
  readonly candidateWorkspaces?: readonly string[];
}

/**
 * Validates anti-collusion and independence constraints across candidate workers and decision makers.
 */
function validateIndependence(input: MultiAgentEnsembleInput): void {
  const { policy, candidates, synthesizer, selector, reviewers } = input;

  if (candidates.length === 0) {
    throw new MultiAgentEnsembleError(
      "At least one candidate worker is required",
    );
  }

  if (policy.mode === "single" && candidates.length !== 1) {
    throw new MultiAgentEnsembleError(
      "Single mode requires exactly one candidate worker",
    );
  }

  if (policy.mode !== "single" && candidates.length < 2) {
    throw new MultiAgentEnsembleError(
      `${policy.mode} mode requires at least two candidate workers`,
    );
  }

  // Verify all candidates have unique worker IDs and independence keys
  const workerIds = new Set<string>();
  const independenceKeys = new Set<string>();

  for (const candidate of candidates) {
    if (workerIds.has(candidate.workerId)) {
      throw new MultiAgentEnsembleError(
        `Duplicate candidate worker ID '${candidate.workerId}'`,
      );
    }
    if (independenceKeys.has(candidate.independenceKey)) {
      throw new MultiAgentEnsembleError(
        `Collusion risk: candidate workers share independence key '${candidate.independenceKey}'`,
      );
    }
    workerIds.add(candidate.workerId);
    independenceKeys.add(candidate.independenceKey);
  }

  // Validate synthesizer independence
  if (policy.mode === "synthesize") {
    if (!synthesizer) {
      throw new MultiAgentEnsembleError(
        "Synthesizer worker is required for synthesize mode",
      );
    }
    if (independenceKeys.has(synthesizer.independenceKey)) {
      throw new MultiAgentEnsembleError(
        `Collusion risk: synthesizer shares independence key '${synthesizer.independenceKey}' with a candidate`,
      );
    }
  }

  // Validate selector independence
  if (policy.mode === "compare_and_select") {
    if (!selector) {
      throw new MultiAgentEnsembleError(
        "Selector worker is required for compare_and_select mode",
      );
    }
    if (independenceKeys.has(selector.independenceKey)) {
      throw new MultiAgentEnsembleError(
        `Collusion risk: selector shares independence key '${selector.independenceKey}' with a candidate`,
      );
    }
  }

  // Validate competitive implementation reviewers
  if (policy.mode === "competitive_implementation") {
    if (!reviewers || reviewers.length === 0) {
      throw new MultiAgentEnsembleError(
        "At least one independent reviewer is required for competitive_implementation mode",
      );
    }
    for (const reviewer of reviewers) {
      if (independenceKeys.has(reviewer.independenceKey)) {
        throw new MultiAgentEnsembleError(
          `Collusion risk: reviewer shares independence key '${reviewer.independenceKey}' with a candidate`,
        );
      }
    }
  }
}

/**
 * Runs candidate tasks in parallel across disparate machines/agents, bounded by maxParallel.
 */
async function runMultiAgentCandidates(
  candidates: readonly MultiAgentWorkerDescriptor[],
  task: MultiAgentTaskRequest,
  maxParallel?: number,
  candidateWorkspaces?: readonly string[],
): Promise<MultiAgentCandidateResult[]> {
  const results: MultiAgentCandidateResult[] = [];
  const limit =
    maxParallel && maxParallel > 0 ? maxParallel : candidates.length;

  for (let offset = 0; offset < candidates.length; offset += limit) {
    const batch = candidates.slice(offset, offset + limit);
    const batchResults = await Promise.all(
      batch.map(async (candidate, batchIdx) => {
        const globalIdx = offset + batchIdx;
        const workspaceId = candidateWorkspaces?.[globalIdx];
        const candidateTask: MultiAgentTaskRequest = {
          ...task,
          taskId: `${task.taskId}:candidate:${candidate.workerId}`,
          input: {
            ...(task.input || {}),
            ...(workspaceId ? { workspaceRepositoryId: workspaceId } : {}),
            candidateWorkerId: candidate.workerId,
            candidateAgentId: candidate.agentId,
          },
        };

        const startTime = Date.now();
        let execResult: MultiAgentCandidateExecutionResult;
        try {
          execResult = await candidate.execute(candidateTask);
        } catch (err) {
          execResult = {
            status: "failed",
            output: null,
            error: {
              code: "CANDIDATE_EXECUTION_EXCEPTION",
              message: err instanceof Error ? err.message : String(err),
              retryable: false,
            },
            executionTimeMs: Date.now() - startTime,
          };
        }

        return {
          workerId: candidate.workerId,
          agentId: candidate.agentId,
          pluginId: candidate.pluginId,
          name: candidate.name,
          independenceKey: candidate.independenceKey,
          workspaceRepositoryId: workspaceId,
          result: {
            ...execResult,
            executionTimeMs:
              execResult.executionTimeMs ?? Date.now() - startTime,
          },
        };
      }),
    );
    results.push(...batchResults);
  }

  return results;
}

/**
 * Executes a multi-agent / multi-worker ensemble across heterogeneous machines.
 */
export async function executeMultiAgentEnsemble(
  input: MultiAgentEnsembleInput,
): Promise<MultiAgentEnsembleResult> {
  validateIndependence(input);

  const { policy, task, candidates } = input;
  const candidateResults = await runMultiAgentCandidates(
    candidates,
    task,
    policy.maxParallel,
    input.candidateWorkspaces,
  );

  // Compute total token usage
  let totalInputTokens = 0;
  let totalOutputTokens = 0;
  for (const c of candidateResults) {
    totalInputTokens += c.result.usage?.inputTokens || 0;
    totalOutputTokens += c.result.usage?.outputTokens || 0;
  }

  const successfulCandidates = candidateResults.filter(
    (c) => c.result.status === "succeeded",
  );
  const minRequired = policy.minSuccessfulCandidates ?? 1;

  // Single mode
  if (policy.mode === "single") {
    const primary = candidateResults[0]!;
    return {
      mode: "single",
      candidates: candidateResults,
      decisionResult: null,
      decision: null,
      decisionTask: null,
      selectedCandidateIndex: 0,
      selectedWorkerId: primary.workerId,
      selectedAgentId: primary.agentId,
      totalInputTokens,
      totalOutputTokens,
      summary:
        primary.result.status === "succeeded"
          ? `Task executed successfully by worker '${primary.name}' on agent '${primary.agentId}'`
          : `Task failed on worker '${primary.name}' on agent '${primary.agentId}'`,
    };
  }

  // Parallel mode (pure scatter-gather)
  if (policy.mode === "parallel") {
    return {
      mode: "parallel",
      candidates: candidateResults,
      decisionResult: null,
      decision: null,
      decisionTask: null,
      totalInputTokens,
      totalOutputTokens,
      summary: `Completed parallel execution of ${candidateResults.length} candidates across ${
        new Set(candidateResults.map((c) => c.agentId)).size
      } agents (${successfulCandidates.length} succeeded)`,
    };
  }

  // Check minimum successful candidates threshold for synthesis and selection
  if (successfulCandidates.length < minRequired) {
    throw new MultiAgentEnsembleError(
      `Ensemble mode '${policy.mode}' requires at least ${minRequired} successful candidate(s), but only ${successfulCandidates.length} succeeded`,
    );
  }

  // Synthesize mode
  if (policy.mode === "synthesize") {
    const synthesizer = input.synthesizer!;
    const synthesisTaskId = `${task.taskId}:synthesis`;

    const synthesisTaskRequest: MultiAgentTaskRequest = {
      taskId: synthesisTaskId,
      role: "synthesizer",
      objective:
        policy.synthesisPrompt ||
        "Synthesize the findings and solutions produced by all candidate workers across machines into a unified consensus",
      requiredCapabilities: ["synthesis"],
      input: {
        sourceTaskId: task.taskId,
        sourceObjective: task.objective,
        candidates: candidateResults.map((c, idx) => ({
          index: idx,
          workerId: c.workerId,
          agentId: c.agentId,
          pluginId: c.pluginId,
          name: c.name,
          status: c.result.status,
          output: c.result.output,
          findings: c.result.findings,
          error: c.result.error,
        })),
      },
      goalId: task.goalId,
      runId: task.runId,
    };

    const decisionResult = await synthesizer.execute(synthesisTaskRequest);
    totalInputTokens += decisionResult.usage?.inputTokens || 0;
    totalOutputTokens += decisionResult.usage?.outputTokens || 0;

    let decision: DecisionResult | null = null;
    if (decisionResult.status === "succeeded" && decisionResult.output) {
      try {
        decision = DecisionResultSchema.parse(decisionResult.output);
      } catch {
        // Fallback or raw output accepted
      }
    }

    return {
      mode: "synthesize",
      candidates: candidateResults,
      decisionResult,
      decision,
      decisionTask: null,
      totalInputTokens,
      totalOutputTokens,
      summary: `Synthesized consensus from ${candidateResults.length} candidates across ${
        new Set(candidateResults.map((c) => c.agentId)).size
      } agents via synthesizer '${synthesizer.name}' on agent '${synthesizer.agentId}'`,
    };
  }

  // Compare and select mode
  if (policy.mode === "compare_and_select") {
    const selector = input.selector!;
    const selectionTaskId = `${task.taskId}:compare_and_select`;

    const selectionTaskRequest: MultiAgentTaskRequest = {
      taskId: selectionTaskId,
      role: "evaluator",
      objective:
        "Evaluate candidate results across machines against requirements and select the best candidate output",
      requiredCapabilities: ["evaluation"],
      input: {
        sourceTaskId: task.taskId,
        sourceObjective: task.objective,
        evaluationCriteria: policy.evaluationCriteria || [
          "correctness",
          "performance",
          "simplicity",
        ],
        candidates: candidateResults.map((c, idx) => ({
          index: idx,
          workerId: c.workerId,
          agentId: c.agentId,
          pluginId: c.pluginId,
          name: c.name,
          status: c.result.status,
          output: c.result.output,
          findings: c.result.findings,
          executionTimeMs: c.result.executionTimeMs,
        })),
      },
      goalId: task.goalId,
      runId: task.runId,
    };

    const decisionResult = await selector.execute(selectionTaskRequest);
    totalInputTokens += decisionResult.usage?.inputTokens || 0;
    totalOutputTokens += decisionResult.usage?.outputTokens || 0;

    let selectedIdx: number | null = null;
    let decision: DecisionResult | null = null;

    if (decisionResult.status === "succeeded" && decisionResult.output) {
      try {
        decision = DecisionResultSchema.parse(decisionResult.output);
        if (typeof decisionResult.output.selectedCandidateIndex === "number") {
          selectedIdx = decisionResult.output.selectedCandidateIndex;
        }
      } catch {
        if (typeof decisionResult.output.selectedCandidateIndex === "number") {
          selectedIdx = decisionResult.output.selectedCandidateIndex;
        }
      }
    }

    if (
      selectedIdx === null ||
      selectedIdx < 0 ||
      selectedIdx >= candidateResults.length
    ) {
      // Default to first successful candidate if selector did not specify an index
      selectedIdx = candidateResults.findIndex(
        (c) => c.result.status === "succeeded",
      );
      if (selectedIdx === -1) selectedIdx = 0;
    }

    const winner = candidateResults[selectedIdx]!;

    return {
      mode: "compare_and_select",
      candidates: candidateResults,
      decisionResult,
      decision,
      decisionTask: null,
      selectedCandidateIndex: selectedIdx,
      selectedWorkerId: winner.workerId,
      selectedAgentId: winner.agentId,
      totalInputTokens,
      totalOutputTokens,
      summary: `Evaluated ${candidateResults.length} candidates across ${
        new Set(candidateResults.map((c) => c.agentId)).size
      } agents. Winner: '${winner.name}' on agent '${winner.agentId}' (index ${selectedIdx})`,
    };
  }

  // Competitive Implementation mode
  if (policy.mode === "competitive_implementation") {
    const reviewers = input.reviewers || [];
    const verifications: MultiAgentVerificationResult[] = [];

    // Verify each candidate implementation using independent reviewers
    for (const candidate of candidateResults) {
      if (candidate.result.status !== "succeeded") {
        verifications.push({
          candidateWorkerId: candidate.workerId,
          reviewerWorkerId: "none",
          reviewerAgentId: "none",
          passed: false,
          score: 0,
          feedback: "Candidate execution failed prior to verification",
        });
        continue;
      }

      // Pick a reviewer whose independenceKey differs from candidate
      const eligibleReviewer = reviewers.find(
        (r) => r.independenceKey !== candidate.independenceKey,
      );

      if (!eligibleReviewer) {
        throw new MultiAgentEnsembleError(
          `No independent reviewer found for candidate '${candidate.workerId}'`,
        );
      }

      const reviewTask: MultiAgentTaskRequest = {
        taskId: `${task.taskId}:verify:${candidate.workerId}`,
        role: "reviewer",
        objective: `Independently verify implementation from candidate '${candidate.name}'`,
        requiredCapabilities: ["code_review", "testing"],
        input: {
          candidateWorkerId: candidate.workerId,
          candidateAgentId: candidate.agentId,
          workspaceRepositoryId: candidate.workspaceRepositoryId,
          output: candidate.result.output,
          artifacts: candidate.result.artifactIds,
        },
      };

      const reviewRes = await eligibleReviewer.execute(reviewTask);
      totalInputTokens += reviewRes.usage?.inputTokens || 0;
      totalOutputTokens += reviewRes.usage?.outputTokens || 0;

      const passed =
        reviewRes.status === "succeeded" &&
        Boolean(reviewRes.output?.passed ?? true);
      const score = Number(reviewRes.output?.score ?? (passed ? 100 : 0));
      const feedback = String(
        reviewRes.output?.feedback ||
          (passed ? "Verification passed" : "Verification failed"),
      );

      verifications.push({
        candidateWorkerId: candidate.workerId,
        reviewerWorkerId: eligibleReviewer.workerId,
        reviewerAgentId: eligibleReviewer.agentId,
        passed,
        score,
        feedback,
      });
    }

    // Select the best verified candidate with highest score
    let bestIdx = -1;
    let highestScore = -1;

    for (let i = 0; i < candidateResults.length; i++) {
      const v = verifications[i];
      if (v?.passed && v.score > highestScore) {
        highestScore = v.score;
        bestIdx = i;
      }
    }

    if (bestIdx === -1) {
      // If none passed, take first successful or 0
      bestIdx = candidateResults.findIndex(
        (c) => c.result.status === "succeeded",
      );
      if (bestIdx === -1) bestIdx = 0;
    }

    const winningCandidate = candidateResults[bestIdx]!;

    return {
      mode: "competitive_implementation",
      candidates: candidateResults,
      decisionResult: null,
      decision: null,
      decisionTask: null,
      selectedCandidateIndex: bestIdx,
      selectedWorkerId: winningCandidate.workerId,
      selectedAgentId: winningCandidate.agentId,
      verifications,
      totalInputTokens,
      totalOutputTokens,
      summary: `Competitive implementation across ${candidateResults.length} candidates completed. Winner: '${winningCandidate.name}' on agent '${winningCandidate.agentId}' (score: ${highestScore})`,
    };
  }

  throw new MultiAgentEnsembleError(
    `Unsupported ensemble mode '${policy.mode}'`,
  );
}
