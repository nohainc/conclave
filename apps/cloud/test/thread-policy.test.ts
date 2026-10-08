import { describe, expect, it } from "vitest";

import {
  eligibilityMessage,
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

describe("Thread authored context", () => {
  it("normalizes instructions without execution preferences", () => {
    expect(
      normalizeThreadWorkConfig({
        defaultWorkflowId: "chat",
        threadInstructions: " Context ",
        bindings: {
          chat: { additionalInstructions: " Focus " },
          direct: { additionalInstructions: " " },
        },
      }).config,
    ).toEqual({
      defaultWorkflowId: "chat",
      threadInstructions: "Context",
      bindings: { chat: { additionalInstructions: "Focus" } },
    });
  });
  it.each([
    "workerId",
    "workerLabel",
    "model",
    "reasoningEffort",
    "fallbackWorkerId",
    "fallbackWorkerLabel",
  ])("rejects obsolete %s preferences", (key) => {
    expect(() =>
      normalizeThreadWorkConfig({
        defaultWorkflowId: "chat",
        bindings: { chat: { [key]: "old" } },
      }),
    ).toThrow("use Workflows");
  });
  it.each([null, 123, "x".repeat(4001)])(
    "rejects malformed instructions %s",
    (instructions) => {
      expect(() =>
        normalizeThreadWorkConfig({
          defaultWorkflowId: "chat",
          bindings: { chat: { additionalInstructions: instructions } },
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
