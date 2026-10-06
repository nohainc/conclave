import { describe, expect, it } from "vitest";
import { BUILTIN_WORKFLOWS, type StepKind } from "@conclave/core";
import {
  renderWorkStepPrompt,
  workStepPromptInputs,
} from "../src/workflow-prompts.js";

const stepResult = (text: string) => ({
  text,
  status: "completed" as const,
  startedAt: "2026-01-01T00:00:00.000Z",
  completedAt: "2026-01-01T00:00:01.000Z",
  workerId: "worker-test",
  workerTypeId: "chatgpt",
  engineVersion: "1.0.0",
  profileDefinitionId: "chatgpt-codex",
  profileReleaseVersion: 1,
  providerToolVersion: null,
  model: null,
});

describe("Work v1 prompt profiles", () => {
  it("gives Chat bounded contextual inputs and references without implementation authority", () => {
    const workflow = BUILTIN_WORKFLOWS.chat;
    const prompt = renderWorkStepPrompt(workflow, workflow.steps[0]!, {
      originalRequest: "Please implement **this change**.",
      workRequestId: "request-chat",
      projectInstructions: "Prefer established patterns.",
      workstreamInstructions: "Explain the current architecture.",
      stepInstructions: {
        chat: "Discuss the tradeoffs.",
        implement: "Must not be inherited.",
      },
      attachments: [
        {
          kind: "file",
          name: "notes.md",
          mediaType: "text/markdown",
          content: "Not inlined.",
        },
        { kind: "url", name: "Reference", url: "https://example.com/docs" },
      ],
      stepResults: { implement: stepResult("Must not be inherited.") },
    });
    expect(prompt).toContain(
      "CHAT\nAnswer the user's request conversationally",
    );
    expect(prompt).toContain(
      "Project instructions:\nPrefer established patterns.",
    );
    expect(prompt).toContain(
      "Workstream instructions:\nExplain the current architecture.",
    );
    expect(prompt).toContain(
      "Additional Chat instructions:\nDiscuss the tradeoffs.",
    );
    expect(prompt).toContain(
      "Run-specific user request:\nPlease implement **this change**.",
    );
    expect(prompt).toContain(
      "notes.md (text/markdown): .conclave/inputs/request-chat/file-001",
    );
    expect(prompt).toContain("Reference: https://example.com/docs");
    expect(prompt).not.toContain("Not inlined.");
    expect(prompt).not.toContain("Must not be inherited.");
    for (const restriction of [
      "create files",
      "modify files",
      "delete or rename files",
      "change Git state",
      "install or update dependencies",
      "perform implementation work",
    ]) {
      expect(prompt).toContain(`Do not ${restriction}.`);
    }
    expect(prompt).toContain("use Work mode");
    expect(prompt).toContain("Markdown where useful");
  });

  it("bounds oversized Chat inputs while retaining the read-only profile", () => {
    const workflow = BUILTIN_WORKFLOWS.chat;
    const oversized = "x".repeat(200000) + "UNBOUNDED_TAIL";
    const prompt = renderWorkStepPrompt(workflow, workflow.steps[0]!, {
      originalRequest: oversized,
      projectInstructions: oversized,
      workstreamInstructions: oversized,
      stepInstructions: { chat: oversized },
      attachments: Array.from({ length: 20 }, () => ({
        kind: "url" as const,
        name: oversized,
        url: oversized,
      })),
    });
    expect(prompt.length).toBeLessThanOrEqual(96000);
    expect(prompt).toContain("Content truncated by Conclave prompt limits.");
    expect(prompt).not.toContain("UNBOUNDED_TAIL");
    expect(prompt).toContain("Do not change Git state.");
    expect(prompt).toContain("use Work mode");
  });
  it("gives Research request text and attachment contents only", () => {
    const workflow = BUILTIN_WORKFLOWS.full_cycle;
    const prompt = renderWorkStepPrompt(workflow, workflow.steps[0]!, {
      originalRequest: "Investigate login redirect",
      attachments: [
        { name: "trace.txt", mediaType: "text/plain", content: "trace body" },
      ],
      projectInstructions: "Use established router patterns.",
      workstreamInstructions: "Keep the change small.",
      stepInstructions: { research: "Check the callback path." },
      stepResults: { verify: stepResult("Must not be inherited.") },
      currentWorkstreamContext: "Must not be inherited.",
    });

    expect(prompt).toContain(
      "Run-specific user request:\nInvestigate login redirect",
    );
    expect(prompt).toContain("Attachment (text/plain): trace.txt\ntrace body");
    expect(prompt).toContain("Project instructions:");
    expect(prompt).toContain("Workstream instructions:");
    expect(prompt).toContain("Additional Research instructions:");
    expect(prompt).not.toContain("Must not be inherited");
  });

  it("gives Plan attachment metadata and Research result, without contents", () => {
    const workflow = BUILTIN_WORKFLOWS.full_cycle;
    const prompt = renderWorkStepPrompt(workflow, workflow.steps[1]!, {
      originalRequest: "Investigate login redirect",
      attachments: [
        {
          name: "trace.txt",
          mediaType: "text/plain",
          sizeBytes: 123,
          content: "private attachment body",
        },
      ],
      projectInstructions: "Project policy",
      workstreamInstructions: "Workstream policy",
      stepInstructions: { plan: "Include callback coverage." },
      stepResults: {
        research: stepResult("Redirect loop starts after callback."),
        implement: stepResult("Must not be inherited."),
      },
      currentWorkstreamContext: "Must not be inherited.",
    });

    expect(prompt).toContain("Attachment metadata:");
    expect(prompt).toContain("trace.txt (text/plain), 123 bytes");
    expect(prompt).not.toContain("private attachment body");
    expect(prompt).toContain(
      "Research result:\nRedirect loop starts after callback.",
    );
    expect(prompt).not.toContain("Must not be inherited");
  });

  it("gives Implement only relevant research and plan results", () => {
    const workflow = BUILTIN_WORKFLOWS.full_cycle;
    const prompt = renderWorkStepPrompt(workflow, workflow.steps[2]!, {
      originalRequest: "Fix login redirect",
      attachments: [{ name: "trace.txt", content: "Must not be inherited." }],
      projectInstructions: "Use the shared router.",
      workstreamInstructions: "Preserve existing behavior.",
      stepInstructions: { implement: "Add a regression fix." },
      stepResults: {
        research: stepResult("Callback state is lost."),
        plan: stepResult("Preserve callback state."),
        test: stepResult("Must not be inherited."),
      },
      currentWorkstreamContext: "Must not be inherited.",
    });

    expect(prompt).toContain("Research result:\nCallback state is lost.");
    expect(prompt).toContain("Plan result:\nPreserve callback state.");
    expect(prompt).toContain("Use the writable Workstream filesystem");
    expect(prompt).not.toContain("Attachment:");
    expect(prompt).not.toContain("Must not be inherited");
  });

  it("gives Test Plan and Implementation results plus current filesystem", () => {
    const workflow = BUILTIN_WORKFLOWS.full_cycle;
    const prompt = renderWorkStepPrompt(workflow, workflow.steps[3]!, {
      originalRequest: "Fix login redirect",
      attachments: [{ name: "trace.txt", content: "Must not be inherited." }],
      projectInstructions: "Project policy",
      workstreamInstructions: "Workstream policy",
      stepInstructions: { test: "Run callback regression tests." },
      stepResults: {
        research: stepResult("Must not be inherited."),
        plan: stepResult("Preserve callback state."),
        implement: stepResult("Updated callback persistence."),
      },
      currentWorkstreamContext: "Working tree contains the implementation.",
    });

    expect(prompt).toContain("Plan result:\nPreserve callback state.");
    expect(prompt).toContain(
      "Implementation result:\nUpdated callback persistence.",
    );
    expect(prompt).toContain("Current Workstream filesystem:");
    expect(prompt).toContain("Working tree contains the implementation.");
    expect(prompt).not.toContain("Must not be inherited");
    expect(prompt).not.toContain("Attachment:");
  });

  it("gives Verify relevant results and filesystem without session history", () => {
    const workflow = BUILTIN_WORKFLOWS.full_cycle;
    const prompt = renderWorkStepPrompt(workflow, workflow.steps[4]!, {
      originalRequest: "Fix login redirect",
      attachments: [{ name: "trace.txt", content: "Must not be inherited." }],
      projectInstructions: "Project policy",
      workstreamInstructions: "Workstream policy",
      stepInstructions: { verify: "Check callback state." },
      stepResults: {
        research: stepResult("Callback state was dropped."),
        plan: stepResult("Preserve callback state."),
        implement: stepResult("Updated callback persistence."),
        test: stepResult("Callback regression test passes."),
        verify: stepResult("Must not be inherited."),
      },
      currentWorkstreamContext: "Current files include the regression test.",
    });

    expect(prompt).toContain("Research result:");
    expect(prompt).toContain("Plan result:");
    expect(prompt).toContain("Implementation result:");
    expect(prompt).toContain("Test result:");
    expect(prompt).toContain("Current Workstream filesystem:");
    expect(prompt).toContain("fresh isolated assignment");
    expect(prompt).not.toContain("Must not be inherited");
  });

  it("omits Research and Plan from Verify when that Workflow has neither", () => {
    const workflow = BUILTIN_WORKFLOWS.implement_verify;
    const prompt = renderWorkStepPrompt(workflow, workflow.steps[1]!, {
      originalRequest: "Implement then verify",
      stepResults: {
        research: stepResult("Not part of this Workflow."),
        plan: stepResult("Not part of this Workflow."),
        implement: stepResult("Implementation result."),
      },
      currentWorkstreamContext: "Current files.",
    });
    expect(prompt).toContain("Implementation result:");
    expect(prompt).not.toContain("Research result:");
    expect(prompt).not.toContain("Plan result:");
  });

  it("fails closed when a declared upstream result is unavailable", () => {
    const workflow = BUILTIN_WORKFLOWS.plan_implement;
    expect(() =>
      renderWorkStepPrompt(workflow, workflow.steps[1]!, {
        originalRequest: "Implement the plan",
      }),
    ).toThrow(/Required plan result is unavailable/);
  });

  it("uses the catalog profile for each StepKind", () => {
    const profileByKind: Record<StepKind, string> = {
      chat: "chat:v1",
      research: "research:v1",
      plan: "plan:v1",
      implement: "implement:v1",
      test: "test:v1",
      verify: "verify:v1",
    };
    for (const [kind, profile] of Object.entries(profileByKind)) {
      const workflow = Object.values(BUILTIN_WORKFLOWS).find((definition) =>
        definition.steps.some((candidate) => candidate.kind === kind),
      )!;
      const step = workflow.steps.find((candidate) => candidate.kind === kind)!;
      expect(step.promptProfileVersion).toBe(profile);
      expect(() =>
        renderWorkStepPrompt(workflow, step, {
          originalRequest: "Do the work.",
          stepResults: Object.fromEntries(
            step.inputsFrom.map((inputKind) => [
              inputKind,
              stepResult(`${inputKind} evidence`),
            ]),
          ),
          currentWorkstreamContext: "Current Workstream files.",
        }),
      ).not.toThrow();
    }
  });

  it("parses structured request input and bounds rendered text", () => {
    const inputs = workStepPromptInputs(
      {
        originalRequest: "Implement this",
        projectInstructions: "Use Dart",
        attachments: [{ name: "notes", sizeBytes: 32 }],
      },
      { research: stepResult("Found one issue") },
    );
    expect(inputs.originalRequest).toBe("Implement this");
    expect(inputs.projectInstructions).toBe("Use Dart");
    expect(inputs.attachments).toHaveLength(1);
    expect(inputs.stepResults?.research?.text).toBe("Found one issue");

    const workflow = BUILTIN_WORKFLOWS.full_cycle;
    const prompt = renderWorkStepPrompt(workflow, workflow.steps[0]!, {
      originalRequest: "x".repeat(200_000),
    });
    expect(prompt.length).toBeLessThanOrEqual(96_000);
    expect(prompt).toContain("Content truncated by Conclave prompt limits");
  });

  it("rejects a prompt profile version not admitted by the catalog", () => {
    const workflow = BUILTIN_WORKFLOWS.direct;
    const step = { ...workflow.steps[0]!, promptProfileVersion: "custom" };
    expect(() =>
      renderWorkStepPrompt({ ...workflow, steps: [step] }, step, {
        originalRequest: "Do the work.",
      }),
    ).toThrow(/Unsupported prompt profile/);
  });
});
