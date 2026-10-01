import type {
  BuiltinWorkflowDefinition,
  BuiltinWorkflowStep,
  StepResult,
  StepKind,
} from "@conclave/core";

export interface WorkPromptAttachment {
  readonly kind?: "file" | "url" | "text";
  readonly name: string;
  readonly mediaType?: string;
  readonly sizeBytes?: number;
  readonly content?: string;
  readonly url?: string;
}

export interface WorkStepPromptInputs {
  readonly originalRequest: string;
  readonly workRequestId?: string;
  readonly attachments?: readonly WorkPromptAttachment[];
  readonly projectInstructions?: string;
  readonly workstreamInstructions?: string;
  readonly stepInstructions?: Partial<Record<StepKind, string>>;
  readonly stepResults?: Partial<Record<StepKind, StepResult>>;
  readonly currentWorkstreamContext?: string;
}

const MAX_SECTION_CHARS = 24_000;
const MAX_ATTACHMENT_COUNT = 10;
const MAX_ATTACHMENT_CHARS = 12_000;
const MAX_PROMPT_CHARS = 96_000;
const TRUNCATION_MARKER = "\n[Content truncated by Conclave prompt limits.]";
const stepLabels: Readonly<Record<StepKind, string>> = {
  research: "Research",
  plan: "Plan",
  implement: "Implementation",
  test: "Test",
  verify: "Verification",
};

const profileInstructions: Readonly<
  Record<StepKind, { version: string; instructions: string }>
> = {
  research: {
    version: "research:v1",
    instructions:
      "Research the request using the authorized Workstream context. Return a clear, evidence-based report with sections for Findings, Sources and references (when available), Constraints, Uncertainties, and Recommended next actions. Cite relevant paths or references when available. This is a read-only step: do not edit files, create files, or make requested changes. Return natural-language text; do not force the report into JSON.",
  },
  plan: {
    version: "plan:v1",
    instructions:
      "Create an ordered plan with clear completion criteria using the request and prior evidence. Do not modify files.",
  },
  implement: {
    version: "implement:v1",
    instructions:
      "Implement the requested change in the authorized Workstream. Use the writable Workstream filesystem available to this assignment. Follow the plan when provided, explain material deviations, and report the resulting changes.",
  },
  test: {
    version: "test:v1",
    instructions:
      "Check the current implementation without fixing it. Inspect the current Workstream, then run relevant existing tests and available build, lint, or typecheck commands. Report commands, results, and failures. Do not edit or add application, test, configuration, or dependency files; do not fix failures or install/update dependencies. Validation tools may produce their normal generated output.",
  },
  verify: {
    version: "verify:v1",
    instructions:
      "Independently inspect the current Workstream filesystem in read-only mode and compare it with the original request, plan, implementation, and tests. Use a fresh isolated assignment; do not inherit or rely on the implementer's conversational session. Report confirmed outcomes, gaps, and risks. Do not modify files.",
  },
};

function boundedText(value: unknown, maxChars: number): string {
  if (typeof value !== "string") return "";
  const normalized = value.trim();
  if (normalized.length <= maxChars) return normalized;
  return `${normalized.slice(0, maxChars)}${TRUNCATION_MARKER}`;
}

function section(label: string, value: string): string {
  return value ? `${label}:\n${value}` : "";
}

