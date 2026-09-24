import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const schemaPath = fileURLToPath(
  new URL("../migrations-v6/0001_conclave_v6.sql", import.meta.url),
);
const schema = readFileSync(schemaPath, "utf8");
const integrationSchema = readFileSync(
  fileURLToPath(new URL("../migrations-v6/0002_workstream_integrations.sql", import.meta.url)),
  "utf8",
);
const observabilitySchema = readFileSync(
  fileURLToPath(new URL("../migrations-v6/0003_usage_audit_observability.sql", import.meta.url)),
  "utf8",
);
const chatMigrationSchema = readFileSync(
  fileURLToPath(new URL("../migrations-v6/0004_chat_workstream_mapping.sql", import.meta.url)),
  "utf8",
);
const executionFoundationSchema = readFileSync(
  fileURLToPath(new URL("../migrations-v6/0005_execution_foundation.sql", import.meta.url)),
  "utf8",
);

function apply(sql: string): string {
  return execFileSync("sqlite3", ["-json", ":memory:"], {
    input: `${schema}\n${integrationSchema}\n${observabilitySchema}\n${chatMigrationSchema}\n${executionFoundationSchema}\n${sql}`,
    encoding: "utf8",
  });
}

const fixture = `
INSERT INTO users VALUES ('u1', 'owner@example.test', 'Owner', 'active', '2026-01-01', '2026-01-01');
INSERT INTO projects VALUES ('p1', 'u1', 'Project', NULL, NULL, '2026-01-01', '2026-01-01');
INSERT INTO project_memberships VALUES ('pm1', 'p1', 'u1', 'owner', '2026-01-01', '2026-01-01');
INSERT INTO execution_workspaces VALUES ('ws1', 'u1', 'Workspace', 'online', '2026-01-01', '2026-01-01');
INSERT INTO workspace_runtime_identities VALUES ('runtime1', 'ws1', 'key-ref', '2026-01-01', NULL);
INSERT INTO workers VALUES ('worker1', 'Worker', 'active', '2026-01-01', '2026-01-01');
INSERT INTO workstreams VALUES ('stream1', 'p1', 'Stream', 'active', '{}', 'u1', '2026-01-01', '2026-01-01');
INSERT INTO workstream_execution_policies VALUES ('stream1', 'stateful', 'ws1', 1, 1);
INSERT INTO workflow_definitions VALUES ('wf1', 'p1', 'Workflow', '', NULL, 'u1', '2026-01-01', '2026-01-01');
INSERT INTO workflow_versions VALUES ('wfv1', 'wf1', 1, 'u1', '2026-01-01');
INSERT INTO workflow_steps VALUES ('step1', 'wfv1', 'Implementation', 'implementation', '[]', 'stateful_workstream', 0, '[]', 'none', 1000, '{}');
INSERT INTO workstream_checkouts VALUES ('checkout1', 'stream1', 'ws1', 'repo1', 'abc', 'stream/one', 'ready', '2026-01-01', '2026-01-01');
INSERT INTO work_requests VALUES ('request1', 'stream1', 'u1', 'stateful', 'wf1', 'wfv1', '{}', 'queued', 'ws1', 'checkout1', '{}', '2026-01-01', '2026-01-01');
INSERT INTO workstream_execution_leases VALUES ('lease1', 'stream1', 'checkout1', 'request1', 'ws1', 1, 'active', '2026-01-01', '2026-01-02', NULL);
INSERT INTO workstream_checkpoints VALUES ('checkpoint1', 'stream1', 'checkout1', 1, 'abc', 'initial', 'request1', '2026-01-01');
INSERT INTO runs (id, project_id, workstream_id, work_request_id, workflow_version_id, checkout_id, execution_lease_id, status, created_at, updated_at)
  VALUES ('run1', 'p1', 'stream1', 'request1', 'wfv1', 'checkout1', 'lease1', 'running', '2026-01-01', '2026-01-01');
`;

describe("v6 D1 schema", () => {
  it("applies cleanly with foreign keys enabled", () => {
    const result = JSON.parse(
      apply(`${fixture}\nSELECT name FROM sqlite_master WHERE type = 'table';`),
    );
    expect(result).toEqual(
      expect.arrayContaining([
        { name: "workstreams" },
        { name: "work_requests" },
        { name: "runs" },
        { name: "workstream_integrations" },
        { name: "workstream_audit_log" },
        { name: "chat_workstream_migrations" },
      ]),
    );
  });

  it("enforces one active checkout and one active lease", () => {
    expect(() =>
      apply(
        `${fixture}\nINSERT INTO workstream_checkouts VALUES ('checkout2', 'stream1', 'ws1', 'repo1', 'def', 'stream/two', 'ready', '2026-01-01', '2026-01-01');`,
      ),
    ).toThrow();
    expect(() =>
      apply(
        `${fixture}\nINSERT INTO workstream_execution_leases VALUES ('lease2', 'stream1', 'checkout1', 'request1', 'ws1', 2, 'active', '2026-01-01', '2026-01-02', NULL);`,
      ),
    ).toThrow();
  });

  it("enforces checkpoint parents and foreign keys", () => {
    expect(() =>
      apply(
        `${fixture}\nINSERT INTO workstream_checkpoints VALUES ('checkpoint2', 'stream1', 'missing-checkout', 2, 'def', 'bad', 'request1', '2026-01-01');`,
      ),
    ).toThrow();
    expect(() =>
      apply(
        `${fixture}\nINSERT INTO workstream_checkpoints VALUES ('checkpoint2', 'missing-stream', 'checkout1', 2, 'def', 'bad', 'request1', '2026-01-01');`,
      ),
    ).toThrow();
  });
});
