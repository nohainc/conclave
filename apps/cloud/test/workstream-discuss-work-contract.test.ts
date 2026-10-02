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
  fileURLToPath(new URL("../src/routes/work.ts", import.meta.url)),
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
const handlers = readFileSync(
  fileURLToPath(new URL("../src/routes/handlers.ts", import.meta.url)),
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
    expect(`${work}\n${handlers}`).toContain('"run.start"');
    expect(work).toContain("validateWorkRequest(workRequest, policy)");
    expect(work).toContain("workstream.work_requested");
  });

  it("exposes the checkout provisioning control plane", () => {
    expect(router).toMatch(/workstreams.*checkouts/);
    expect(workstreams).toContain("handleProvisionWorkstreamCheckout");
    expect(workstreams).toContain("Workspace Project Grant is not active");
    expect(workstreams).toContain(
      "Add at least one repository mapping to the Workspace Project Grant before provisioning a checkout",
    );
    expect(gateway).toContain("Workspace is offline");
    expect(workstreams).toContain("provision-checkout");
    expect(gateway).toContain("workstream.checkout.status");
  });
});
