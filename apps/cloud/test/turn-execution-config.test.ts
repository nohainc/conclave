import { expect, it } from "vitest";
import { BUILTIN_WORKFLOWS } from "@conclave/core";
import {
  parseTurnExecutionSelection,
  resolveTurnExecutionConfig,
} from "../src/routes/turn-execution-config.js";
const workflow = BUILTIN_WORKFLOWS.chat;
it("captures explicit Default choices without inheriting saved model or effort", () => {
  const selection = parseTurnExecutionSelection(
    { workerId: "worker-a", modelId: null, effort: null },
    workflow,
  )!;
  expect(
    resolveTurnExecutionConfig(
      workflow,
      selection.workerId,
      { profileId: "profile-a", profileReleaseVersion: 3 },
      selection.modelId,
      selection.effort,
      selection,
    ),
  ).toEqual({
    schemaVersion: 1,
    workerId: "worker-a",
    profileId: "profile-a",
    profileReleaseVersion: 3,
    modelId: null,
    effort: null,
    workflowId: "chat",
    workflowVersion: 1,
  });
});
it("rejects a profile that changed between composer selection and acceptance", () => {
  const selection = parseTurnExecutionSelection(
    { workerId: "worker-a", profileId: "profile-a", profileReleaseVersion: 2 },
    workflow,
  );
  expect(() =>
    resolveTurnExecutionConfig(
      workflow,
      "worker-a",
      { profileId: "profile-a", profileReleaseVersion: 3 },
      null,
      null,
      selection,
    ),
  ).toThrow("Profile changed");
});
it("keeps graph execution separate and rejects malformed selection claims", () => {
  expect(() =>
    parseTurnExecutionSelection(
      { workerId: "worker-a" },
      BUILTIN_WORKFLOWS.implement_verify,
    ),
  ).toThrow("manual");
  for (const input of [
    { workerId: "" },
    { workerId: "a", profileReleaseVersion: "3" },
    { workerId: "a", extra: true },
  ])
    expect(() => parseTurnExecutionSelection(input, workflow)).toThrow();
});
