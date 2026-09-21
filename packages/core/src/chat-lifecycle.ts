/**
 * Chat is a human-facing surface. This module keeps its semantic boundary
 * separate from orchestration state: workers may recommend an intent, but
 * only Core may accept a legal transition.
 */

export type ChatIntentKind =
  "conversation" | "new_goal" | "continue_goal" | "approval" | "follow_up_goal";

export type ChatGoalStatus =
  | "draft"
  | "ready"
  | "running"
  | "waiting"
  | "completed"
  | "failed"
  | "cancelled"
  | "superseded";

export interface ChatGoalState {
  readonly id: string;
  readonly status: ChatGoalStatus;
  readonly awaitingUserInput?: boolean;
}

export interface ChatIntentProposal {
  readonly kind: ChatIntentKind;
  readonly confidence?: number;
  readonly targetGoalId?: string | null;
  readonly rationale?: string;
}

export interface ChatIntentDecision {
  readonly accepted: boolean;
  readonly kind: ChatIntentKind;
  readonly targetGoalId: string | null;
  readonly reason: string;
  readonly requiresClarification: boolean;
}

export interface ChatIntentState {
  readonly goals: readonly ChatGoalState[];
}

const intentKinds = new Set<ChatIntentKind>([
  "conversation",
  "new_goal",
  "continue_goal",
  "approval",
  "follow_up_goal",
]);

export function parseChatIntentProposal(input: unknown): ChatIntentProposal {
  if (!input || typeof input !== "object") {
    throw new Error("Chat intent proposal must be an object");
  }
  const value = input as Record<string, unknown>;
  if (
    typeof value.kind !== "string" ||
    !intentKinds.has(value.kind as ChatIntentKind)
  ) {
    throw new Error("Chat intent proposal has an unsupported kind");
  }
  if (
    value.confidence !== undefined &&
    (typeof value.confidence !== "number" ||
      value.confidence < 0 ||
      value.confidence > 1)
  ) {
    throw new Error("Chat intent confidence must be between 0 and 1");
  }
  if (
    value.targetGoalId !== undefined &&
    value.targetGoalId !== null &&
    (typeof value.targetGoalId !== "string" || value.targetGoalId.trim() === "")
  ) {
    throw new Error("Chat intent targetGoalId must be a non-empty string");
  }
  if (value.rationale !== undefined && typeof value.rationale !== "string") {
    throw new Error("Chat intent rationale must be a string");
  }
  return {
    kind: value.kind as ChatIntentKind,
    ...(typeof value.confidence === "number"
      ? { confidence: value.confidence }
      : {}),
    ...(typeof value.targetGoalId === "string"
      ? { targetGoalId: value.targetGoalId }
      : {}),
    ...(typeof value.rationale === "string"
      ? { rationale: value.rationale }
      : {}),
  };
}

function latestGoal(goals: readonly ChatGoalState[]): ChatGoalState | null {
  return goals[0] ?? null;
}

/** A conservative baseline proposal used when no semantic Worker is needed. */
export function recommendChatIntent(
  message: string,
  state: ChatIntentState,
): ChatIntentProposal {
  const text = message.trim();
  const latest = latestGoal(state.goals);
  if (
    /^(approve|approved|yes|拒否|go ahead|continue)\b/i.test(text) &&
    latest?.status === "waiting"
  ) {
    return { kind: "approval", targetGoalId: latest.id, confidence: 0.9 };
  }
  if (
    /\b(why|what|how did|explain|clarify)\b/i.test(text) &&
    !/\b(implement|build|fix|change|create|add|remove|review|research)\b/i.test(
      text,
    )
  ) {
    return { kind: "conversation", confidence: 0.8 };
  }
  if (
    latest?.status === "waiting" &&
    /\b(answer|respond|use|choose|keep|reject)\b/i.test(text)
  ) {
    return { kind: "continue_goal", targetGoalId: latest.id, confidence: 0.75 };
  }
  if (
    latest?.status === "completed" &&
    /\b(now|next|implement|build|apply|ship|follow[- ]?up)\b/i.test(text)
  ) {
    return { kind: "follow_up_goal", targetGoalId: latest.id, confidence: 0.7 };
  }
  if (
    /\b(implement|build|fix|change|create|add|remove|review|research|design|migrate|test)\b/i.test(
      text,
    )
  ) {
    return { kind: "new_goal", confidence: 0.65 };
  }
  return { kind: "conversation", confidence: 0.55 };
}

