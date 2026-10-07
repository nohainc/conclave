import { describe, expect, it } from "vitest";
import { projectModelOptions } from "../src/routes/profiles.js";
describe("profile selection projection", () => {
  it("keeps per-model efforts and filters out non-allowlisted entries", () => {
    const result = projectModelOptions(
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
      projectModelOptions(JSON.stringify({ model: { supported: true } }))
        ?.catalog,
    ).toEqual([]);
    expect(projectModelOptions("invalid")).toBeNull();
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
    projectModelOptions(payload, "1.5.0")?.catalog.map((item) => item.id),
  ).toEqual(["old"]);
  expect(
    projectModelOptions(payload, "2.0.0")?.catalog.map((item) => item.id),
  ).toEqual(["new"]);
  expect(projectModelOptions(payload)?.catalog).toEqual([]);
});
