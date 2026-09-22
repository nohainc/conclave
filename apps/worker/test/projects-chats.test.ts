import { describe, expect, it, beforeEach } from "vitest";
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import worker, { requireSameOriginForCookieMutation } from "../src/index.js";
import { hashToken } from "../../../packages/security/src/index.js";
import type {
  Workspace,
  Project,
  Chat,
  ChatMessage,
} from "../../../packages/core/src/index.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const migrationsPath = path.resolve(__dirname, "../migrations");

function createD1Mock(db: DatabaseSync) {
  return {
    prepare(query: string) {
      let params: Array<string | number | bigint | null | Uint8Array> = [];
      const stmtObj = {
        bind(...args: unknown[]) {
          params = args as Array<string | number | bigint | null | Uint8Array>;
          return stmtObj;
        },
        async first<T = Record<string, unknown>>() {
          const stmt = db.prepare(query);
          const res = stmt.get(...params) as T | undefined;
          return res ?? null;
        },
        async all<T = Record<string, unknown>>() {
          const stmt = db.prepare(query);
          const res = stmt.all(...params) as T[];
          return { results: res };
        },
        async run() {
          const stmt = db.prepare(query);
          stmt.run(...params);
          return { success: true };
        },
      };
      return stmtObj;
    },
    async batch(statements: Array<{ run: () => Promise<unknown> }>) {
      for (const stmt of statements) {
        await stmt.run();
      }
    },
  };
}

