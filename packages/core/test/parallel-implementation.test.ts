import { describe, expect, it } from "vitest";
import { executeParallelImplementations } from "../src/index.js";
import { request, worker } from "./assignment-fixtures.js";

describe("parallel assignment implementation", () => {
  it("requires isolated workspaces and independent workers", async () => {
    await expect(
      executeParallelImplementations({
        request,
        executions: [
          { worker: worker("one"), workspaceRepositoryId: "repo::one" },
          { worker: worker("two"), workspaceRepositoryId: "repo::two" },
        ],
      }),
    ).resolves.toHaveLength(2);
  });
});
