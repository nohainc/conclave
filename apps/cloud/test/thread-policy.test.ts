import { describe, expect, it } from "vitest";

import {
  eligibilityMessage,
  findUnapprovedThreadWorkerIds,
  inputCapabilityMessage,
  normalizeThreadWorkConfig,
} from "../src/routes/thread-policy.js";

describe("catalog-backed Worker validation messages", () => {
  it("uses the supplied catalog name without deriving names from Worker IDs", () => {
    expect(
      eligibilityMessage(
        "implement",
        "dynamic-test-worker",
        "capability_missing",
        null,
        "Dynamic Test Worker",
      ),
    ).toBe(
      "Implement: Dynamic Test Worker does not have the capability required by this Step.",
    );
    expect(
      inputCapabilityMessage(
        "implement",
        "dynamic-test-worker",
        "image",
        false,
        "Dynamic Test Worker",
      ),
    ).toBe("Implement Dynamic Test Worker does not support image input.");
  });

  it("uses a neutral label when catalog display metadata is unavailable", () => {
    expect(
      eligibilityMessage(
        "implement",
        "dynamic-test-worker",
        "worker_not_ready",
      ),
    ).toBe("Implement: Selected Worker is not Ready.");
    expect(
      inputCapabilityMessage("implement", "dynamic-test-worker", "image"),
    ).toBe("Implement Selected Worker does not support image input.");
  });

  it("ignores blank catalog display metadata and stays Worker-neutral", () => {
    expect(
      eligibilityMessage(
        "implement",
        "dynamic-test-worker",
        "worker_disabled",
        null,
        "   ",
      ),
    ).toBe("Implement: Selected Worker is disabled.");
  });
});

describe("Thread Worker label snapshots", () => {
  it("admits an independent Chat default and binding", () => {
    const normalized = normalizeThreadWorkConfig({
      defaultWorkflowId: "chat",
      bindings: {
        chat: { workerId: "dynamic-chat-worker", model: "chat-model" },
        direct: { workerId: "dynamic-work-worker", model: "work-model" },
      },
    });
    expect(normalized.config.defaultWorkflowId).toBe("chat");
    expect(normalized.config.bindings).toMatchObject({
      chat: { workerId: "dynamic-chat-worker", model: "chat-model" },
      direct: { workerId: "dynamic-work-worker", model: "work-model" },
    });
    expect(normalized.workerIds).toEqual([
      "dynamic-chat-worker",
      "dynamic-work-worker",
    ]);
  });
  it("preserves bounded primary and fallback labels without changing identities", () => {
    const normalized = normalizeThreadWorkConfig({
      defaultWorkflowId: "full_cycle",
      bindings: {
        implement: {
          workerId: "worker-primary",
          workerLabel: {
            displayName: " Claude ",
            workspaceName: " Vitalii's MacBook Pro ",
          },
          fallbackWorkerId: "worker-fallback",
          fallbackWorkerLabel: {
            displayName: "Gemini",
            workspaceName: "Linux workstation",
          },
        },
      },
    });

    expect(normalized.workerIds).toEqual(["worker-primary", "worker-fallback"]);
    expect(normalized.config).toMatchObject({
      bindings: {
        implement: {
          workerId: "worker-primary",
          workerLabel: {
            displayName: "Claude",
            workspaceName: "Vitalii's MacBook Pro",
          },
          fallbackWorkerId: "worker-fallback",
          fallbackWorkerLabel: {
            displayName: "Gemini",
            workspaceName: "Linux workstation",
          },
        },
      },
    });
  });

  it("rejects malformed or unbounded presentation snapshots", () => {
    for (const workerLabel of [
      null,
      { displayName: "Claude", workspaceName: "Mac", extra: "ignored?" },
      { displayName: " ", workspaceName: "Mac" },
      { displayName: "x".repeat(161), workspaceName: "Mac" },
    ]) {
      expect(() =>
        normalizeThreadWorkConfig({
          defaultWorkflowId: "full_cycle",
          bindings: {
            implement: { workerId: "worker-primary", workerLabel },
          },
        }),
      ).toThrow("workConfig workerLabel is invalid");
    }
  });

  it("allows unchanged stale bindings but rejects new unavailable Workers", () => {
    expect(
      findUnapprovedThreadWorkerIds(
        ["worker-current", "worker-retired", "worker-unknown"],
        new Set(["worker-current"]),
        new Set(["worker-retired"]),
      ),
    ).toEqual(["worker-unknown"]);
  });
});

describe("profile reasoning configuration", () => {
  it("preserves effort while omission remains the default", () => {
    const result = normalizeThreadWorkConfig({
      defaultWorkflowId: "chat",
      bindings: {
        chat: { workerId: "worker", reasoningEffort: " high " },
        direct: { workerId: "worker" },
      },
    });
    expect(result.config.bindings).toEqual({
      chat: { workerId: "worker", reasoningEffort: "high" },
      direct: { workerId: "worker" },
    });
  });
  it.each(["", " ", 123, "x".repeat(65)])(
    "rejects malformed effort %s",
    (reasoningEffort) => {
      expect(() =>
        normalizeThreadWorkConfig({
          defaultWorkflowId: "chat",
          bindings: { chat: { workerId: "worker", reasoningEffort } },
        }),
      ).toThrow();
    },
  );
});

it("validates selected effort and models against the selected signed Profile", async () => {
  const { validateWorkflowWorkerEligibility } =
    await import("../src/routes/thread-policy.js");
  const { BUILTIN_WORKFLOWS } = await import("@conclave/core");
  const row = {
    workspaceId: "WS",
    workerTypeId: "generic-worker",
    activationState: "enabled",
    readinessState: "ready",
    executionProfileJson: JSON.stringify({
      session: { supported: true },
      model: {
        supported: true,
        unknownModelPolicy: "profile_allowlist",
        allowlist: ["a", "b"],
        supportedReasoningEfforts: ["brief", "deep"],
        catalog: [
          { id: "a", name: "A", supportedReasoningEfforts: ["deep"] },
          { id: "b", name: "B", supportedReasoningEfforts: [] },
        ],
      },
    }),
  };
  const db = { prepare: () => ({ bind: () => ({ first: async () => row }) }) };
  const env = {
    CONCLAVE_DB: db,
  } as unknown as import("../src/routes/http-security.js").SecurityEnv;
  for (const [model, effort, invalid] of [
    ["a", "deep", false],
    ["a", "brief", true],
    ["b", "deep", true],
    ["other", null, true],
  ] as const) {
    const result = await validateWorkflowWorkerEligibility(
      env,
      "P",
      "W",
      BUILTIN_WORKFLOWS.chat,
      {
        chat: {
          workerId: "worker",
          model,
          ...(effort ? { reasoningEffort: effort } : {}),
        },
      },
    );
    expect(
      result.issues.some(
        (issue) => issue.code === "profile_execution_option_unavailable",
      ),
    ).toBe(invalid);
  }
});
