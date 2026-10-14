import { describe, expect, it } from "vitest";
import { hashToken } from "../../../packages/security/src/index.js";
import { WorkspaceGateway } from "../src/workspace-gateway.js";
import { conversationFixture } from "./helpers/conversation.js";

const token = "runtime-secret-assignment-lifecycle";

/**
 * Drives the real Gateway over the HTTP fallback transport against the real
 * SQL schema, so the ack handlers, the transition helper, the generated
 * source sets and the conversation-turn triggers are exercised together.
 */
async function gatewayFixture(initialStatus: string) {
  const f = await conversationFixture();
  f.sqlite.exec(
    "INSERT INTO runs(id,space_id,status,created_at,updated_at) VALUES('RUN','P','running','now','now')",
  );
  f.assign("A1");
  f.sqlite
    .prepare(
      `UPDATE worker_assignments
          SET run_id='RUN', attempt_id='ATT1', idempotency_key='IDEM1', status=?
        WHERE id='A1'`,
    )
    .run(initialStatus);
  f.sqlite
    .prepare(
      "UPDATE workspace_runtime_identities SET credential_token_hash=? WHERE id='RT'",
    )
    .run(await hashToken(token));
  const storage = new Map<string, unknown>();
  const gateway = new WorkspaceGateway(
    {
      id: { name: "WS" },
      storage: {
        get: async (key: string) => storage.get(key),
        put: async (key: string, value: unknown) => {
          storage.set(key, value);
        },
        delete: async (key: string) => storage.delete(key),
      },
    } as never,
    { CONCLAVE_DB: f.db as never },
  );
  const headers = {
    authorization: `Bearer ${token}`,
    "content-type": "application/json",
  };
  const create = await gateway.fetch(
    new Request("https://gateway.internal/runtime/sessions", {
      method: "POST",
      headers,
      body: JSON.stringify({
        workspaceRuntimeId: "RT",
        contractVersion: "1.0",
      }),
    }),
  );
  expect(create.status).toBe(200);
  const { sessionId } = (await create.json()) as { sessionId: string };

  let counter = 0;
  const send = async (
    type: string,
    payload: Record<string, unknown>,
    overrides: Record<string, unknown> = {},
  ) => {
    counter += 1;
    const at = new Date().toISOString();
    const response = await gateway.fetch(
      new Request("https://gateway.internal/runtime/events", {
        method: "POST",
        headers,
        body: JSON.stringify({
          sessionId,
          events: [
            {
              contract: "conclave.desktop-auth-transport",
              version: "1.0",
              eventId: `event-${counter}`,
              occurredAt: at,
              message: {
                protocol: "conclave.workspace-runtime-protocol",
                protocolVersion: "5.1",
                messageId: `message-${counter}`,
                timestamp: at,
                type,
                executionWorkspaceId: "WS",
                workspaceRuntimeId: "RT",
                workerId: "worker-a",
                runId: "RUN",
                taskId: "T",
                attemptId: "ATT1",
                assignmentId: "A1",
                idempotencyKey: "IDEM1",
                payload,
                ...overrides,
              },
            },
          ],
        }),
      }),
    );
    expect(response.status).toBe(200);
  };
  const status = () =>
    f.sqlite
      .prepare(
        "SELECT status, updated_at FROM worker_assignments WHERE id='A1'",
      )
      .get() as { status: string; updated_at: string };
  return { ...f, send, status };
}

const started = { started: true, engineStarted: true, providerStarted: true };

describe("Gateway assignment acknowledgement ordering", () => {
  it("never reverts Running to Acknowledged when acceptance arrives late", async () => {
    const f = await gatewayFixture("dispatched");
    await f.send("assignment.start.ack", started);
    expect(f.status().status).toBe("running");
    const stamp = f.status().updated_at;

    await f.send("assignment.ack", { accepted: true });
    await f.send("assignment.ack", { accepted: true });
    expect({ ...f.status() }).toEqual({ status: "running", updated_at: stamp });
    const task = f.sqlite
      .prepare("SELECT status FROM workflow_tasks WHERE id='T'")
      .get() as { status: string };
    expect(task.status).toBe("running");
  });

  it("accepts in the normal order and tolerates duplicates", async () => {
    const f = await gatewayFixture("dispatched");
    await f.send("assignment.ack", { accepted: true });
    expect(f.status().status).toBe("acknowledged");
    const stamp = f.status().updated_at;
    await f.send("assignment.ack", { accepted: true });
    expect(f.status().updated_at).toBe(stamp);
    await f.send("assignment.start.ack", started);
    await f.send("assignment.start.ack", started);
    expect(f.status().status).toBe("running");
  });

  it("does not let a replayed rejection fail an accepted assignment", async () => {
    const f = await gatewayFixture("running");
    await f.send("assignment.ack", { accepted: false });
    expect(f.status().status).toBe("running");
  });

  it("does not move a terminal assignment back to Running", async () => {
    const f = await gatewayFixture("cancelled");
    await f.send("assignment.start.ack", started);
    await f.send("assignment.ack", { accepted: true });
    expect(f.status().status).toBe("cancelled");
  });

  it("ignores acknowledgements carrying another attempt's identity", async () => {
    const f = await gatewayFixture("dispatched");
    await f.send("assignment.start.ack", started, { attemptId: "ATT0" });
    await f.send("assignment.ack", { accepted: true }, { attemptId: "ATT0" });
    expect(f.status().status).toBe("dispatched");
  });
});
