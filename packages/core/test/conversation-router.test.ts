import { describe, expect, it } from "vitest";
import {
  CONVERSATION_WORKFLOWS,
  routeConversation,
  type ConversationRouteRequest,
  type RoutableWorkerSession,
} from "../src/index.js";

const session: RoutableWorkerSession = {
  id: "session",
  conversationId: "conversation",
  workerId: "worker",
  profileId: "profile",
  profileVersion: 1,
  nativeSessionAvailable: true,
  synchronizedContextRevision: 2,
  status: "active",
  lastModelId: "a",
  lastEffort: "low",
  createdAt: "2026-10-07T10:00:00Z",
  lastUsedAt: "2026-10-07T10:00:00Z",
};
const request: ConversationRouteRequest = {
  conversation: {
    id: "conversation",
    threadId: "stream",
    workflowId: "work",
    workflowVersion: 1,
    conversationRevision: 3,
    contextRevision: 2,
    createdAt: session.createdAt,
    updatedAt: session.lastUsedAt,
  },
  workflow: CONVERSATION_WORKFLOWS.work!,
  turn: {
    schemaVersion: 1,
    workerId: "worker",
    profileId: "profile",
    profileReleaseVersion: 1,
    modelId: "a",
    effort: "low",
    workflowId: "direct",
    workflowVersion: 2,
  },
  executionOptions: {
    schemaVersion: 1,
    models: {
      supported: true,
      discovery: "profile_catalog",
      allowsCustomModel: false,
      allowedModelIds: ["a", "b"],
      defaultModelId: null,
      options: [],
    },
    modelSwitch: { supported: true },
    effort: { supported: true, values: ["low", "high"], defaultValue: "low" },
  },
  sessionCapabilities: {
    durableSessions: true,
    incrementalContextSync: true,
    compatibleProfileVersions: [1],
  },
  sessions: [session],
  contextRevision: 2,
  sessionPolicy: "durable",
};

