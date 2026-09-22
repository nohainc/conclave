import { describe, expect, it } from "vitest";
import worker from "../src/index.js";
import type {
  D1DatabaseLike,
  D1Statement,
} from "../../../packages/persistence/src/index.js";

type Tenant = "org-a" | "org-b";

const projects = [
  { id: "project-a", organization_id: "org-a", name: "A" },
  { id: "project-b", organization_id: "org-b", name: "B" },
];
const rowsByTenant: Record<
  Tenant,
  Record<string, readonly Record<string, unknown>[]>
> = {
  "org-a": {
    workers: [
      {
        id: "worker-a",
        name: "Worker A",
        provider: "a",
        roles_json: '["lead"]',
        capabilities_json: "[]",
        status: "available",
        cost: "",
      },
    ],
    tasks: [
      {
        id: "task-a",
        title: "Task A",
        phase: "Research",
        status: "completed",
        worker: "worker-a",
        detail: "A",
        progress: 1,
        dependencies: "[]",
        tokens: "1",
        cost: "0",
      },
    ],
    findings: [
      {
        id: "finding-a",
        title: "Finding A",
        description: "A",
        severity: "minor",
        status: "open",
        taskId: "task-a",
        author: "Unknown",
      },
    ],
    events: [
      { time: "now", title: "RunStarted", detail: "run-a", kind: "RunStarted" },
    ],
    artifacts: [
      { name: "artifact-a", type: "text/plain", size: 1, source: "Conclave" },
    ],
    modelCalls: [
      {
        worker: "worker-a",
        model: "model-a",
        task: "attempt-a",
        tokens: 1,
        cost: 0,
        duration: "—",
        status: "completed",
      },
    ],
    plugins: [
      {
        id: "plugin-a",
        name: "Plugin A",
        version: "1.0.0",
        status: "Installed",
        roles: [],
        capabilities: [],
      },
    ],
  },
  "org-b": {
    workers: [
      {
        id: "worker-b",
        name: "Worker B",
        provider: "b",
        roles_json: '["reviewer"]',
        capabilities_json: "[]",
        status: "available",
        cost: "",
      },
    ],
    tasks: [
      {
        id: "task-b",
        title: "Task B",
        phase: "Research",
        status: "completed",
        worker: "worker-b",
        detail: "B",
        progress: 1,
        dependencies: "[]",
        tokens: "1",
        cost: "0",
      },
    ],
    findings: [
      {
        id: "finding-b",
        title: "Finding B",
        description: "B",
        severity: "major",
        status: "open",
        taskId: "task-b",
        author: "Unknown",
      },
    ],
    events: [
      { time: "now", title: "RunStarted", detail: "run-b", kind: "RunStarted" },
    ],
    artifacts: [
      { name: "artifact-b", type: "text/plain", size: 1, source: "Conclave" },
    ],
    modelCalls: [
      {
        worker: "worker-b",
        model: "model-b",
        task: "attempt-b",
        tokens: 1,
        cost: 0,
        duration: "—",
        status: "completed",
      },
    ],
    plugins: [
      {
        id: "plugin-b",
        name: "Plugin B",
        version: "1.0.0",
        status: "Installed",
        roles: [],
        capabilities: [],
      },
    ],
  },
};

const runs = [
  { id: "run-a", organization_id: "org-a", status: "running" },
  { id: "run-b", organization_id: "org-b", status: "running" },
];

