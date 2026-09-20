import { describe, expect, it } from "vitest";
import worker from "../src/index.js";

describe("Worker smoke tests", () => {
  it("returns a health response", async () => {
    const response = await worker.fetch(
      new Request("https://conclave.test/health"),
      {
        CONCLAVE_ENVIRONMENT: "development",
      },
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      environment: "development",
    });
  });

  it("returns not found for unknown routes", async () => {
    const response = await worker.fetch(
      new Request("https://conclave.test/unknown"),
      {
        CONCLAVE_ENVIRONMENT: "development",
      },
    );

    expect(response.status).toBe(404);
  });
});
