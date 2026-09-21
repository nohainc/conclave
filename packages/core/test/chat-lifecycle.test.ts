import { describe, expect, it } from "vitest";
import {
  assembleChatContext,
  decideChatIntent,
  recommendChatIntent,
} from "../src/chat-lifecycle.js";

describe("chat lifecycle", () => {
  it("permits a first actionable message as a new Goal", () => {
    const proposal = recommendChatIntent("Fix the authentication bug", {
      goals: [],
    });
    expect(decideChatIntent(proposal, { goals: [] })).toMatchObject({
      accepted: true,
      kind: "new_goal",
    });
  });

  it("allows approval only for a waiting Goal awaiting input", () => {
    const state = {
      goals: [
        { id: "goal-1", status: "waiting" as const, awaitingUserInput: true },
      ],
    };
    expect(
      decideChatIntent({ kind: "approval", targetGoalId: "goal-1" }, state)
        .accepted,
    ).toBe(true);
    expect(
      decideChatIntent({ kind: "approval", targetGoalId: "goal-2" }, state)
        .accepted,
    ).toBe(false);
  });

  it("allows follow-up Goals only from completed work", () => {
    expect(
      decideChatIntent(
        { kind: "follow_up_goal", targetGoalId: "goal-1" },
        { goals: [{ id: "goal-1", status: "completed" }] },
      ).accepted,
    ).toBe(true);
    expect(
      decideChatIntent(
        { kind: "follow_up_goal", targetGoalId: "goal-1" },
        { goals: [{ id: "goal-1", status: "running" }] },
      ).accepted,
    ).toBe(false);
  });

  it("assembles bounded selected context without transcript history", () => {
    const context = assembleChatContext(
      {
        currentMessage: "Implement option B",
        acceptedDecisions: [
          {
            id: "decision-1",
            kind: "accepted_decision",
            content: "Use option B",
          },
        ],
        relevantArtifacts: [
          { id: "artifact-1", kind: "relevant_artifact", content: "diff" },
        ],
        explicitReferences: [
          {
            id: "artifact-1",
            kind: "explicit_reference",
            content: "duplicate",
          },
        ],
      },
      { maxItems: 3, maxChars: 100 },
    );
    expect(context.map((item) => item.id)).toEqual([
      "current-message",
      "decision-1",
      "artifact-1",
    ]);
    expect(
      context.some((item) => item.content.includes("old transcript")),
    ).toBe(false);
  });
});
