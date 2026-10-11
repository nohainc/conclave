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

it("validates v2 unavailable models even with custom-model admission", () => {
  const unified: WorkerExecutionOptions = {
    schemaVersion: 2,
    catalogRevision: "a".repeat(64),
    models: {
      ...options.models,
      allowsCustomModel: true,
      options: [
        {
          id: "reasoner",
          name: "Reasoner",
          selectionMode: "separate",
          status: "listed",
          efforts: ["ultra"],
          defaultEffort: "ultra",
        },
        {
          id: "retired",
          name: "Retired",
          selectionMode: "combined",
          status: "unavailable",
          efforts: [],
          defaultEffort: null,
        },
      ],
    },
    modelSwitch: options.modelSwitch,
    effort: options.effort,
  };
  expect(
    validateWorkerExecutionSelection(unified, "reasoner", "ultra"),
  ).toBeNull();
  expect(
    validateWorkerExecutionSelection(unified, "reasoner", "high"),
  ).toContain("effort");
  expect(validateWorkerExecutionSelection(unified, "retired", null)).toContain(
    "not available",
  );
  expect(validateWorkerExecutionSelection(unified, null, null)).toBeNull();
});

it("requires an explicit combined effort when no signed default exists", () => {
  const combined: WorkerExecutionOptions = {
    schemaVersion: 2,
    catalogRevision: "a".repeat(64),
    models: {
      ...options.models,
      defaultModelId: null,
      options: [
        {
          id: "reasoner",
          name: "Family",
          selectionMode: "combined",
          status: "listed",
          efforts: ["low", "high"],
          defaultEffort: null,
        },
      ],
    },
    modelSwitch: options.modelSwitch,
    effort: options.effort,
  };
  expect(
    validateWorkerExecutionSelection(combined, "reasoner", null),
  ).toContain("explicit effort");
  expect(
    validateWorkerExecutionSelection(combined, "reasoner", "low"),
  ).toBeNull();
  expect(validateWorkerExecutionSelection(combined, null, null)).toContain(
    "explicit model",
  );
});

it("rejects stale and changed catalogs without replacing selections", () => {
  const current: WorkerExecutionOptions = {
    ...options,
    schemaVersion: 2,
    catalogRevision: "a".repeat(64),
    models: {
      ...options.models,
      options: [
        {
          id: "reasoner",
          name: "Reasoner",
          selectionMode: "separate",
          status: "verified",
          efforts: ["deep"],
          defaultEffort: "deep",
        },
      ],
    },
  };
  expect(
    validateWorkerExecutionSelection(
      current,
      "reasoner",
      "deep",
      "a".repeat(64),
    ),
  ).toBeNull();
  expect(
    validateWorkerExecutionSelection(
      current,
      "reasoner",
      "deep",
      "b".repeat(64),
    ),
  ).toContain("catalog changed");
  expect(
    validateWorkerExecutionSelection(
      { ...current, catalogStale: true },
      "reasoner",
      "deep",
    ),
  ).toContain("stale");
  expect(
    validateWorkerExecutionSelection(
      {
        ...current,
        models: {
          ...current.models,
          discovery: "provider_catalog",
          options: [],
        },
      },
      null,
      null,
    ),
  ).toContain("unavailable");
});
