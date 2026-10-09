import { expect, it, vi } from "vitest";
import { BUILTIN_WORKFLOWS } from "@conclave/core";
import type { SecurityEnv } from "../src/routes/http-security.js";
const admission = vi.hoisted(() => vi.fn());
vi.mock("../src/routes/handlers.js", () => ({
  validateWorkflowWorkerEligibility: admission,
}));
import {
  parseWorkflowExecutionSelection,
  resolveWorkflowExecutionBindings,
} from "../src/routes/workflow-execution-configuration.js";

it("accepts Auto only for transient model and effort overrides", () => {
  expect(
    parseWorkflowExecutionSelection({
      workerId: "b",
      model: "Auto",
      reasoningEffort: "Auto",
    }),
  ).toEqual({ workerId: "b", model: null, reasoningEffort: null });
  expect(() => parseWorkflowExecutionSelection({ workerId: "Auto" })).toThrow(
    "Worker must be selected explicitly",
  );
  expect(() =>
    parseWorkflowExecutionSelection({ model: "Automatic" }),
  ).toThrow("Use Auto for model and effort defaults");
});

function fixture(
  defaults: object = {},
  stepOverrides: object = {},
  spaceDefaults?: object,
  workspaceId = (defaults as { worker?: string }).worker === "a"
    ? "first"
    : "second",
) {
  const inventory = [
    { workerId: "a", workspaceId: "first" },
    { workerId: "b", workspaceId: "second" },
  ];
  const configuration = {
    schemaVersion: 1,
    workflowId: "implement_verify",
    enabled: true,
    defaults,
    stepOverrides,
  };
  const env = {
    CONCLAVE_DB: {
      prepare(sql: string) {
        return {
          values: [] as unknown[],
          bind(user: string, ...rest: unknown[]) {
            this.values = [user, ...rest];
            if (!sql.includes("workspace_worker_inventory"))
              expect(user).toBe(
                sql.includes("WHERE id = ?1") ||
                  sql.includes("workspace_space_grants") ||
                  sql.includes("FROM spaces WHERE id = ?1") ||
                  sql.includes("space_id = ?1") ||
                  sql.startsWith(
                    "SELECT workspace_id AS workspaceId FROM space_workflow_settings",
                  )
                  ? "space"
                  : "user",
              );
            return this;
          },
          async first() {
            if (sql.includes("space_workflow_settings")) return null;
            if (sql.includes("user_workflow_settings")) return { workspaceId };
            return { ownerUserId: "user" };
          },
          async all() {
            return {
              results: sql.includes("UNION ALL")
                ? [
                    {
                      workflow_id: configuration.workflowId,
                      configuration_json: JSON.stringify(
                        spaceDefaults
                          ? { ...configuration, defaults: spaceDefaults }
                          : configuration,
                      ),
                    },
                  ]
                : inventory.filter((w) => w.workspaceId === this.values[0]),
            };
          },
        };
      },
    },
  } as unknown as SecurityEnv;
  const resolve = (requester = "user", threadId = "thread") =>
    resolveWorkflowExecutionBindings(
      env,
      requester,
      "space",
      threadId,
      BUILTIN_WORKFLOWS.implement_verify,
      {},
      [],
    );
  admission.mockImplementation(
    async (_env, _space, _thread, definition, bindings) => {
      const binding = Object.values(bindings)[0] as { workerId: string };
      const supports =
        binding.workerId === "b" || definition.steps[0].kind === "implement";
      return {
        issues: supports ? [] : [{ message: "Unsupported capability" }],
        primaryWorkspaceId: binding.workerId === "b" ? "second" : "first",
        workerProfiles: {},
      };
    },
  );
  return { configuration, resolve };
}
it("uses the explicitly configured Worker across the whole workflow", async () => {
  const f = fixture(
    { worker: "b", model: "model", effort: "medium" },
    { verify: { effort: "high" } },
  );
  expect(await f.resolve()).toEqual({
    implement: { workerId: "b", model: "model", reasoningEffort: "medium" },
    verify: { workerId: "b", model: "model", reasoningEffort: "high" },
  });
});
it("retains an explicit Worker and fails admission without silently choosing another", async () => {
  const f = fixture({ worker: "a" });
  await expect(f.resolve()).rejects.toMatchObject({
    status: 422,
    message: "Unsupported capability",
  });
});
it("rejects a saved Worker missing from current user ownership", async () => {
  const f = fixture({ worker: "foreign" });
  await expect(f.resolve()).rejects.toMatchObject({ status: 422 });
});
it("rejects disabled workflows before admission", async () => {
  const f = fixture();
  f.configuration.enabled = false;
  admission.mockClear();
  await expect(f.resolve()).rejects.toMatchObject({ status: 422 });
  expect(admission).not.toHaveBeenCalled();
});

it("uses shared Space defaults for every requester and Thread rather than each requester's globals", async () => {
  const f = fixture(
    { model: "global-model" },
    {},
    { worker: "b", model: "space-model", effort: "high" },
  );
  const owner = await f.resolve();
  expect(owner).toEqual({
    implement: { workerId: "b", model: "space-model", reasoningEffort: "high" },
    verify: { workerId: "b", model: "space-model", reasoningEffort: "high" },
  });
  expect(await f.resolve("another-member", "another-thread")).toEqual(owner);
  f.configuration.defaults = { model: "changed-global-model" };
  expect(await f.resolve("another-member", "another-thread")).toEqual(owner);
});

it("requires an explicit Worker and does not fall back to another Workspace", async () => {
  await expect(
    fixture({}, {}, undefined, "first").resolve(),
  ).rejects.toMatchObject({
    status: 422,
    message: expect.stringContaining("Select a Worker"),
  });
  await expect(
    fixture({ worker: "b" }, {}, undefined, "first").resolve(),
  ).rejects.toMatchObject({ status: 422 });
});