describe("Conversation Router", () => {
  it.each([
    {
      name: "same worker/model/effort",
      modelId: "a",
      effort: "low",
      action: "CONTINUE_SESSION",
      modelAction: "UNCHANGED_MODEL",
    },
    {
      name: "effort-only change",
      modelId: "a",
      effort: "high",
      action: "CONTINUE_SESSION",
      modelAction: "UNCHANGED_MODEL",
    },
    {
      name: "supported model switch",
      modelId: "b",
      effort: "high",
      action: "CONTINUE_SESSION",
      modelAction: "KEEP_SESSION_WITH_NEW_MODEL",
    },
    {
      name: "unsupported model switch",
      modelId: "b",
      effort: "low",
      modelSwitch: false,
      action: "RECONSTRUCT_SESSION",
      modelAction: "NEW_SESSION_FOR_MODEL",
    },
    {
      name: "lost native session",
      modelId: "a",
      effort: "low",
      available: false,
      action: "RECONSTRUCT_SESSION",
      modelAction: "UNCHANGED_MODEL",
    },
  ])("Phase 29 matrix: $name preserves historical choices", (scenario) => {
    const before = JSON.stringify(request);
    const next = {
      ...request,
      turn: {
        ...request.turn,
        modelId: scenario.modelId,
        effort: scenario.effort,
      },
      executionOptions: {
        ...request.executionOptions,
        modelSwitch: { supported: scenario.modelSwitch ?? true },
      },
      sessions: [
        { ...session, nativeSessionAvailable: scenario.available ?? true },
      ],
    };
    expect(routeConversation(next)).toMatchObject({
      action: scenario.action,
      modelAction: scenario.modelAction,
    });
    expect(JSON.stringify(request)).toBe(before);
    expect(next.turn.effort).toBe(scenario.effort);
  });

  it("switches workers and returns to the original session with delta synchronization", () => {
    const geminiTurn = {
      ...request.turn,
      workerId: "gemini",
      profileId: "gemini-profile",
    };
    expect(routeConversation({ ...request, turn: geminiTurn })).toMatchObject({
      action: "BOOTSTRAP_SESSION",
      workerSessionId: null,
    });
    const geminiSession = {
      ...session,
      id: "gemini-session",
      workerId: "gemini",
      profileId: "gemini-profile",
    };
    const sessions = [session, geminiSession];
    expect(
      routeConversation({ ...request, turn: geminiTurn, sessions })
        .workerSessionId,
    ).toBe("gemini-session");
    const returning = {
      ...request,
      conversation: {
        ...request.conversation,
        conversationRevision: 4,
        contextRevision: 3,
      },
      contextRevision: 3,
      sessions,
    };
    const before = JSON.stringify(returning);
    expect(routeConversation(returning)).toMatchObject({
      action: "SYNC_AND_CONTINUE",
      workerSessionId: "session",
      context: { transfer: "delta", fromRevision: 2, toRevision: 3 },
    });
    expect(JSON.stringify(returning)).toBe(before);
  });
  it("continues synchronized sessions without changing input", () => {
    const before = JSON.stringify(request);
    expect(routeConversation(request)).toMatchObject({
      action: "CONTINUE_SESSION",
      modelAction: "UNCHANGED_MODEL",
      workerSessionId: "session",
      context: { transfer: "none", fromRevision: 2, toRevision: 2 },
    });
    expect(JSON.stringify(request)).toBe(before);
  });
  it("synchronizes stale sessions with a bounded delta", () => {
    expect(
      routeConversation({
        ...request,
        sessions: [{ ...session, synchronizedContextRevision: 1 }],
      }),
    ).toMatchObject({
      action: "SYNC_AND_CONTINUE",
      context: { transfer: "delta", fromRevision: 1, toRevision: 2 },
    });
  });
  it("reconstructs when incremental synchronization is unavailable", () => {
    expect(
      routeConversation({
        ...request,
        sessionCapabilities: {
          ...request.sessionCapabilities,
          incrementalContextSync: false,
        },
        sessions: [{ ...session, synchronizedContextRevision: 1 }],
      }),
    ).toMatchObject({
      action: "RECONSTRUCT_SESSION",
      context: { transfer: "full", fromRevision: 0 },
    });
  });
  it("bootstraps only from sessions belonging to this Conversation and Worker/Profile", () => {
    for (const foreign of [
      { conversationId: "other" },
      { workerId: "other" },
      { profileId: "other" },
    ]) {
      expect(
        routeConversation({
          ...request,
          sessions: [{ ...session, ...foreign }],
        }),
      ).toMatchObject({
        action: "BOOTSTRAP_SESSION",
        workerSessionId: null,
        context: { transfer: "full" },
      });
    }
  });
  it("reconstructs missing native state and incompatible Profile releases", () => {
    for (const broken of [
      { nativeSessionAvailable: false },
      { profileVersion: 2 },
    ]) {
      expect(
        routeConversation({ ...request, sessions: [{ ...session, ...broken }] })
          .action,
      ).toBe("RECONSTRUCT_SESSION");
    }
  });
  it("never resumes context ahead of the frozen turn", () => {
    expect(routeConversation({ ...request, contextRevision: 1 })).toMatchObject(
      { action: "RECONSTRUCT_SESSION", workerSessionId: null },
    );
  });
  it("retains session when the Profile supports switching models, independently of effort", () => {
    expect(
      routeConversation({
        ...request,
        turn: { ...request.turn, modelId: "b", effort: "high" },
      }),
    ).toMatchObject({
      action: "CONTINUE_SESSION",
      modelAction: "KEEP_SESSION_WITH_NEW_MODEL",
    });
    expect(
      routeConversation({
        ...request,
        turn: { ...request.turn, effort: "high" },
      }).modelAction,
    ).toBe("UNCHANGED_MODEL");
  });
  it("requires reconstructed context for a new session when model switching is unsupported", () => {
    expect(
      routeConversation({
        ...request,
        turn: { ...request.turn, modelId: "b" },
        executionOptions: {
          ...request.executionOptions,
          modelSwitch: { supported: false },
        },
      }),
    ).toMatchObject({
      action: "RECONSTRUCT_SESSION",
      modelAction: "NEW_SESSION_FOR_MODEL",
      context: { transfer: "full" },
    });
  });
  it("requires canonical history for model replacement even before context materialization", () => {
    expect(
      routeConversation({
        ...request,
        contextRevision: 0,
        sessions: [{ ...session, synchronizedContextRevision: 0 }],
        turn: { ...request.turn, modelId: "b" },
        executionOptions: {
          ...request.executionOptions,
          modelSwitch: { supported: false },
        },
      }),
    ).toMatchObject({
      action: "RECONSTRUCT_SESSION",
      modelAction: "NEW_SESSION_FOR_MODEL",
      context: { transfer: "full", toRevision: 0 },
    });
  });
  it("supports stateless policy and Workers without durable sessions", () => {
    expect(
      routeConversation({ ...request, sessionPolicy: "stateless" }),
    ).toMatchObject({
      action: "STATELESS_EXECUTION",
      workerSessionId: null,
      context: { transfer: "full" },
    });
    expect(
      routeConversation({
        ...request,
        sessionCapabilities: {
          ...request.sessionCapabilities,
          durableSessions: false,
        },
      }).action,
    ).toBe("STATELESS_EXECUTION");
  });
  it("prefers compatible sessions and breaks equal timestamps deterministically", () => {
    expect(
      routeConversation({
        ...request,
        sessions: [
          { ...session, id: "z" },
          { ...session, id: "a" },
          {
            ...session,
            id: "newer",
            profileVersion: 2,
            lastUsedAt: "2026-10-07T11:00:00Z",
          },
        ],
      }).workerSessionId,
    ).toBe("a");
  });
  it("uses Default without guessing resolved provider model and avoids empty context transfer", () => {
    expect(
      routeConversation({
        ...request,
        contextRevision: 0,
        sessions: [],
        turn: { ...request.turn, modelId: null, effort: null },
      }),
    ).toMatchObject({
      action: "BOOTSTRAP_SESSION",
      context: { transfer: "none", toRevision: 0 },
    });
  });
  it("fails closed on mismatched workflows, invalid selections, and corrupt revisions", () => {
    expect(() =>
      routeConversation({ ...request, workflow: CONVERSATION_WORKFLOWS.chat! }),
    ).toThrow(/identities/);
    expect(() =>
      routeConversation({
        ...request,
        turn: { ...request.turn, modelId: "foreign" },
      }),
    ).toThrow(/model/);
    expect(() =>
      routeConversation({
        ...request,
        turn: { ...request.turn, effort: "unknown" },
      }),
    ).toThrow(/effort/);
    for (const contextRevision of [-1, 3, 0.5, NaN])
      expect(() => routeConversation({ ...request, contextRevision })).toThrow(
        /revision/,
      );
    expect(() =>
      routeConversation({
        ...request,
        sessions: [{ ...session, synchronizedContextRevision: -1 }],
      }),
    ).toThrow(/metadata/);
  });
});
