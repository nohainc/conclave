import { describe, expect, it } from "vitest";
import {
  isTrustedRealtimeOrigin,
  sanitizeDiagnostics,
  structuredLogRecord,
} from "../src/observability.js";

describe("observability", () => {
  it("redacts secrets and bounds diagnostic values", () => {
    const result = sanitizeDiagnostics({
      apiKey: "do-not-export",
      nested: { authorization: "Bearer secret" },
      output: "x".repeat(600),
      items: Array.from({ length: 60 }, (_, index) => index),
    }) as Record<string, unknown>;

    expect(result.apiKey).toBe("[redacted]");
    expect((result.nested as Record<string, unknown>).authorization).toBe(
      "[redacted]",
    );
    expect(String(result.output)).toHaveLength(513);
    expect(result.items).toHaveLength(50);
  });

  it("keeps end-to-end correlation fields in structured records", () => {
    const record = structuredLogRecord("info", "assignment.completed", {
      requestId: "request-1",
      eventId: "event-1",
      workspaceId: "workspace-1",
      runId: "run-1",
      taskId: "task-1",
      attemptId: "attempt-1",
      assignmentId: "assignment-1",
      hostId: "host-1",
      workerId: "worker-1",
      credentialProfileId: "profile-1",
    });

    expect(record.correlation).toMatchObject({
      requestId: "request-1",
      eventId: "event-1",
      assignmentId: "assignment-1",
      credentialProfileId: "profile-1",
    });
  });

  it("requires a trusted Origin for browser realtime upgrades", () => {
    expect(
      isTrustedRealtimeOrigin(
        new Request("https://app.conclave.test/api/realtime", {
          headers: { origin: "https://evil.example" },
        }),
      ),
    ).toBe(false);
    expect(
      isTrustedRealtimeOrigin(
        new Request("https://api.conclave.test/api/realtime", {
          headers: { origin: "https://app.conclave.test" },
        }),
        ["https://app.conclave.test"],
      ),
    ).toBe(true);
  });
});
