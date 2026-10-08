import { describe, expect, it } from "vitest";
import {
  isDurableRealtimeEventType,
  isEphemeralRealtimeEventType,
  parseRealtimeEvent,
} from "../src/index.js";

describe("realtime event contract", () => {
  const event = {
    eventId: "event-1",
    type: "run.completed",
    version: "1.0",
    timestamp: "2026-09-23T10:00:00.000Z",
    workspaceId: "workspace-1",
    spaceId: "space-1",
    runId: "run-1",
    sequence: 7,
    payload: { entityId: "run-1", status: "completed", summary: "Done" },
  };

  it("preserves the acceptance submission correlation ID", () => {
    const accepted = {
      ...event,
      type: "work_request.created",
      payload: {
        workRequestId: "request",
        threadId: "thread",
        submissionId: "opaque-submission",
        status: "queued",
      },
    };
    expect(parseRealtimeEvent(accepted)).toEqual(accepted);
  });

  it("accepts current durable and ephemeral events", () => {
    expect(parseRealtimeEvent(JSON.stringify(event))).toEqual(event);
    expect(isDurableRealtimeEventType("run.completed")).toBe(true);
    expect(isEphemeralRealtimeEventType("stream.delta")).toBe(true);
  });

  it("retains unknown events from a compatible minor version", () => {
    const unknown = parseRealtimeEvent({
      ...event,
      type: "future.new.fact",
      version: "1.1",
    });
    expect(unknown.type).toBe("future.new.fact");
  });

  it.each([
    ["missing sequence", { ...event, sequence: undefined }],
    ["negative sequence", { ...event, sequence: -1 }],
    ["major version", { ...event, version: "2.0" }],
    [
      "raw secret",
      { ...event, payload: { ...event.payload, rawApiKey: "secret" } },
    ],
    ["oversized delta", { ...event, payload: { delta: "x".repeat(8193) } }],
  ])("rejects %s", (_name, input) => {
    expect(() => parseRealtimeEvent(input)).toThrow();
  });
});

describe("collaboration streams", () => {
  const event = {
    eventId: "collab",
    type: "discussion.created",
    version: "1.1",
    timestamp: "2026-10-06T00:00:00.000Z",
    spaceId: "same-id",
    threadId: "w",
    stream: { kind: "space", id: "same-id" },
    sequence: 1,
    payload: { entityId: "m", threadId: "w" },
  };
  it("accepts ID-only collaboration signals with no execution Workspace", () => {
    expect(parseRealtimeEvent(event)).toEqual(event);
    expect(isDurableRealtimeEventType("discussion.created")).toBe(true);
    expect(isDurableRealtimeEventType("workspace_space_grant.updated")).toBe(
      true,
    );
  });
  it.each([
    { ...event, workspaceId: "same-id" },
    { ...event, stream: undefined },
    { ...event, stream: { kind: "space", id: "wrong-space" } },
    { ...event, stream: { kind: "execution_workspace", id: "same-id" } },
    { ...event, version: "1.0" },
    {
      ...event,
      payload: { entityId: "m", threadId: "w", text: "large history" },
    },
    { ...event, payload: { entityId: "m" } },
    { ...event, type: "work_request.created" },
  ])(
    "rejects ambiguous ownership or oversized entity-bearing signals",
    (input) => {
      expect(() => parseRealtimeEvent(input)).toThrow();
    },
  );
});
