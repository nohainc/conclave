import { expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { conversationFixture } from "./helpers/conversation.js";
vi.mock("../src/routes/thread-policy.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: vi.fn(async () => ({})),
}));
vi.mock("../src/collaboration-events.js", () => ({
  publishCollaborationEvent: vi.fn(async () => {}),
}));
import { publishCollaborationEvent } from "../src/collaboration-events.js";
import { handleClearWorkHistory } from "../src/routes/work-lifecycle.js";
import { routeHandlers } from "../src/index.js";
import {
  routeWorkerRequest,
  type WorkerRouteDependencies,
} from "../src/routes/router.js";
import { HttpError, json } from "../src/routes/handlers.js";
import { RealtimeEventEnvelopeSchema } from "@conclave/protocol";
import type { SecurityEnv } from "../src/routes/handlers.js";

it("routes through production handler registration and clears remote history", async () => {
  const f = await conversationFixture();
  try {
    f.sqlite.exec(
      readFileSync(
        new URL(
          "../migrations-v8/0054_thread_work_session_generation.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    f.sqlite.exec("UPDATE work_requests SET status='completed' WHERE id='R'");
    const response = await routeWorkerRequest(
      new Request("https://test/api/threads/W/work-history/clear", {
        method: "POST",
      }),
      { CONCLAVE_DB: f.db } as unknown as Env,
      undefined,
      routeHandlers,
      {
        json,
        HttpError: HttpError as unknown as WorkerRouteDependencies["HttpError"],
        errorMessage: String,
        requireSameOriginForCookieMutation: () => undefined,
      },
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ threadId: "W", cleared: true });
    for (const table of [
      "work_requests",
      "conversations",
      "conversation_history_entries",
    ]) {
      expect(
        f.sqlite.prepare(`SELECT COUNT(*) AS count FROM ${table}`).get()!.count,
      ).toBe(0);
    }
    expect(
      f.sqlite
        .prepare(
          "SELECT work_session_generation AS generation FROM threads WHERE id='W'",
        )
        .get()!.generation,
    ).toBe(1);
    expect(publishCollaborationEvent).toHaveBeenCalledWith(
      expect.anything(),
      "thread.work_cleared",
      "P",
      "W",
      { threadId: "W" },
    );
  } finally {
    f.sqlite.close();
  }
});

it("rejects active work without deleting remote history", async () => {
  const f = await conversationFixture();
  try {
    await expect(
      handleClearWorkHistory(
        new Request("https://test/api/threads/W/work-history/clear", {
          method: "POST",
        }),
        { CONCLAVE_DB: f.db } as unknown as SecurityEnv,
        "W",
      ),
    ).rejects.toMatchObject({ status: 409 });
    expect(
      f.sqlite.prepare("SELECT COUNT(*) AS count FROM work_requests").get()!
        .count,
    ).toBe(1);
    expect(
      f.sqlite
        .prepare("SELECT COUNT(*) AS count FROM conversation_history_entries")
        .get()!.count,
    ).toBeGreaterThan(0);
  } finally {
    f.sqlite.close();
  }
});

it("emits a clear event that the protocol's realtime envelope accepts", async () => {
  const f = await conversationFixture();
  try {
    f.sqlite.exec(
      readFileSync(
        new URL(
          "../migrations-v8/0054_thread_work_session_generation.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    f.sqlite.exec("UPDATE work_requests SET status='completed' WHERE id='R'");
    vi.mocked(publishCollaborationEvent).mockClear();

    await handleClearWorkHistory(
      new Request("https://test/api/threads/W/work-history/clear", {
        method: "POST",
      }),
      { CONCLAVE_DB: f.db } as unknown as SecurityEnv,
      "W",
    );

    const calls = vi.mocked(publishCollaborationEvent).mock.calls;
    expect(calls).toHaveLength(1);
    const [, type, spaceId, entityId, options] = calls[0]!;
    // Validate the same envelope shape the publisher builds, using the real
    // protocol schema rather than a mock, so an invalid event name fails here.
    const envelope = RealtimeEventEnvelopeSchema.parse({
      eventId: "evt-clear-work-1",
      type,
      version: "1.1",
      timestamp: new Date().toISOString(),
      stream: { kind: "space", id: spaceId },
      spaceId,
      threadId: "W",
      sequence: 1,
      payload: { entityId, ...options },
    });
    expect(envelope.type).toBe("thread.work_cleared");
  } finally {
    f.sqlite.close();
  }
});
