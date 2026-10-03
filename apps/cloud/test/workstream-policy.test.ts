import { describe, expect, it } from "vitest";

import {
  eligibilityMessage,
  findUnapprovedWorkstreamWorkerIds,
  inputCapabilityMessage,
  normalizeWorkstreamWorkConfig,
} from "../src/routes/workstream-policy.js";

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

describe("Workstream Worker label snapshots", () => {
  it("preserves bounded primary and fallback labels without changing identities", () => {
    const normalized = normalizeWorkstreamWorkConfig({
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
        normalizeWorkstreamWorkConfig({
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
      findUnapprovedWorkstreamWorkerIds(
        ["worker-current", "worker-retired", "worker-unknown"],
        new Set(["worker-current"]),
        new Set(["worker-retired"]),
      ),
    ).toEqual(["worker-unknown"]);
  });
});