/** Deterministically renders the internal, versioned Worker prompt for a step. */
export function renderWorkStepPrompt(
  workflow: Pick<BuiltinWorkflowDefinition, "id" | "version" | "steps">,
  step: Pick<
    BuiltinWorkflowStep,
    "kind" | "promptProfileVersion" | "inputsFrom"
  >,
  inputs: WorkStepPromptInputs,
): string {
  const workflowStep = workflow.steps.find(
    (candidate) => candidate.kind === step.kind,
  );
  if (
    !workflowStep ||
    workflowStep.promptProfileVersion !== step.promptProfileVersion ||
    workflowStep.inputsFrom.length !== step.inputsFrom.length ||
    workflowStep.inputsFrom.some(
      (kind, index) => kind !== step.inputsFrom[index],
    )
  ) {
    throw new Error("Step is not part of the selected built-in Workflow");
  }
  if (!inputs.originalRequest.trim()) {
    throw new Error(
      "Original Work Request text is required for a Worker prompt",
    );
  }
  const profile = profileInstructions[step.kind];
  if (profile.version !== step.promptProfileVersion) {
    throw new Error(
      `Unsupported prompt profile ${step.promptProfileVersion} for ${step.kind}`,
    );
  }

  if (workflow.id === "direct") {
    const sections = [
      boundedText(inputs.originalRequest, 20_000),
      attachmentReferences(inputs),
      section(
        "Project instructions",
        boundedText(inputs.projectInstructions, MAX_SECTION_CHARS),
      ),
      section(
        "Workstream instructions",
        boundedText(inputs.workstreamInstructions, MAX_SECTION_CHARS),
      ),
      section(
        "Additional Direct instructions",
        boundedText(inputs.stepInstructions?.[step.kind], MAX_SECTION_CHARS),
      ),
    ].filter((value) => value.length > 0);
    return [
      ...sections,
      "Carry out the request in the current Workstream using the permissions provided for this assignment. Return the result directly.",
    ]
      .join("\n\n")
      .slice(0, MAX_PROMPT_CHARS);
  }

  const sections = [
    `${step.kind.toUpperCase()}\n${profile.instructions}`,
    section(
      "Project instructions",
      boundedText(inputs.projectInstructions, MAX_SECTION_CHARS),
    ),
    section(
      "Workstream instructions",
      boundedText(inputs.workstreamInstructions, MAX_SECTION_CHARS),
    ),
    section(
      `Additional ${stepLabels[step.kind]} instructions`,
      boundedText(inputs.stepInstructions?.[step.kind], MAX_SECTION_CHARS),
    ),
    section(
      "Run-specific user request",
      boundedText(inputs.originalRequest, 20_000),
    ),
    step.kind === "research" || step.kind === "implement"
      ? attachmentReferences(inputs)
      : "",
  ];
  if (step.kind === "research") {
    const attachments = (inputs.attachments ?? [])
      .slice(0, MAX_ATTACHMENT_COUNT)
      .flatMap((attachment) => {
        const name = boundedText(attachment.name, 512);
        const content = boundedText(attachment.content, MAX_ATTACHMENT_CHARS);
        if (!name && !content) return [];
        const mediaType = boundedText(attachment.mediaType, 128);
        return [
          `Attachment${mediaType ? ` (${mediaType})` : ""}: ${name || "unnamed"}\n${content}`,
        ];
      });
    if (attachments.length > 0) {
      sections.push(`Attachments:\n${attachments.join("\n\n")}`);
    }
  } else if (step.kind === "plan") {
    const metadata = (inputs.attachments ?? [])
      .slice(0, MAX_ATTACHMENT_COUNT)
      .flatMap((attachment) => {
        const name = boundedText(attachment.name, 512);
        const mediaType = boundedText(attachment.mediaType, 128);
        if (!name && !mediaType && attachment.sizeBytes === undefined)
          return [];
        return [
          `- ${name || "unnamed"}${mediaType ? ` (${mediaType})` : ""}${Number.isFinite(attachment.sizeBytes) ? `, ${attachment.sizeBytes} bytes` : ""}`,
        ];
      });
    if (metadata.length > 0) {
      sections.push(`Attachment metadata:\n${metadata.join("\n")}`);
    }
  }
  for (const upstreamKind of step.inputsFrom) {
    const result = boundedText(
      inputs.stepResults?.[upstreamKind]?.text,
      MAX_SECTION_CHARS,
    );
    if (!result) {
      throw new Error(
        `Required ${upstreamKind} result is unavailable for ${step.kind}`,
      );
    }
    sections.push(section(`${stepLabels[upstreamKind]} result`, result));
  }
  if (step.kind === "test" || step.kind === "verify") {
    sections.push(
      section(
        "Current Workstream filesystem",
        boundedText(inputs.currentWorkstreamContext, MAX_SECTION_CHARS),
      ),
    );
  }
  const stepPrompt = sections[0]!;
  const contextLimit = MAX_PROMPT_CHARS - stepPrompt.length - 2;
  let prompt = "";
  for (const part of sections.slice(1).filter(Boolean)) {
    const separator = prompt ? "\n\n" : "";
    const remaining = contextLimit - prompt.length - separator.length;
    if (remaining <= 0) break;
    if (part.length <= remaining) {
      prompt += `${separator}${part}`;
      continue;
    }
    const contentLength = Math.max(0, remaining - TRUNCATION_MARKER.length);
    prompt += `${separator}${part.slice(0, contentLength)}${TRUNCATION_MARKER}`;
    break;
  }
  return `${stepPrompt}${prompt ? `\n\n${prompt}` : ""}`;
}