class Statement implements D1Statement {
  private values: readonly unknown[] = [];
  constructor(
    private readonly query: string,
    private readonly role: string,
    private readonly projectIds: readonly string[],
    private readonly queries: string[],
  ) {
    queries.push(query);
  }
  bind(...values: unknown[]): D1Statement {
    this.values = values;
    return this;
  }
  async first<T>(): Promise<T | null> {
    if (this.query.includes("workspace_memberships")) {
      return { role: this.role, status: "active" } as T;
    }
    if (this.query.includes("SELECT r.id FROM runs")) {
      if (
        !this.query.includes("p.organization_id = ?1") &&
        !this.query.includes("p.workspace_id = ?1") &&
        !this.query.includes("p.id = ?1")
      ) {
        throw new Error("unscoped Studio run query");
      }
      const tenant = this.tenant();
      return (runs.find((run) => run.organization_id === tenant) ??
        null) as T | null;
    }
    return null;
  }
  async all<T>(): Promise<{ results: readonly T[] }> {
    if (this.query.includes("FROM workspace_memberships")) {
      const organizationId = this.values.find(
        (value): value is Tenant => value === "org-a" || value === "org-b",
      ) as Tenant;
      return {
        results: [
          {
            user_id: `user-${organizationId}`,
            email: `${organizationId}-user@example.com`,
            display_name: "Test User",
            user_status: "active",
            workspace_id: organizationId,
            role: this.role,
            status: "active",
          } as T,
        ],
      };
    }
    if (this.query.includes("project_memberships"))
      return {
        results: this.projectIds.map((project_id) => ({
          project_id,
          role: "collaborator",
        })),
      } as unknown as { results: readonly T[] };
    if (
      this.query.includes("FROM projects p") ||
      this.query.includes("FROM workers") ||
      this.query.includes("FROM tasks t") ||
      this.query.includes("FROM findings f") ||
      this.query.includes("FROM events e") ||
      this.query.includes("FROM artifacts a") ||
      this.query.includes("FROM model_calls mc")
    ) {
      const scoped =
        this.query.includes("organization_id = ?1") ||
        this.query.includes("p.organization_id = ?1") ||
        this.query.includes("workspace_id = ?1") ||
        this.query.includes("p.workspace_id = ?1") ||
        this.query.includes("p.id = ?1");
      if (!scoped) throw new Error("unscoped Studio query");
    }
    if (this.query.includes("FROM projects p")) {
      const tenant = this.tenant();
      return {
        results: projects.filter(
          (project) => project.organization_id === tenant,
        ) as T[],
      };
    }
    if (this.query.includes("FROM workers"))
      return { results: this.rows("workers") as T[] };
    if (this.query.includes("FROM tasks t"))
      return { results: this.rows("tasks") as T[] };
    if (this.query.includes("FROM findings f"))
      return { results: this.rows("findings") as T[] };
    if (this.query.includes("FROM events e"))
      return { results: this.rows("events") as T[] };
    if (this.query.includes("FROM artifacts a"))
      return { results: this.rows("artifacts") as T[] };
    if (this.query.includes("FROM model_calls mc"))
      return { results: this.rows("modelCalls") as T[] };
    if (this.query.includes("FROM worker_plugins p"))
      return { results: this.rows("plugins") as T[] };
    return { results: [] };
  }
  async run(): Promise<{ success: boolean }> {
    return { success: true };
  }
  private tenant(): Tenant {
    const candidate = this.values.find(
      (value): value is Tenant => value === "org-a" || value === "org-b",
    );
    return candidate ?? "org-a";
  }
  private rows(kind: string): readonly Record<string, unknown>[] {
    return rowsByTenant[this.tenant()][kind] ?? [];
  }
}

class TenantDb implements D1DatabaseLike {
  readonly queries: string[] = [];
  constructor(
    private readonly role = "owner",
    private readonly projectIds: readonly string[] = [],
  ) {}
  prepare(query: string): D1Statement {
    return new Statement(query, this.role, this.projectIds, this.queries);
  }
  async batch(): Promise<readonly { success: boolean }[]> {
    return [];
  }
}

function environment(
  organizationId: Tenant,
  options: { role?: string; projectIds?: readonly string[] } = {},
) {
  return {
    CONCLAVE_ENVIRONMENT: "production",
    CONCLAVE_ACCESS_ORGANIZATION_ID: organizationId,
    CONCLAVE_DB: new TenantDb(options.role, options.projectIds),
  } as unknown as Env;
}

