import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

describe("configured Worker product boundary", () => {
  it("does not expose standalone AI Account routes", () => {
    const router = readFileSync(
      fileURLToPath(new URL("../src/routes/router.ts", import.meta.url)),
      "utf8",
    );
    expect(router).not.toContain("/api/accounts");
    expect(router).not.toContain("/accounts");
    expect(router).not.toContain("handleCreateCredentialProfile");
    expect(router).not.toContain("handleCreateCredentialGrant");
  });
});
