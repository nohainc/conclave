import { expect, it } from "vitest";
import {
  BUILTIN_WORKFLOW_CATALOG,
  parseUserWorkflowConfiguration,
  resolveUserWorkflowConfiguration,
} from "../src/index.js";
const definition = Object.values(BUILTIN_WORKFLOW_CATALOG).find(
  (d) => d.id === "full_cycle",
)!;
const input = {
  schemaVersion: 1,
  workflowId: definition.id,
  enabled: true,
  defaults: {},
  stepOverrides: {},
};
it("keeps definitions separate, defaults to Auto and overlays steps without mutating preferences", () => {
  const config = parseUserWorkflowConfiguration(definition, {
    ...input,
    defaults: { worker: "offline", model: "m" },
    stepOverrides: { verify: { worker: "reviewer", effort: "high" } },
  });
  const effective = resolveUserWorkflowConfiguration(definition, config);
  expect(effective.definition).toBe(definition);
  expect(effective.steps.verify).toEqual({
    worker: "reviewer",
    model: "m",
    effort: "high",
  });
  expect(config.stepOverrides.verify).toEqual({
    worker: "reviewer",
    effort: "high",
  });
  expect(resolveUserWorkflowConfiguration(definition).enabled).toBe(true);
  expect(resolveUserWorkflowConfiguration(definition).steps.verify).toEqual({});
});
it("normalizes Auto and rejects public contract extensions and invalid step identities", () => {
  expect(
    parseUserWorkflowConfiguration(definition, {
      ...input,
      defaults: { worker: "Auto", model: null },
      stepOverrides: { verify: { effort: "Auto" } },
    }),
  ).toEqual(input);
  for (const extra of [
    { userId: "other" },
    { schemaVersion: 2 },
    { stepOverrides: { unknown: {} } },
    { defaults: { worker: 2 } },
    { workflowId: "chat" },
  ]) {
    expect(() =>
      parseUserWorkflowConfiguration(definition, { ...input, ...extra }),
    ).toThrow();
  }
});
