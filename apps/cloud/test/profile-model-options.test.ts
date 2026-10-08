import { describe, expect, it } from "vitest";
import { spaceModelOptions } from "../src/routes/profiles.js";
describe("profile selection projection", () => {
  it("keeps per-model efforts and filters out non-allowlisted entries", () => {
    const result = spaceModelOptions(
      JSON.stringify({
        credential: "never exposed",
        model: {
          supported: true,
          unknownModelPolicy: "profile_allowlist",
          allowlist: ["a", "b"],
          supportedReasoningEfforts: ["low", "high"],
          catalog: [
            { id: "a", name: "A", supportedReasoningEfforts: ["low"] },
            { id: "b", name: "B", supportedReasoningEfforts: [] },
            { id: "c", name: "C" },
          ],
        },
      }),
    );
    expect(result?.catalog.map((item) => item.id)).toEqual(["a", "b"]);
    expect(result?.catalog[0]?.supportedReasoningEfforts).toEqual(["low"]);
    expect(result?.catalog[1]?.supportedReasoningEfforts).toEqual([]);
    expect(result).not.toHaveProperty("credential");
  });
  it("does not invent a catalog for legacy profiles", () => {
    expect(
      spaceModelOptions(JSON.stringify({ model: { supported: true } }))
        ?.catalog,
    ).toEqual([]);
    expect(spaceModelOptions("invalid")).toBeNull();
  });
});

it("filters profile models against the installed CLI version", () => {
  const payload = JSON.stringify({
    model: {
      supported: true,
      catalog: [
        { id: "new", name: "New", minProviderVersion: "2.0.0" },
        { id: "old", name: "Old", maxProviderVersion: "1.9.0" },
      ],
    },
  });
  expect(
    spaceModelOptions(payload, "1.5.0")?.catalog.map((item) => item.id),
  ).toEqual(["old"]);
  expect(
    spaceModelOptions(payload, "2.0.0")?.catalog.map((item) => item.id),
  ).toEqual(["new"]);
  expect(spaceModelOptions(payload)?.catalog).toEqual([]);
});

it("spaces normalized capabilities without provider instructions or fake Defaults", async () => {
  const { spaceWorkerExecutionOptions } =
    await import("../src/worker-execution-options.js");
  const result = spaceWorkerExecutionOptions(
    JSON.stringify({
      session: { supported: true },
      model: {
        supported: true,
        arguments: ["--private-flag"],
        unknownModelPolicy: "profile_allowlist",
        allowlist: ["a", "b"],
        supportedReasoningEfforts: ["brief", "deep"],
        defaultReasoningEffort: "brief",
        executionOptions: {
          schemaVersion: 1,
          discovery: "profile_catalog",
          modelSwitchSupported: false,
          effortSupported: true,
          defaultModelId: "a",
          effortMapping: { deep: "provider-private-value" },
        },
        catalog: [
          { id: "a", name: "A", supportedReasoningEfforts: [] },
          {
            id: "b",
            name: "B",
            supportedReasoningEfforts: ["deep"],
            defaultReasoningEffort: "deep",
          },
        ],
      },
    }),
  );
  expect(result?.schemaVersion).toBe(1);
  expect(result?.modelSwitch.supported).toBe(false);
  expect(result?.models.defaultModelId).toBe("a");
  expect(result?.models.options[0]?.effort).toEqual({
    supported: false,
    values: [],
    defaultValue: null,
  });
  expect(result?.models.options[1]?.effort.defaultValue).toBe("deep");
  expect(JSON.stringify(result)).not.toContain("private");
});
it("supports fixed-model effort and filters unavailable CLI-version models", async () => {
  const { spaceWorkerExecutionOptions } =
    await import("../src/worker-execution-options.js");
  const fixed = spaceWorkerExecutionOptions(
    JSON.stringify({
      model: {
        supported: false,
        supportedReasoningEfforts: ["deep"],
        defaultReasoningEffort: "deep",
      },
    }),
  );
  expect(fixed?.models.supported).toBe(false);
  expect(fixed?.effort.values).toEqual(["deep"]);
  const result = spaceWorkerExecutionOptions(
    JSON.stringify({
      session: { supported: true },
      model: {
        supported: true,
        unknownModelPolicy: "profile_allowlist",
        allowlist: ["new"],
        catalog: [{ id: "new", name: "New", minProviderVersion: "2.0.0" }],
        executionOptions: {
          schemaVersion: 1,
          discovery: "profile_catalog",
          modelSwitchSupported: true,
          effortSupported: false,
          defaultModelId: "new",
        },
      },
    }),
    "1.0.0",
  );
  expect(result?.models.allowedModelIds).toEqual([]);
  expect(result?.models.defaultModelId).toBeNull();
  expect(result?.models.options).toEqual([]);
});
