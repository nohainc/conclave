import { describe, expect, it, vi } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import type { SecurityEnv } from "../src/routes/handlers.js";
vi.mock("../src/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeWorkstreamAccess: async () => ({
    context: { userId: "owner" },
    projectId: "P",
  }),
  validateWorkflowWorkerEligibility: async () => ({
    issues: [],
    primaryWorkspaceId: "workspace",
  }),
}));
vi.mock("../src/event-publisher.js", () => ({
  createEventPublisher: () => ({ publish: async () => {} }),
}));
import { handleCreateWorkRequest } from "../src/routes/work-creation.js";
function fixture() {
  const { sqlite, db } = sqliteD1();
  sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('owner','owner@test','Owner','now','now');
    INSERT INTO projects(id,owner_user_id,name,created_at,updated_at) VALUES('P','owner','Project','now','now');
    INSERT INTO project_memberships(id,project_id,user_id,role,created_at,updated_at) VALUES('member','P','owner','owner','now','now');
    INSERT INTO workstreams(id,project_id,name,status,lead_user_id,created_at,updated_at) VALUES('W','P','Stream','active','owner','now','now');
    INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES('workspace','owner','Workspace','now','now');`);
  const instances = new Set<string>();
  let failDispatch = false;
  const enqueue = vi.fn(async () => new Response("{}"));
  const create = vi.fn(async ({ id }: { id: string }) => {
    if (failDispatch) throw new Error("dispatch temporarily unavailable");
    if (instances.has(id)) throw new Error("instance already exists");
    instances.add(id);
    return { status: async () => ({ status: "queued" }) };
  });
  const get = vi.fn(async (id: string) => {
    if (!instances.has(id)) throw new Error("missing instance");
    return { status: async () => ({ status: "queued" }) };
  });
  const env = {
    CONCLAVE_DB: db,
    CONCLAVE_RUN_WORKFLOW: { create, get },
    CONCLAVE_WORKSTREAM_COORDINATOR: { getByName: () => ({ fetch: enqueue }) },
  } as unknown as SecurityEnv;
  const request = (
    prompt = "Implement this",
    key = "work-operation-000000001",
  ) =>
    new Request("https://cloud.test/workstreams/W/work-requests", {
      method: "POST",
      headers: { "Idempotency-Key": key },
      body: JSON.stringify({
        workflowId: "direct",
        input: { originalRequest: prompt },
      }),
    });
  const submit = (prompt?: string, key?: string) =>
    handleCreateWorkRequest(request(prompt, key), env, "W");
  return {
    sqlite,
    db,
    instances,
    create,
    get,
    enqueue,
    submit,
    setFail: (value: boolean) => {
      failDispatch = value;
    },
  };
}
describe("Work mutation identity through response loss", () => {
  it("concurrent and later explicit retries create one request, Run, audit record and runtime instance", async () => {
    const f = fixture();
    const responses = await Promise.all(
      Array.from({ length: 5 }, () => f.submit()),
    );
    const values = (await Promise.all(responses.map((r) => r.json()))) as {
      workRequest: { id: string };
      run: { id: string };
    }[];
    expect(new Set(values.map((v) => v.workRequest.id)).size).toBe(1);
    expect(new Set(values.map((v) => v.run.id)).size).toBe(1);
    expect(f.instances.size).toBe(1);
    for (const table of [
      "work_requests",
      "runs",
      "project_audit_log",
      "mutation_receipts",
    ]) {
      expect(
        f.sqlite.prepare(`SELECT count(*) AS n FROM ${table}`).get()?.n,
      ).toBe(1);
    }
    expect(await (await f.submit()).json()).toEqual(values[0]);
    expect(f.instances.size).toBe(1);
    await expect(f.submit("Different prompt")).rejects.toMatchObject({
      status: 409,
    });
    f.sqlite.close();
  });
  it("a retry resumes interrupted dispatch with the same committed identities", async () => {
    const f = fixture();
    f.setFail(true);
    await expect(f.submit()).rejects.toThrow(
      "dispatch temporarily unavailable",
    );
    const before = f.sqlite.prepare("SELECT id FROM work_requests").get()?.id;
    expect(f.instances.size).toBe(0);
    f.setFail(false);
    const accepted = (await (await f.submit()).json()) as {
      workRequest: { id: string };
    };
    expect(accepted.workRequest.id).toBe(before);
    expect(f.instances.size).toBe(1);
    expect(f.sqlite.prepare("SELECT count(*) AS n FROM runs").get()?.n).toBe(1);
    f.sqlite.close();
  });
  it("replaying a cancelled/finished request never starts execution again", async () => {
    const f = fixture();
    await f.submit();
    f.sqlite.exec("UPDATE work_requests SET status='cancelled'");
    f.create.mockClear();
    f.enqueue.mockClear();
    expect((await f.submit()).status).toBe(202);
    expect(f.create).not.toHaveBeenCalled();
    expect(f.enqueue).not.toHaveBeenCalled();
    f.sqlite.close();
  });
});
