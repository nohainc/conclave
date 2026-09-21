import { describe, expect, it } from "vitest";
import worker from "../src/index.js";

describe("web AI connector relay", () => {
  it("registers and reports a subscription-backed relay task", async () => {
    const env = {
      CONCLAVE_ENVIRONMENT: "development",
      CONCLAVE_CONNECTOR_REGISTRATION_TOKEN: "relay-test-token",
    } as unknown as Env;
    const registered = await worker.fetch(
      new Request("https://conclave.test/api/connector/tasks/register", {
        method: "POST",
        headers: {
          authorization: "Bearer relay-test-token",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          taskId: "web-relay-task",
          objective: "Propose an architecture",
          prompt: "Return a structured candidate",
        }),
      }),
      env,
    );
    expect(registered.status).toBe(200);

    const status = await worker.fetch(
      new Request("https://conclave.test/api/connector/tasks/web-relay-task/status", {
        headers: { authorization: "Bearer relay-test-token" },
      }),
      env,
    );
    expect(status.status).toBe(200);
    expect(await status.json()).toMatchObject({ status: "queued" });
  });
});
