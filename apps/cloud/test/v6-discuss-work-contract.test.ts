import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const handlers = readFileSync(
  fileURLToPath(new URL("../src/routes/handlers.ts", import.meta.url)),
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

function functionBody(name: string): string {
  const start = handlers.indexOf(`async function ${name}`);
  const end = handlers.indexOf(
    "\n// =========================================================================\n// V6",
    start,
  );
  return handlers.slice(start, end);
}

describe("v6 Discuss / Work boundary", () => {
  it("keeps generic Chat messages free of orchestration authority", () => {
    const body = functionBody("handleCreateChatMessage");
    expect(body).not.toContain("startChatExecution");
    expect(body).not.toContain("resumeChatExecution");
    expect(body).not.toContain("intentProposal");
    expect(body).toContain("goalId: null");
  });

  it("exposes separate discussion and explicit Work Request routes", () => {
    expect(router).toMatch(/workstreams.*discussion-messages/);
    expect(router).toMatch(/workstreams.*work-requests/);
    expect(handlers).toContain('"run.start"');
    expect(handlers).toContain("validateWorkRequest(workRequest, policy)");
    expect(handlers).toContain("workstream.work_requested");
  });

  it("exposes the checkout provisioning control plane", () => {
    expect(router).toMatch(/workstreams.*checkouts/);
    expect(handlers).toContain("handleProvisionWorkstreamCheckout");
    expect(handlers).toContain("Workspace Project Grant is not active");
    expect(handlers).toContain(
      "Project repository is required before provisioning a checkout",
    );
    expect(handlers).toContain("Primary Workspace is offline");
    expect(handlers).toContain("provision-checkout");
    expect(gateway).toContain("workstream.checkout.status");
  });
});