describe("Projects and Chats API (Architecture v2)", () => {
  let db: DatabaseSync;
  let d1: ReturnType<typeof createD1Mock>;
  let mockEnv: Env;

  beforeEach(() => {
    db = new DatabaseSync(":memory:");
    db.exec("PRAGMA foreign_keys = ON;");
    for (const migration of fs
      .readdirSync(migrationsPath)
      .filter((file) => file.endsWith(".sql"))
      .sort()) {
      db.exec(fs.readFileSync(path.join(migrationsPath, migration), "utf8"));
    }
    d1 = createD1Mock(db);

    mockEnv = {
      CONCLAVE_ENVIRONMENT: "production",
      CONCLAVE_DB: d1,
      CONCLAVE_RUN_WORKFLOW: {
        create: async () => ({
          status: async () => ({ status: "running" }),
        }),
        get: async () => ({
          status: async () => ({ status: "running" }),
        }),
      },
    } as unknown as Env;
  });

  it("allows Access service-token requests through the cookie CSRF guard", () => {
    const request = new Request(
      "https://cloud.conclave.internal/api/workspaces",
      {
        method: "POST",
        headers: {
          cookie: "CF_Authorization=access-session",
          "cf-access-client-id": "publisher.example.access",
          "cf-access-client-secret": "service-secret",
        },
      },
    );

    expect(() => requireSameOriginForCookieMutation(request)).not.toThrow();
  });

  it("recognizes the Access service-token assertion forwarded to the Worker", () => {
    const payload = btoa(JSON.stringify({ common_name: "publisher.access" }));
    const request = new Request(
      "https://cloud.conclave.internal/api/workspaces",
      {
        method: "POST",
        headers: {
          cookie: "CF_Authorization=access-session",
          "cf-access-jwt-assertion": `header.${payload}.signature`,
        },
      },
    );

    expect(() => requireSameOriginForCookieMutation(request)).not.toThrow();
  });

  async function seedUserAndSession(userId: string, email: string) {
    const token = `tok_${userId}_${Math.random()}`;
    const tokenHash = await hashToken(token);
    const now = new Date().toISOString();
    const expiresAt = new Date(Date.now() + 86400000).toISOString();

    db.prepare(
      `INSERT INTO users (id, email, display_name, status, created_at, updated_at)
       VALUES (?, ?, ?, 'active', ?, ?)`,
    ).run(userId, email, `User ${userId}`, now, now);

    db.prepare(
      `INSERT INTO auth_sessions (id, user_id, token_hash, client_type, expires_at, created_at, updated_at)
       VALUES (?, ?, ?, 'desktop', ?, ?, ?)`,
    ).run(`sess-${userId}`, userId, tokenHash, expiresAt, now, now);

    return { token, userId };
  }

  it("handles Workspace creation and listing", async () => {
    const { token } = await seedUserAndSession(
      "user-alice",
      "alice@example.com",
    );

    const cookieMutation = await worker.fetch(
      new Request("https://cloud.conclave.internal/api/workspaces", {
        method: "POST",
        headers: {
          cookie: `conclave_session=${token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({ name: "Blocked Workspace" }),
      }),
      mockEnv,
    );
    expect(cookieMutation.status).toBe(403);

    const sameOriginCookieMutation = await worker.fetch(
      new Request("https://cloud.conclave.internal/api/workspaces", {
        method: "POST",
        headers: {
          cookie: `conclave_session=${token}`,
          origin: "https://cloud.conclave.internal",
          "content-type": "application/json",
        },
        body: JSON.stringify({ name: "Cookie Workspace" }),
      }),
      mockEnv,
    );
    expect(sameOriginCookieMutation.status).toBe(201);

    // 1. Create a workspace
    const createReq = new Request(
      "https://cloud.conclave.internal/api/workspaces",
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${token}`,
        },
        body: JSON.stringify({ name: "Alice Workspace", slug: "alice-ws" }),
      },
    );
    const createRes = await worker.fetch(createReq, mockEnv);
    expect(createRes.status).toBe(201);
    const createData = (await createRes.json()) as {
      workspace: Workspace & { role: string };
    };
    expect(createData.workspace.name).toBe("Alice Workspace");
    expect(createData.workspace.role).toBe("owner");

    const wsId = createData.workspace.id;

    // 2. List workspaces for Alice
    const listReq = new Request(
      "https://cloud.conclave.internal/api/workspaces",
      {
        method: "GET",
        headers: { authorization: `Bearer ${token}` },
      },
    );
    const listRes = await worker.fetch(listReq, mockEnv);
    expect(listRes.status).toBe(200);
    const listData = (await listRes.json()) as {
      workspaces: readonly Workspace[];
    };
    expect(listData.workspaces).toHaveLength(2);
    expect(listData.workspaces.map((workspace) => workspace.id)).toContain(
      wsId,
    );

    // 3. Get workspace by ID
    const getReq = new Request(
      `https://cloud.conclave.internal/api/workspaces/${wsId}`,
      {
        method: "GET",
        headers: { authorization: `Bearer ${token}` },
      },
    );
    const getRes = await worker.fetch(getReq, mockEnv);
    expect(getRes.status).toBe(200);
    const getData = (await getRes.json()) as { workspace: Workspace };
    expect(getData.workspace.slug).toBe("alice-ws");
  });

  it("exposes the authenticated session and revokes it on logout", async () => {
    const { token } = await seedUserAndSession(
      "user-session",
      "session@example.com",
    );
    const now = new Date().toISOString();
    db.prepare(
      `INSERT INTO workspaces (id, name, slug, created_at, updated_at)
       VALUES ('workspace-session', 'Session Workspace', 'session-workspace', ?, ?)`,
    ).run(now, now);
    db.prepare(
      `INSERT INTO workspace_memberships (id, workspace_id, user_id, role, created_at, updated_at)
       VALUES ('membership-session', 'workspace-session', 'user-session', 'owner', ?, ?)`,
    ).run(now, now);

    const session = await worker.fetch(
      new Request("https://cloud.conclave.internal/api/session", {
        headers: { cookie: `conclave_session=${token}` },
      }),
      mockEnv,
    );
    expect(session.status).toBe(200);
    const sessionBody = (await session.json()) as Record<string, unknown>;
    expect(sessionBody.authenticated).toBe(true);

    const logout = await worker.fetch(
      new Request("https://cloud.conclave.internal/api/session/logout", {
        method: "POST",
        headers: {
          cookie: `conclave_session=${token}`,
          origin: "https://cloud.conclave.internal",
        },
      }),
      mockEnv,
    );
    expect(logout.status).toBe(200);
    expect(logout.headers.get("set-cookie")).toContain("Max-Age=0");

    const afterLogout = await worker.fetch(
      new Request("https://cloud.conclave.internal/api/session", {
        headers: { cookie: `conclave_session=${token}` },
      }),
      mockEnv,
    );
    expect(afterLogout.status).toBe(401);
  });

  it("handles Project CRUD and scoping within a Workspace", async () => {
    const { token } = await seedUserAndSession("user-bob", "bob@example.com");

    // Create workspace
    const wsRes = await worker.fetch(
      new Request("https://cloud.conclave.internal/api/workspaces", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${token}`,
        },
        body: JSON.stringify({ name: "Bob WS", slug: "bob-ws" }),
      }),
      mockEnv,
    );
    const { workspace } = (await wsRes.json()) as { workspace: Workspace };

    // Create project
    const projRes = await worker.fetch(
      new Request("https://cloud.conclave.internal/api/projects", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${token}`,
          "x-conclave-workspace-id": workspace.id,
        },
        body: JSON.stringify({
          name: "Mobile App",
          description: "Flutter iOS and Android",
          repositoryId: "repo-flutter",
          settings: { env: "staging" },
        }),
      }),
      mockEnv,
    );
    expect(projRes.status).toBe(201);
    const { project } = (await projRes.json()) as { project: Project };
    expect(project.name).toBe("Mobile App");
    expect(project.workspaceId).toBe(workspace.id);

    // List projects
    const listRes = await worker.fetch(
      new Request("https://cloud.conclave.internal/api/projects", {
        method: "GET",
        headers: {
          authorization: `Bearer ${token}`,
          "x-conclave-workspace-id": workspace.id,
        },
      }),
      mockEnv,
    );
    expect(listRes.status).toBe(200);
    const { projects } = (await listRes.json()) as {
      projects: readonly Project[];
    };
    expect(projects).toHaveLength(1);
    expect(projects[0]!.id).toBe(project.id);
    expect(projects[0]!.settings).toEqual({ env: "staging" });

    // Get single project
    const getRes = await worker.fetch(
      new Request(
        `https://cloud.conclave.internal/api/projects/${project.id}`,
        {
          method: "GET",
          headers: {
            authorization: `Bearer ${token}`,
            "x-conclave-workspace-id": workspace.id,
          },
        },
      ),
      mockEnv,
    );
    expect(getRes.status).toBe(200);
    const getProjectData = (await getRes.json()) as { project: Project };
    expect(getProjectData.project.id).toBe(project.id);
  });

  it("supports multi-turn conversation and multiple goals inside a single Chat", async () => {
    const { token } = await seedUserAndSession(
      "user-carol",
      "carol@example.com",
    );

    // 1. Create Workspace and Project
    const wsRes = await worker.fetch(
      new Request("https://cloud.conclave.internal/api/workspaces", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${token}`,
        },
        body: JSON.stringify({ name: "Carol WS" }),
      }),
      mockEnv,
    );
    const { workspace } = (await wsRes.json()) as { workspace: Workspace };

    const projRes = await worker.fetch(
      new Request("https://cloud.conclave.internal/api/projects", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${token}`,
          "x-conclave-workspace-id": workspace.id,
        },
        body: JSON.stringify({ name: "Analytics Engine" }),
      }),
      mockEnv,
    );
    const { project } = (await projRes.json()) as { project: Project };

    // 2. Create Chat in the Project
    const chatRes = await worker.fetch(
      new Request(
        `https://cloud.conclave.internal/api/projects/${project.id}/chats`,
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            authorization: `Bearer ${token}`,
            "x-conclave-workspace-id": workspace.id,
          },
          body: JSON.stringify({
            title: "Architecture & Implementation Planning",
          }),
        },
      ),
      mockEnv,
    );
    expect(chatRes.status).toBe(201);
    const { chat } = (await chatRes.json()) as { chat: Chat };
    expect(chat.title).toBe("Architecture & Implementation Planning");
    expect(chat.projectId).toBe(project.id);

    // 3. User sends Message 1: "Research architecture."
    const msg1Res = await worker.fetch(
      new Request(
        `https://cloud.conclave.internal/api/chats/${chat.id}/messages`,
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            authorization: `Bearer ${token}`,
            "x-conclave-workspace-id": workspace.id,
          },
          body: JSON.stringify({
            content: "Research architecture for the analytics stream.",
            senderType: "user",
            kind: "user",
          }),
        },
      ),
      mockEnv,
    );
    expect(msg1Res.status).toBe(201);

    // 4. Create Goal A ("Research architecture") linked to Chat
    const goal1Res = await worker.fetch(
      new Request("https://cloud.conclave.internal/api/goals", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${token}`,
          "x-conclave-workspace-id": workspace.id,
        },
        body: JSON.stringify({
          projectId: project.id,
          chatId: chat.id,
          objective: "Research streaming architectures",
          commitSha: "0123456789abcdef0123456789abcdef01234567",
        }),
      }),
      mockEnv,
    );
    expect(goal1Res.status).toBe(202);
    const goal1Data = (await goal1Res.json()) as {
      goalId: string;
      runId: string;
      chatId?: string;
    };
    expect(goal1Data.chatId).toBe(chat.id);

    // 5. User sends Message 2: "Use option B."
    await worker.fetch(
      new Request(
        `https://cloud.conclave.internal/api/chats/${chat.id}/messages`,
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            authorization: `Bearer ${token}`,
            "x-conclave-workspace-id": workspace.id,
          },
          body: JSON.stringify({ content: "Use option B." }),
        },
      ),
      mockEnv,
    );

    // 6. User sends Message 3: "Implement it."
    await worker.fetch(
      new Request(
        `https://cloud.conclave.internal/api/chats/${chat.id}/messages`,
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            authorization: `Bearer ${token}`,
            "x-conclave-workspace-id": workspace.id,
          },
          body: JSON.stringify({ content: "Implement it." }),
        },
      ),
      mockEnv,
    );

    // 7. Create Goal B ("Implement option B") linked to the SAME Chat
    const goal2Res = await worker.fetch(
      new Request("https://cloud.conclave.internal/api/goals", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${token}`,
          "x-conclave-workspace-id": workspace.id,
        },
        body: JSON.stringify({
          projectId: project.id,
          chatId: chat.id,
          objective: "Implement stream processor option B",
          commitSha: "abcdef0123456789abcdef0123456789abcdef01",
        }),
      }),
      mockEnv,
    );
    expect(goal2Res.status).toBe(202);
    const goal2Data = (await goal2Res.json()) as {
      goalId: string;
      runId: string;
      chatId?: string;
    };

    // 8. Verify Chat Goals endpoint returns BOTH Goal A and Goal B
    const chatGoalsRes = await worker.fetch(
      new Request(
        `https://cloud.conclave.internal/api/chats/${chat.id}/goals`,
        {
          method: "GET",
          headers: {
            authorization: `Bearer ${token}`,
            "x-conclave-workspace-id": workspace.id,
          },
        },
      ),
      mockEnv,
    );
    expect(chatGoalsRes.status).toBe(200);
    const { goals } = (await chatGoalsRes.json()) as {
      goals: readonly { id: string }[];
    };
    expect(goals).toHaveLength(2);
    expect(goals[0]!.id).toBe(goal1Data.goalId);
    expect(goals[1]!.id).toBe(goal2Data.goalId);

    // 9. Verify Chat Messages endpoint returns all messages in chronological order
    const messagesRes = await worker.fetch(
      new Request(
        `https://cloud.conclave.internal/api/chats/${chat.id}/messages`,
        {
          method: "GET",
          headers: {
            authorization: `Bearer ${token}`,
            "x-conclave-workspace-id": workspace.id,
          },
        },
      ),
      mockEnv,
    );
    expect(messagesRes.status).toBe(200);
    const { messages } = (await messagesRes.json()) as {
      messages: readonly ChatMessage[];
    };
    // 3 user messages + 2 goal started status messages = 5
    expect(messages.length).toBeGreaterThanOrEqual(5);
    expect(messages[0]!.content).toContain("Research architecture");
  });

  it("enforces multi-tenancy: User from Workspace A cannot access Workspace B projects/chats", async () => {
    const userA = await seedUserAndSession("user-a", "usera@example.com");
    const userB = await seedUserAndSession("user-b", "userb@example.com");

    // User A creates workspace and project
    const wsARes = await worker.fetch(
      new Request("https://cloud.conclave.internal/api/workspaces", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${userA.token}`,
        },
        body: JSON.stringify({ name: "Workspace A" }),
      }),
      mockEnv,
    );
    const { workspace: wsA } = (await wsARes.json()) as {
      workspace: Workspace;
    };

    const projARes = await worker.fetch(
      new Request("https://cloud.conclave.internal/api/projects", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${userA.token}`,
          "x-conclave-workspace-id": wsA.id,
        },
        body: JSON.stringify({ name: "Project Secret A" }),
      }),
      mockEnv,
    );
    const { project: projA } = (await projARes.json()) as { project: Project };

    // User B creates workspace B
    const wsBRes = await worker.fetch(
      new Request("https://cloud.conclave.internal/api/workspaces", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${userB.token}`,
        },
        body: JSON.stringify({ name: "Workspace B" }),
      }),
      mockEnv,
    );
    const { workspace: wsB } = (await wsBRes.json()) as {
      workspace: Workspace;
    };

    // Even an owner of Workspace A cannot read Workspace B without membership.
    const ownerCrossWorkspaceRes = await worker.fetch(
      new Request(`https://cloud.conclave.internal/api/workspaces/${wsB.id}`, {
        method: "GET",
        headers: { authorization: `Bearer ${userA.token}` },
      }),
      mockEnv,
    );
    expect(ownerCrossWorkspaceRes.status).toBe(404);

    // A non-active membership must not grant workspace visibility.
    db.prepare(
      "INSERT INTO workspace_memberships (id, workspace_id, user_id, role, status, created_at, updated_at) VALUES (?, ?, ?, 'member', 'suspended', ?, ?)",
    ).run(
      `wm-suspended-${Date.now()}`,
      wsB.id,
      userA.userId,
      new Date().toISOString(),
      new Date().toISOString(),
    );
    const suspendedMemberRes = await worker.fetch(
      new Request(`https://cloud.conclave.internal/api/workspaces/${wsB.id}`, {
        method: "GET",
        headers: { authorization: `Bearer ${userA.token}` },
      }),
      mockEnv,
    );
    expect(suspendedMemberRes.status).toBe(404);

    // User B attempts to access Project A using Workspace B header -> forbidden/not found
    const getProjRes = await worker.fetch(
      new Request(`https://cloud.conclave.internal/api/projects/${projA.id}`, {
        method: "GET",
        headers: {
          authorization: `Bearer ${userB.token}`,
          "x-conclave-workspace-id": wsB.id,
        },
      }),
      mockEnv,
    );
    expect(getProjRes.status).toBe(404);

    // User B attempts to access Workspace A directly -> forbidden
    const getWsRes = await worker.fetch(
      new Request(`https://cloud.conclave.internal/api/workspaces/${wsA.id}`, {
        method: "GET",
        headers: {
          authorization: `Bearer ${userB.token}`,
          "x-conclave-workspace-id": wsA.id,
        },
      }),
      mockEnv,
    );
    expect([403, 404]).toContain(getWsRes.status);
  });
});
