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
    projectId: "project-1",
    runId: "run-1",
    sequence: 7,
    payload: { entityId: "run-1", status: "completed", summary: "Done" },
  };

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
