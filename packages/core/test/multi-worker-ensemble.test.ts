import { describe, expect, it } from "vitest";
import {
  executeMultiWorkerEnsemble,
  MultiWorkerEnsembleError,
  type MultiWorkerWorkerDescriptor,
  type MultiWorkerTaskRequest,
} from "../src/index.js";

describe("Multi-Worker Ensemble Engine (V4-12)", () => {
  // Setup 3 candidate workers across disparate physical machines/hosts:
  // 1. Worker A: Claude on MacBook
  const macbookClaudeWorker: MultiWorkerWorkerDescriptor = {
    workerId: "worker-claude-macbook",
    hostId: "Host-macbook-pro",
    workerPackageId: "conclave.claude-code",
    name: "Claude on MacBook",
    role: "architect",
    capabilities: ["architecture", "code_review"],
    independenceKey: "indep-claude-mac",
    execute: async () => ({
      status: "succeeded",
      output: {
        architecture: "Event-driven CQRS with SQLite persistence",
        latency: "12ms",
        strengths: ["low latency", "local first"],
      },
      usage: { inputTokens: 500, outputTokens: 200, totalTokens: 700 },
      artifactIds: ["art-arch-claude"],
    }),
  };

  // 2. Worker B: GPT on Linux server
  const linuxGptWorker: MultiWorkerWorkerDescriptor = {
    workerId: "worker-gpt-linux",
    hostId: "Host-linux-server-prod",
    workerPackageId: "conclave.openai-api",
    name: "GPT on Linux Server",
    role: "architect",
    capabilities: ["architecture", "code_review"],
    independenceKey: "indep-gpt-linux",
    execute: async () => ({
      status: "succeeded",
      output: {
        architecture: "Microservices with distributed transactional outbox",
        latency: "45ms",
        strengths: ["high scale", "horizontal partitioning"],
      },
      usage: { inputTokens: 600, outputTokens: 250, totalTokens: 850 },
      artifactIds: ["art-arch-gpt"],
    }),
  };

  // 3. Worker C: Web Worker (remote browser client)
  const webWorker: MultiWorkerWorkerDescriptor = {
    workerId: "worker-chatgpt-web",
    hostId: "Host-web-client-1",
    workerPackageId: "conclave.echo-worker",
    name: "ChatGPT Web Worker",
    role: "architect",
    capabilities: ["architecture"],
    independenceKey: "indep-web-worker",
    execute: async () => ({
      status: "succeeded",
      output: {
        architecture: "Serverless Edge Worker with KV cache",
        latency: "20ms",
        strengths: ["zero cold start", "edge localization"],
      },
      usage: { inputTokens: 400, outputTokens: 150, totalTokens: 550 },
      artifactIds: ["art-arch-web"],
    }),
  };

  // Synthesizer worker on host Host
  const synthesizerWorker: MultiWorkerWorkerDescriptor = {
    workerId: "worker-synthesizer-cloud",
    hostId: "Host-cloud-host",
    workerPackageId: "conclave.openai-api",
    name: "Consensus Synthesizer",
    role: "synthesizer",
    capabilities: ["synthesis"],
    independenceKey: "indep-synthesizer",
    execute: async () => ({
      status: "succeeded",
      output: {
        consensusArchitecture:
          "Hybrid Edge-local CQRS with transactional outbox",
        rationale:
          "Combines low latency of Claude with horizontal scaling of GPT",
      },
      usage: { inputTokens: 1200, outputTokens: 300, totalTokens: 1500 },
      artifactIds: ["art-final-consensus"],
    }),
  };

  // Selector / Evaluator worker
  const evaluatorWorker: MultiWorkerWorkerDescriptor = {
    workerId: "worker-evaluator-cloud",
    hostId: "Host-cloud-host",
    workerPackageId: "conclave.anthropic-api",
    name: "Lead Architecture Evaluator",
    role: "evaluator",
    capabilities: ["evaluation"],
    independenceKey: "indep-evaluator",
    execute: async () => ({
      status: "succeeded",
      output: {
        selectedCandidateIndex: 0,
        score: 95,
        rationale:
          "Claude on MacBook design provides the lowest latency and cleanest state boundaries",
      },
      usage: { inputTokens: 1000, outputTokens: 200, totalTokens: 1200 },
    }),
  };

  // Independent reviewer for competitive implementation
  const independentReviewer: MultiWorkerWorkerDescriptor = {
    workerId: "worker-qa-reviewer",
    hostId: "Host-qa-ci-runner",
    workerPackageId: "conclave.claude-code",
    name: "QA CI Reviewer",
    role: "reviewer",
    capabilities: ["code_review", "testing"],
    independenceKey: "indep-qa-reviewer",
    execute: async (task: MultiWorkerTaskRequest) => {
      const candidateWorkerId = task.input?.candidateWorkerId;
      if (candidateWorkerId === "worker-claude-macbook") {
        return {
          status: "succeeded",
          output: {
            passed: true,
            score: 98,
            feedback: "All tests pass, zero lint issues",
          },
          usage: { inputTokens: 300, outputTokens: 50 },
        };
      }
      return {
        status: "succeeded",
        output: {
          passed: true,
          score: 85,
          feedback: "Tests pass with minor warnings",
        },
        usage: { inputTokens: 300, outputTokens: 50 },
      };
    },
  };

  const sampleTask: MultiWorkerTaskRequest = {
    taskId: "task-arch-design",
    role: "architect",
    objective: "Design distributed messaging layer for Conclave AX",
    goalId: "goal-1",
    runId: "run-1",
  };

  it("rejects invalid execution limits before dispatching workers", async () => {
    await expect(
      executeMultiWorkerEnsemble({
        policy: { mode: "parallel", maxParallel: 0 },
        task: sampleTask,
        candidates: [macbookClaudeWorker, linuxGptWorker],
      }),
    ).rejects.toThrow("maxParallel must be a positive integer");

    await expect(
      executeMultiWorkerEnsemble({
        policy: {
          mode: "parallel",
          timeoutMs: -1,
          maxEstimatedCostMicrosPerAttempt: -1,
        },
        task: sampleTask,
        candidates: [macbookClaudeWorker, linuxGptWorker],
      }),
    ).rejects.toThrow("timeoutMs must be positive");

    await expect(
      executeMultiWorkerEnsemble({
        policy: {
          mode: "parallel",
          minSuccessfulCandidates: 0,
        },
        task: sampleTask,
        candidates: [macbookClaudeWorker, linuxGptWorker],
      }),
    ).rejects.toThrow("minSuccessfulCandidates must be a positive integer");
  });

  it("coordinates parallel execution across 3 disparate machines (MacBook, Linux, Web)", async () => {
    const result = await executeMultiWorkerEnsemble({
      policy: { mode: "parallel" },
      task: sampleTask,
      candidates: [macbookClaudeWorker, linuxGptWorker, webWorker],
    });

    expect(result.mode).toBe("parallel");
    expect(result.candidates).toHaveLength(3);

    // Verify candidates are on 3 distinct physical hosts
    const hostIds = result.candidates.map((c) => c.hostId);
    expect(new Set(hostIds).size).toBe(3);
    expect(hostIds).toContain("Host-macbook-pro");
    expect(hostIds).toContain("Host-linux-server-prod");
    expect(hostIds).toContain("Host-web-client-1");

    // Verify total token telemetry
    expect(result.totalInputTokens).toBe(1500); // 500 + 600 + 400
    expect(result.totalOutputTokens).toBe(600); // 200 + 250 + 150
    expect(result.summary).toContain("3 candidates across 3 hosts");
  });

  it("coordinates synthesize mode across 3 machines with independent synthesizer", async () => {
    const result = await executeMultiWorkerEnsemble({
      policy: {
        mode: "synthesize",
        synthesisPrompt: "Create unified hybrid design from all 3 proposals",
      },
      task: sampleTask,
      candidates: [macbookClaudeWorker, linuxGptWorker, webWorker],
      synthesizer: synthesizerWorker,
    });

    expect(result.mode).toBe("synthesize");
    expect(result.candidates).toHaveLength(3);
    expect(result.decisionResult).not.toBeNull();
    expect(result.decisionResult?.output?.consensusArchitecture).toContain(
      "Hybrid Edge-local",
    );
    expect(result.totalInputTokens).toBe(2700); // 1500 + 1200
    expect(result.summary).toContain("Consensus Synthesizer");
  });

  it("coordinates compare_and_select mode picking winner across machines", async () => {
    const result = await executeMultiWorkerEnsemble({
      policy: { mode: "compare_and_select" },
      task: sampleTask,
      candidates: [macbookClaudeWorker, linuxGptWorker, webWorker],
      selector: evaluatorWorker,
    });

    expect(result.mode).toBe("compare_and_select");
    expect(result.selectedCandidateIndex).toBe(0);
    expect(result.selectedWorkerId).toBe("worker-claude-macbook");
    expect(result.selectedHostId).toBe("Host-macbook-pro");
    expect(result.summary).toContain(
      "Winner: 'Claude on MacBook' on Host 'Host-macbook-pro'",
    );
  });

  it("coordinates competitive_implementation mode with independent reviewer verification", async () => {
    const result = await executeMultiWorkerEnsemble({
      policy: { mode: "competitive_implementation" },
      task: sampleTask,
      candidates: [macbookClaudeWorker, linuxGptWorker],
      candidateWorkspaces: ["worktree-macbook-1", "worktree-linux-2"],
      reviewers: [independentReviewer],
    });

    expect(result.mode).toBe("competitive_implementation");
    expect(result.verifications).toHaveLength(2);
    expect(result.verifications?.[0]?.score).toBe(98);
    expect(result.verifications?.[1]?.score).toBe(85);

    // Highest score candidate (index 0) is selected
    expect(result.selectedCandidateIndex).toBe(0);
    expect(result.selectedWorkerId).toBe("worker-claude-macbook");
    expect(result.selectedHostId).toBe("Host-macbook-pro");
  });

  it("strictly prevents collusion when workers share independence keys", async () => {
    // Colluding worker with same independence key as candidate
    const colludingSynthesizer: MultiWorkerWorkerDescriptor = {
      ...synthesizerWorker,
      independenceKey: "indep-claude-mac", // same as macbookClaudeWorker!
    };

    await expect(
      executeMultiWorkerEnsemble({
        policy: { mode: "synthesize" },
        task: sampleTask,
        candidates: [macbookClaudeWorker, linuxGptWorker],
        synthesizer: colludingSynthesizer,
      }),
    ).rejects.toThrowError(MultiWorkerEnsembleError);
  });

  it("accepts the same model in fresh sessions", async () => {
    const first = {
      ...macbookClaudeWorker,
      workerId: "same-worker",
      snapshot: {
        hostId: "host-1",
        workerId: "same-worker",
        credentialProfileId: "cred-1",
        provider: "anthropic",
        model: "claude-sonnet",
        sessionId: "session-1",
      },
    };
    const second = {
      ...first,
      hostId: "host-2",
      snapshot: { ...first.snapshot, hostId: "host-2", sessionId: "session-2" },
    };
    const result = await executeMultiWorkerEnsemble({
      policy: { mode: "parallel", independenceLevels: ["session"] },
      task: sampleTask,
      candidates: [first, second],
    });
    expect(result.candidates[0]?.snapshot?.sessionId).toBe("session-1");
  });

  it("accepts same provider with different models and different providers", async () => {
    const make = (workerId: string, provider: string, model: string) => ({
      ...macbookClaudeWorker,
      workerId,
      hostId: `host-${workerId}`,
      snapshot: {
        hostId: `host-${workerId}`,
        workerId,
        credentialProfileId: `cred-${workerId}`,
        provider,
        model,
        sessionId: `session-${workerId}`,
      },
    });
    const result = await executeMultiWorkerEnsemble({
      policy: { mode: "parallel", independenceLevels: ["model", "provider"] },
      task: sampleTask,
      candidates: [
        make("model-a", "openai", "gpt-5"),
        make("model-b", "openai", "gpt-4.1"),
        make("provider-b", "anthropic", "claude-sonnet"),
      ],
    });
    expect(result.candidates).toHaveLength(3);
  });

  it("does not treat different Hosts as intellectual independence by default", async () => {
    const sameModel = (hostId: string) => ({
      ...macbookClaudeWorker,
      workerId: `worker-${hostId}`,
      hostId,
      snapshot: {
        hostId,
        workerId: `worker-${hostId}`,
        credentialProfileId: "same-credential",
        provider: "openai",
        model: "gpt-5",
        sessionId: "same-session",
      },
    });
    await expect(
      executeMultiWorkerEnsemble({
        policy: { mode: "parallel" },
        task: sampleTask,
        candidates: [sameModel("host-a"), sameModel("host-b")],
      }),
    ).rejects.toThrowError(MultiWorkerEnsembleError);
    const result = await executeMultiWorkerEnsemble({
      policy: { mode: "parallel", independenceLevels: ["host"] },
      task: sampleTask,
      candidates: [sameModel("host-a"), sameModel("host-b")],
    });
    expect(result.candidates).toHaveLength(2);
  });
});
