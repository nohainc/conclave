import { expect, it } from "vitest";
import {
  validateWorkerExecutionSelection,
  workerEffortOptionsForModel,
  type WorkerExecutionOptions,
} from "../src/index.js";
const options: WorkerExecutionOptions = {
  schemaVersion: 1,
  models: {
    supported: true,
    discovery: "profile_catalog",
    allowsCustomModel: false,
    allowedModelIds: ["reasoner", "fast"],
    defaultModelId: "fast",
    options: [
      {
        id: "reasoner",
        name: "Reasoner",
        effort: {
          supported: true,
          values: ["brief", "deep"],
          defaultValue: "brief",
        },
      },
      {
        id: "fast",
        name: "Fast",
        effort: { supported: false, values: [], defaultValue: null },
      },
    ],
  },
  modelSwitch: { supported: false },
  effort: { supported: true, values: ["normal"], defaultValue: "normal" },
};
it("validates model-specific effort without assuming provider values", () => {
  expect(
    validateWorkerExecutionSelection(options, "reasoner", "deep"),
  ).toBeNull();
  expect(validateWorkerExecutionSelection(options, "reasoner", "high")).toMatch(
    /effort/,
  );
  expect(validateWorkerExecutionSelection(options, "fast", "normal")).toMatch(
    /effort/,
  );
  expect(validateWorkerExecutionSelection(options, "other", null)).toMatch(
    /model/,
  );
  expect(validateWorkerExecutionSelection(options, null, null)).toBeNull();
  expect(workerEffortOptionsForModel(options, null).supported).toBe(false);
});
it("allows pass-through models only when the Profile advertises them", () => {
  expect(
    validateWorkerExecutionSelection(
      { ...options, models: { ...options.models, allowsCustomModel: true } },
      "custom",
      "normal",
    ),
  ).toBeNull();
});