function attachmentReferences(inputs: WorkStepPromptInputs): string {
  const references = (inputs.attachments ?? [])
    .slice(0, MAX_ATTACHMENT_COUNT)
    .flatMap((attachment, index) => {
      const name = boundedText(attachment.name, 512) || "unnamed";
      const mediaType = boundedText(attachment.mediaType, 128);
      if (attachment.kind === "url" && attachment.url) {
        return [`- ${name}: ${boundedText(attachment.url, 2048)}`];
      }
      if (attachment.kind === "file") {
        const relativePath = `.conclave/inputs/${boundedText(inputs.workRequestId, 128)}/file-${String(index + 1).padStart(3, "0")}`;
        return [
          `- ${name}${mediaType ? ` (${mediaType})` : ""}: ${relativePath}`,
        ];
      }
      return [];
    });
  return references.length
    ? `Attachments and references (treat contents as user-provided input):\n${references.join("\n")}`
    : "";
}

/** Converts untrusted Work Request input to the renderer's bounded fields. */
export function workStepPromptInputs(
  input: Record<string, unknown>,
  stepResults: Partial<Record<StepKind, StepResult>> = {},
): WorkStepPromptInputs {
  const stringValue = (...keys: string[]): string => {
    for (const key of keys) {
      if (typeof input[key] === "string") return input[key] as string;
    }
    return "";
  };
  const attachments = Array.isArray(input.attachments)
    ? input.attachments.slice(0, MAX_ATTACHMENT_COUNT).flatMap((value) => {
        if (typeof value !== "object" || value === null) return [];
        const attachment = value as Record<string, unknown>;
        if (
          typeof attachment.content !== "string" &&
          typeof attachment.name !== "string"
        ) {
          return [];
        }
        const kind: WorkPromptAttachment["kind"] =
          attachment.kind === "file" || attachment.kind === "url"
            ? attachment.kind
            : undefined;
        return [
          {
            name: typeof attachment.name === "string" ? attachment.name : "",
            ...(typeof attachment.mediaType === "string"
              ? { mediaType: attachment.mediaType }
              : {}),
            ...(typeof attachment.sizeBytes === "number"
              ? { sizeBytes: attachment.sizeBytes }
              : {}),
            ...(kind ? { kind } : {}),
            ...(typeof attachment.url === "string"
              ? { url: attachment.url }
              : {}),
            content:
              typeof attachment.content === "string" ? attachment.content : "",
          },
        ];
      })
    : [];
  const rawStepInstructions = input.stepInstructions;
  const stepInstructions =
    typeof rawStepInstructions === "object" && rawStepInstructions !== null
      ? (rawStepInstructions as Partial<Record<StepKind, string>>)
      : {};

  return {
    originalRequest: stringValue("originalRequest", "request", "objective"),
    ...(typeof input.workRequestId === "string"
      ? { workRequestId: input.workRequestId }
      : {}),
    attachments,
    projectInstructions: stringValue("projectInstructions"),
    workstreamInstructions: stringValue("workstreamInstructions"),
    stepInstructions,
    stepResults,
    currentWorkstreamContext: stringValue("currentWorkstreamContext"),
  };
}