async function snapshot(organizationId: Tenant) {
  const response = await worker.fetch(
    new Request("https://conclave.test/api/studio/snapshot", {
      headers: { accept: "application/json" },
    }),
    environment(organizationId),
    {
      access: {
        getIdentity: async () => ({
          email: `${organizationId}-user@example.com`,
        }),
      },
    } as never,
  );
  expect(response.status).toBe(200);
  return response.json() as Promise<{
    activeRunId: string | null;
    projects: readonly { id: string }[];
    workers: readonly { id: string }[];
    tasks: readonly { id: string }[];
    findings: readonly { id: string }[];
    events: readonly { detail: string }[];
    artifacts: readonly { name: string }[];
    modelCalls: readonly { worker: string }[];
    plugins: readonly { id: string }[];
  }>;
}

describe("Studio tenant isolation", () => {
  it("does not expose another organization's workers or run data", async () => {
    const a = await snapshot("org-a");
    const b = await snapshot("org-b");

    expect(a.projects.map((row) => row.id)).toEqual(["project-a"]);
    expect(a.workers.map((row) => row.id)).toEqual(["worker-a"]);
    expect(a.tasks.map((row) => row.id)).toEqual(["task-a"]);
    expect(a.findings.map((row) => row.id)).toEqual(["finding-a"]);
    expect(a.events.map((row) => row.detail)).toEqual(["run-a"]);
    expect(a.plugins.map((row) => row.id)).toEqual(["plugin-a"]);
    expect(a.artifacts.map((row) => row.name)).toEqual(["artifact-a"]);
    expect(a.modelCalls.map((row) => row.worker)).toEqual(["worker-a"]);
    expect(a.activeRunId).toBe("run-a");

    expect(b.projects.map((row) => row.id)).toEqual(["project-b"]);
    expect(b.workers.map((row) => row.id)).toEqual(["worker-b"]);
    expect(b.tasks.map((row) => row.id)).toEqual(["task-b"]);
    expect(b.findings.map((row) => row.id)).toEqual(["finding-b"]);
    expect(b.events.map((row) => row.detail)).toEqual(["run-b"]);
    // Plugin catalog entries are global registry resources. They must remain
    // visible before a tenant creates its first Worker; tenant-owned Worker
    // data is still scoped independently below.
    expect(b.plugins.map((row) => row.id)).toEqual(["plugin-a"]);
    expect(b.artifacts.map((row) => row.name)).toEqual(["artifact-b"]);
    expect(b.modelCalls.map((row) => row.worker)).toEqual(["worker-b"]);
    expect(b.activeRunId).toBe("run-b");
  });

  it("applies project memberships to the workspace-wide snapshot", async () => {
    const db = new TenantDb("member", ["project-a"]);
    const env = {
      CONCLAVE_ENVIRONMENT: "production",
      CONCLAVE_ACCESS_ORGANIZATION_ID: "org-a",
      CONCLAVE_DB: db,
    } as unknown as Env;
    const response = await worker.fetch(
      new Request("https://conclave.test/api/studio/snapshot", {
        headers: { accept: "application/json" },
      }),
      env,
      {
        access: {
          getIdentity: async () => ({ email: "org-a-user@example.com" }),
        },
      } as never,
    );

    expect(response.status).toBe(200);
    const scopedQueries = db.queries.filter(
      (query) =>
        query.includes("FROM projects p") ||
        query.includes("FROM tasks t") ||
        query.includes("FROM findings f") ||
        query.includes("FROM events e") ||
        query.includes("FROM artifacts a") ||
        query.includes("FROM model_calls mc") ||
        query.includes("FROM chats c"),
    );
    expect(scopedQueries.length).toBeGreaterThan(0);
    expect(scopedQueries.every((query) => query.includes("IN ("))).toBe(true);
  });
});
