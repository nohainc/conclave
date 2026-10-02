import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const projects = readFileSync(
  fileURLToPath(new URL("../src/routes/projects.ts", import.meta.url)),
  "utf8",
);
const workstreams = readFileSync(
  fileURLToPath(new URL("../src/routes/workstreams.ts", import.meta.url)),
  "utf8",
);
const work = readFileSync(
  fileURLToPath(new URL("../src/routes/work-creation.ts", import.meta.url)),
  "utf8",
);
const workstreamPolicy = readFileSync(
  fileURLToPath(new URL("../src/routes/workstream-policy.ts", import.meta.url)),
  "utf8",
);
const router = readFileSync(
  fileURLToPath(new URL("../src/routes/router.ts", import.meta.url)),
  "utf8",
);
const gateway = readFileSync(
  fileURLToPath(new URL("../src/workspace-gateway.ts", import.meta.url)),
  "utf8",
);

describe("Workstream Discuss / Work boundary", () => {
  it("routes discussion through the Workstream", () => {
    expect(router).toMatch(/workstreams.*discussion-messages/);
    expect(projects).toContain("handleCreateProject");
  });

  it("exposes separate discussion and explicit Work Request routes", () => {
    expect(router).toMatch(/workstreams.*discussion-messages/);
    expect(router).toMatch(/workstreams.*work-requests/);
    expect(`${work}\n${workstreamPolicy}`).toContain('"run.start"');
    expect(work).toContain("validateWorkRequest(workRequest, policy)");
    expect(work).toContain("workstream.work_requested");
  });

  it("does not expose the removed Checkout control plane", () => {
    expect(router).not.toMatch(/workstreams.*checkouts/);
    expect(workstreams).not.toMatch(/WorkstreamCheckout|checkout/);
    expect(gateway).not.toMatch(/checkout|checkpoint|rollback/i);
  });
});
