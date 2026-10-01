import { describe, expect, it } from "vitest";
import {
  BUILTIN_WORKFLOWS,
  type BuiltinWorkflowDefinition,
} from "@conclave/core";
import { ConclaveRunWorkflow } from "../src/workflow.js";

const requestText = "Improve the sample Workstream behavior";
const workerBindings = {
  direct: { workerId: "worker-direct" },
  research: { workerId: "worker-research" },
  plan: { workerId: "worker-plan" },
  implement: { workerId: "worker-implement" },
  test: { workerId: "worker-test" },
  verify: { workerId: "worker-verify" },
};

function createAcceptanceRun(
  definition: BuiltinWorkflowDefinition,
  options: { cancelAfterFirstStep?: boolean } = {},
) {
  const calls: Record<string, unknown>[] = [];
  const taskWrites: { sql: string; values: unknown[] }[] = [];
  let terminalIndex = 0;
  let cancellationChecks = 0;
  const terminalEvents = definition.steps.map((step, index) => ({
    eventId: `event-${index + 1}`,
    runId: "run-v8-acceptance",
    executionId: "execution-v8-acceptance",
    status: "completed",
    finalText: `completed ${step.kind}`,
    workerId: `workspace-worker-${step.kind}`,
    workerTypeId: "chatgpt",
    engineVersion: "1.0.0-test",
    profileDefinitionId: "chatgpt-codex",
    profileReleaseVersion: 1,
    providerToolVersion: "0.1.0-test",
    model: null,
  }));
  const database = {
    prepare(sql: string) {
      let values: unknown[] = [];
      const statement = {
        bind(...next: unknown[]) {
          values = next;
          return statement;
        },
        async first<T>() {
          if (sql.includes("SELECT wr.input_json")) {
            return {
              inputJson: JSON.stringify({ originalRequest: requestText }),
              snapshotJson: JSON.stringify({
                originalRequest: requestText,
                resolvedBindings: workerBindings,
              }),
            } as T;
          }
          if (sql.includes("SELECT mode FROM work_requests")) {
            return { mode: "stateless" } as T;
          }
          if (sql.includes("cancel_requested_at")) {
            cancellationChecks += 1;
            return {
              cancelRequestedAt:
                options.cancelAfterFirstStep && cancellationChecks > 0
                  ? "2026-10-01T00:00:00.000Z"
                  : null,
            } as T;
          }
          return null;
        },
        async run() {
          taskWrites.push({ sql, values });
          return { success: true };
        },
      };
      return statement;
    },
    async batch() {
      return [];
    },
  } as unknown as D1Database;
  const executionService = {
    async fetch(_input: RequestInfo | URL, init?: RequestInit) {
      calls.push(JSON.parse(String(init?.body)) as Record<string, unknown>);
      return Response.json(
        { executionId: "execution-v8-acceptance" },
        {
          status: 202,
        },
      );
    },
  };
  const instance = new ConclaveRunWorkflow(
    {} as never,
    {
      CONCLAVE_DB: database,
      CONCLAVE_FORGE_EXECUTION: executionService,
    } as never,
  );
  const step = {
    do: async <T>(
      _name: string,
      _config: unknown,
      callback: () => Promise<T>,
    ) => callback(),
    waitForEvent: async <T>() =>
      ({
        payload: terminalEvents[terminalIndex++],
      }) as { payload: T },
  } as unknown as import("cloudflare:workers").WorkflowStep;
  return { instance, step, calls, taskWrites };
}

const workflowCases = Object.values(BUILTIN_WORKFLOWS);

describe("Work v1 regression acceptance over the v8 Worker boundary", () => {
  it.each(workflowCases)(
    "executes the real $name workflow snapshot",
    async (definition) => {
      const { instance, step, calls, taskWrites } =
        createAcceptanceRun(definition);
      const result = await instance.run(
        {
          payload: {
            runId: "run-v8-acceptance",
            goalId: "goal-v8-acceptance",
            idempotencyKey: `key-${definition.id}`,
            requireCiEvidence: false,
            workRequestId: "request-v8-acceptance",
            builtinWorkflow: definition,
          },
        } as never,
        step,
      );

      expect(result.status).toBe("completed");
      expect(calls.map((call) => call.workBindingId)).toEqual(
        definition.steps.map((item) =>
          definition.id === "direct" ? "direct" : item.kind,
        ),
      );
      expect(
        calls.map(
          (call) => (call.workflowStep as Record<string, unknown>).kind,
        ),
      ).toEqual(definition.steps.map((item) => item.kind));
      for (const [index, item] of definition.steps.entries()) {
        const call = calls[index]!;
        const workflowStep = call.workflowStep as Record<string, unknown>;
        expect(workflowStep.readWritePolicy).toBe(
          item.kind === "implement" ? "write_workstream" : "read_only",
        );
        expect(call.workBindingId).not.toContain("codex");
        const prompt = String(call.effectiveWorkerPrompt);
        for (const inputKind of item.inputsFrom) {
          const label =
            inputKind === "implement"
              ? "Implementation"
              : inputKind[0]!.toUpperCase() + inputKind.slice(1);
          expect(prompt).toContain(`${label} result:\ncompleted ${inputKind}`);
        }
        if (item.kind === "verify") {
          expect(prompt).toContain("fresh isolated assignment");
          expect(workflowStep.readWritePolicy).toBe("read_only");
        }
      }
      expect(
        taskWrites.filter(({ sql }) =>
          sql.includes("UPDATE workflow_tasks SET status"),
        ),
      ).toHaveLength(definition.steps.length * 2);
      expect(workerBindings).toEqual(
        expect.objectContaining({
          implement: { workerId: "worker-implement" },
          verify: { workerId: "worker-verify" },
        }),
      );
      for (const binding of Object.values(workerBindings)) {
        expect(binding).toHaveProperty("workerId");
        expect(binding).not.toHaveProperty("profileDefinitionId");
        expect(binding).not.toHaveProperty("engineVersion");
      }
    },
  );

  it("stops downstream steps when cancellation is recorded after a running step", async () => {
    const { instance, step, calls } = createAcceptanceRun(
      BUILTIN_WORKFLOWS.plan_implement,
      { cancelAfterFirstStep: true },
    );
    const result = await instance.run(
      {
        payload: {
          runId: "run-v8-acceptance",
          goalId: "goal-v8-acceptance",
          idempotencyKey: "key-cancel",
          requireCiEvidence: false,
          workRequestId: "request-v8-acceptance",
          builtinWorkflow: BUILTIN_WORKFLOWS.plan_implement,
        },
      } as never,
      step,
    );

    expect(result.status).toBe("cancelled");
    expect(calls.map((call) => call.workBindingId)).toEqual(["plan"]);
  });
});
