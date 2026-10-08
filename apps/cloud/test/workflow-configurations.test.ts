import { expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { handleWorkflowConfigurations } from "../src/routes/workflow-configurations.js";
import type { SecurityEnv } from "../src/routes/http-security.js";
vi.mock("../src/routes/http-security.js", async (original) => ({
  ...(await original<typeof import("../src/routes/http-security.js")>()),
  securityContext: async (request: Request) => {
    const userId = request.headers.get("authorization");
    if (!userId) throw new Error("Unauthenticated");
    return { userId };
  },
}));
const inventory = vi.hoisted(() => ({
  workers: [{ id: "offline", executionOptions: null }] as {
    id: string;
    executionOptions: import("@conclave/core").WorkerExecutionOptions | null;
  }[],
}));
vi.mock("../src/routes/profiles.js", () => ({
  handleListWorkspaceWorkerInventory: async () => Response.json(inventory),
}));
it("persists only user overrides, isolates users, retains offline choices, resets and rejects foreign writes", async () => {
  const { sqlite, db } = sqliteD1();
  try {
    sqlite.exec(
      readFileSync(
        new URL(
          "../migrations-v8/0018_user_workflow_configurations.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    sqlite.exec(
      "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES ('U','u@test','U','now','now'),('V','v@test','V','now','now')",
    );
    const env = { CONCLAVE_DB: db } as SecurityEnv;
    const configuration = {
      schemaVersion: 1,
      workflowId: "chat",
      enabled: false,
      defaults: { worker: "offline" },
      stepOverrides: {},
    };
    const request = (method: string, user = "U", body?: unknown) =>
      new Request("https://cloud.test/api/user/workflow-configurations/chat", {
        method,
        headers: user ? { authorization: user } : {},
        ...(body ? { body: JSON.stringify(body) } : {}),
      });
    await expect(
      handleWorkflowConfigurations(request("GET", ""), env),
    ).rejects.toThrow("Unauthenticated");
    await handleWorkflowConfigurations(
      request("PUT", "U", configuration),
      env,
      "chat",
    );
    expect(
      (
        (await (
          await handleWorkflowConfigurations(request("GET"), env)
        ).json()) as { configurations: unknown[] }
      ).configurations,
    ).toEqual([configuration]);
    expect(
      (
        (await (
          await handleWorkflowConfigurations(request("GET", "V"), env)
        ).json()) as { configurations: unknown[] }
      ).configurations,
    ).toEqual([]);
    await expect(
      handleWorkflowConfigurations(
        request("PUT", "U", {
          ...configuration,
          defaults: { worker: "foreign" },
        }),
        env,
        "chat",
      ),
    ).rejects.toThrow("not owned");
    await expect(
      handleWorkflowConfigurations(
        request("PUT", "U", {
          ...configuration,
          defaults: { worker: "offline", model: "invented" },
        }),
        env,
        "chat",
      ),
    ).rejects.toThrow("capabilities");
    await handleWorkflowConfigurations(
      request("PUT", "U", { ...configuration, enabled: true }),
      env,
      "chat",
    );
    expect(
      sqlite
        .prepare("SELECT count(*) n FROM user_workflow_configurations")
        .get()!.n,
    ).toBe(1);
    await handleWorkflowConfigurations(request("DELETE", "V"), env, "chat");
    expect(
      sqlite
        .prepare("SELECT count(*) n FROM user_workflow_configurations")
        .get()!.n,
    ).toBe(1);
    await handleWorkflowConfigurations(request("DELETE"), env, "chat");
    expect(
      sqlite
        .prepare("SELECT count(*) n FROM user_workflow_configurations")
        .get()!.n,
    ).toBe(0);
    await handleWorkflowConfigurations(
      request("PUT", "U", {
        ...configuration,
        enabled: true,
        defaults: { worker: "Auto" },
      }),
      env,
      "chat",
    );
    expect(
      sqlite
        .prepare("SELECT count(*) n FROM user_workflow_configurations")
        .get()!.n,
    ).toBe(0);
    inventory.workers.push({
      id: "capable",
      executionOptions: {
        schemaVersion: 1,
        models: {
          supported: true,
          discovery: "profile_catalog",
          allowsCustomModel: false,
          allowedModelIds: ["m"],
          defaultModelId: null,
          options: [
            {
              id: "m",
              name: "Model",
              effort: { supported: true, values: ["low"], defaultValue: null },
            },
          ],
        },
        modelSwitch: { supported: true },
        effort: { supported: false, values: [], defaultValue: null },
      },
    });
    const choices = {
      ...configuration,
      defaults: { worker: "capable", model: "m", effort: "low" },
    };
    await handleWorkflowConfigurations(
      request("PUT", "U", choices),
      env,
      "chat",
    );
    await expect(
      handleWorkflowConfigurations(
        request("PUT", "U", {
          ...choices,
          defaults: { ...choices.defaults, effort: "high" },
        }),
        env,
        "chat",
      ),
    ).rejects.toThrow("selected effort");
    await expect(
      handleWorkflowConfigurations(
        request("PUT", "U", {
          ...choices,
          defaults: { ...choices.defaults, model: "invented" },
        }),
        env,
        "chat",
      ),
    ).rejects.toThrow("selected model");
    await handleWorkflowConfigurations(
      request("PUT", "U", {
        ...choices,
        defaults: { model: "m", effort: "low" },
      }),
      env,
      "chat",
    );
    await handleWorkflowConfigurations(
      request("PUT", "U", {
        ...configuration,
        defaults: { worker: "capable", model: "m" },
        stepOverrides: { chat: { effort: "low" } },
      }),
      env,
      "chat",
    );
    inventory.workers.find(
      (worker) => worker.id === "capable",
    )!.executionOptions = null;
    await handleWorkflowConfigurations(
      request("PUT", "U", {
        ...configuration,
        defaults: { worker: "capable", model: "m" },
        stepOverrides: {},
      }),
      env,
      "chat",
    );
    await expect(
      handleWorkflowConfigurations(
        request("PUT", "U", {
          ...configuration,
          defaults: { worker: "capable", model: "invented" },
          stepOverrides: {},
        }),
        env,
        "chat",
      ),
    ).rejects.toThrow("capabilities");
    await handleWorkflowConfigurations(request("DELETE"), env, "chat");
  } finally {
    sqlite.close();
  }
});