/** Core-owned transition gate for AI or heuristic intent proposals. */
export function decideChatIntent(
  proposalInput: unknown,
  state: ChatIntentState,
): ChatIntentDecision {
  const proposal = parseChatIntentProposal(proposalInput);
  const target = proposal.targetGoalId
    ? (state.goals.find((goal) => goal.id === proposal.targetGoalId) ?? null)
    : null;

  if (proposal.kind === "conversation" || proposal.kind === "new_goal") {
    return {
      accepted: true,
      kind: proposal.kind,
      targetGoalId: null,
      reason: "Core permits this transition for the current Chat.",
      requiresClarification: false,
    };
  }

  if (!target) {
    return {
      accepted: false,
      kind: proposal.kind,
      targetGoalId: proposal.targetGoalId ?? null,
      reason: "The referenced Goal is not part of this Chat.",
      requiresClarification: true,
    };
  }

  if (proposal.kind === "continue_goal") {
    const accepted = target.status === "waiting";
    return {
      accepted,
      kind: proposal.kind,
      targetGoalId: target.id,
      reason: accepted
        ? "The waiting Goal may receive a continuation."
        : "Only a waiting Goal may be continued by a Chat message.",
      requiresClarification: !accepted,
    };
  }

  if (proposal.kind === "approval") {
    const accepted =
      target.status === "waiting" && target.awaitingUserInput === true;
    return {
      accepted,
      kind: proposal.kind,
      targetGoalId: target.id,
      reason: accepted
        ? "The waiting Goal is explicitly awaiting user input."
        : "Approval is legal only for a Goal waiting for user input.",
      requiresClarification: !accepted,
    };
  }

  const accepted =
    target.status === "completed" || target.status === "superseded";
  return {
    accepted,
    kind: proposal.kind,
    targetGoalId: target.id,
    reason: accepted
      ? "A completed Goal may be used as the basis for a follow-up Goal."
      : "A follow-up Goal must reference a completed or superseded Goal.",
    requiresClarification: !accepted,
  };
}

export type ChatContextKind =
  | "current_message"
  | "accepted_decision"
  | "relevant_artifact"
  | "project_instruction"
  | "explicit_reference";

export interface ChatContextItem {
  readonly id: string;
  readonly kind: ChatContextKind;
  readonly content: string;
  readonly mediaType?: string;
  readonly sourceId?: string;
}

export interface ChatContextLimits {
  readonly maxItems?: number;
  readonly maxChars?: number;
}

/**
 * Assemble bounded task context. Deliberately accepts selected durable inputs,
 * never a transcript, so callers cannot accidentally leak all chat history.
 */
export function assembleChatContext(
  input: {
    readonly currentMessage: string;
    readonly acceptedDecisions?: readonly ChatContextItem[];
    readonly relevantArtifacts?: readonly ChatContextItem[];
    readonly projectInstructions?: readonly ChatContextItem[];
    readonly explicitReferences?: readonly ChatContextItem[];
  },
  limits: ChatContextLimits = {},
): readonly ChatContextItem[] {
  const maxItems = limits.maxItems ?? 16;
  const maxChars = limits.maxChars ?? 48_000;
  const current: ChatContextItem = {
    id: "current-message",
    kind: "current_message",
    content: input.currentMessage,
  };
  const selected = [
    current,
    ...(input.acceptedDecisions ?? []),
    ...(input.relevantArtifacts ?? []),
    ...(input.projectInstructions ?? []),
    ...(input.explicitReferences ?? []),
  ];
  const seen = new Set<string>();
  const result: ChatContextItem[] = [];
  let chars = 0;
  for (const item of selected) {
    if (
      seen.has(item.id) ||
      result.length >= maxItems ||
      chars + item.content.length > maxChars
    )
      continue;
    seen.add(item.id);
    result.push(item);
    chars += item.content.length;
  }
  return result;
}
