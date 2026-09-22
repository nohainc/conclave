import { describe, expect, it } from "vitest";
import { executeReadOnlyPanel } from "../src/index.js";
import { request, worker } from "./assignment-fixtures.js";

describe("read-only assignment roles", () => {
  it("validates role and capability before assignment", async () => {
    const result = await executeReadOnlyPanel({
      request,
      roles: ["researcher"],
      workers: { researcher: worker("researcher", { roles: ["researcher"] }) },
    });
    expect(result[0]?.result.status).toBe("completed");
  });
  it("rejects workers that share an independence key", async () => {
    await expect(
      executeReadOnlyPanel({
        request,
        roles: ["researcher", "architect"],
        workers: {
          researcher: worker("one", {
            roles: ["researcher"],
            independenceKey: "same",
          }),
          architect: worker("two", {
            roles: ["architect"],
            independenceKey: "same",
          }),
        },
      }),
    ).rejects.toThrow(/independent/);
  });
});
