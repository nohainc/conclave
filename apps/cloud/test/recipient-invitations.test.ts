import { describe, expect, it } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import {
  handleListCurrentUserInvitations,
  handleAcceptProjectInvitation,
  handleDeclineProjectInvitation,
} from "../src/routes/handlers.js";
import worker from "../src/index.js";

describe("Recipient Invitations API", () => {
  function createTestEnv() {
    const { sqlite, db } = sqliteD1();
    const now = new Date().toISOString();

    // Seed users
    sqlite.exec(`
      INSERT INTO users (id, email, display_name, status, created_at, updated_at)
      VALUES 
        ('user-vitalii', 'vitalii@nohainc.com', 'Vitalii Noha', 'active', '${now}', '${now}'),
        ('user-ulikoss', 'ulikossnokia@gmail.com', 'Ulikoss Nokia', 'active', '${now}', '${now}'),
        ('user-other', 'other@example.com', 'Other Person', 'active', '${now}', '${now}');
    `);

    // Seed project owned by vitalii
    sqlite.exec(`
      INSERT INTO projects (id, name, owner_user_id, created_at, updated_at)
      VALUES ('proj-1', 'Conclave AX Development', 'user-vitalii', '${now}', '${now}');
      INSERT INTO project_memberships (id, project_id, user_id, role, created_at, updated_at)
      VALUES ('pm-1', 'proj-1', 'user-vitalii', 'owner', '${now}', '${now}');
    `);

    const env = {
      CONCLAVE_ENVIRONMENT: "development",
      CONCLAVE_DB: db,
      TEST_AUTHENTICATION: async (req: Request) => {
        const authHeader = req.headers.get("authorization");
        if (authHeader === "Bearer ulikoss") {
          return {
            userId: "user-ulikoss",
            user: {
              id: "user-ulikoss",
              email: "ulikossnokia@gmail.com",
              displayName: "Ulikoss Nokia",
              status: "active",
            },
            workspaceId: "",
            projectRoles: {},
            sessionId: "sess-ulikoss",
            clientType: "web",
          };
        }
        if (authHeader === "Bearer vitalii") {
          return {
            userId: "user-vitalii",
            user: {
              id: "user-vitalii",
              email: "vitalii@nohainc.com",
              displayName: "Vitalii Noha",
              status: "active",
            },
            workspaceId: "",
            projectRoles: { "proj-1": "owner" },
            sessionId: "sess-vitalii",
            clientType: "web",
          };
        }
        return {
          userId: "user-other",
          user: {
            id: "user-other",
            email: "other@example.com",
            displayName: "Other Person",
            status: "active",
          },
          workspaceId: "",
          projectRoles: {},
          sessionId: "sess-other",
          clientType: "web",
        };
      },
    };

    return { sqlite, db, env };
  }

  describe("GET /api/me/invitations", () => {
    it("returns active pending invitations for authenticated recipient", async () => {
      const { sqlite, env } = createTestEnv();
      const future = new Date(Date.now() + 86400000).toISOString();
      const past = new Date(Date.now() - 86400000).toISOString();

      // Active invitation to ulikoss
      sqlite.exec(`
        INSERT INTO project_invitations (id, project_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-1', 'proj-1', 'ulikossnokia@gmail.com', 'collaborator', 'hash-1', 'user-vitalii', 'pending', '${future}', '${future}', '${future}');
      `);

      // Expired invitation to ulikoss
      sqlite.exec(`
        INSERT INTO project_invitations (id, project_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-expired', 'proj-1', 'ulikossnokia@gmail.com', 'collaborator', 'hash-exp', 'user-vitalii', 'pending', '${past}', '${past}', '${past}');
      `);

      // Invitation to someone else
      sqlite.exec(`
        INSERT INTO project_invitations (id, project_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-other', 'proj-1', 'other@example.com', 'collaborator', 'hash-other', 'user-vitalii', 'pending', '${future}', '${future}', '${future}');
      `);

      const req = new Request("https://conclave.test/api/me/invitations", {
        headers: { authorization: "Bearer ulikoss" },
      });
      const res = await handleListCurrentUserInvitations(req, env as never);
      expect(res.status).toBe(200);

      const body = (await res.json()) as {
        invitations: Array<Record<string, unknown>>;
      };
      expect(body.invitations).toHaveLength(1);
      expect(body.invitations[0]).toMatchObject({
        id: "pinv-1",
        projectId: "proj-1",
        projectName: "Conclave AX Development",
        email: "ulikossnokia@gmail.com",
        role: "collaborator",
        status: "pending",
        invitedByUserId: "user-vitalii",
        invitedByUserName: "Vitalii Noha",
        invitedByUserEmail: "vitalii@nohainc.com",
      });
    });

    it("works via appRouter dispatch", async () => {
      const { sqlite, env } = createTestEnv();
      const future = new Date(Date.now() + 86400000).toISOString();

      sqlite.exec(`
        INSERT INTO project_invitations (id, project_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-router', 'proj-1', 'ulikossnokia@gmail.com', 'collaborator', 'hash-r', 'user-vitalii', 'pending', '${future}', '${future}', '${future}');
      `);

      const req = new Request("https://conclave.test/api/me/invitations", {
        headers: { authorization: "Bearer ulikoss" },
      });
      const res = await worker.fetch(req, env as never);
      expect(res.status).toBe(200);
      const body = (await res.json()) as { invitations: unknown[] };
      expect(body.invitations).toHaveLength(1);
    });
  });

  describe("POST /api/invitations/:id/accept", () => {
    it("atomically creates project membership and marks invitation accepted", async () => {
      const { sqlite, env } = createTestEnv();
      const future = new Date(Date.now() + 86400000).toISOString();

      sqlite.exec(`
        INSERT INTO project_invitations (id, project_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-accept-1', 'proj-1', 'ulikossnokia@gmail.com', 'collaborator', 'hash-acc', 'user-vitalii', 'pending', '${future}', '${future}', '${future}');
      `);

      const req = new Request(
        "https://conclave.test/api/invitations/pinv-accept-1/accept",
        {
          method: "POST",
          headers: { authorization: "Bearer ulikoss" },
        },
      );
      const res = await handleAcceptProjectInvitation(
        req,
        env as never,
        "pinv-accept-1",
      );
      expect(res.status).toBe(200);
      const body = (await res.json()) as Record<string, unknown>;
      expect(body).toMatchObject({
        id: "pinv-accept-1",
        projectId: "proj-1",
        role: "collaborator",
        status: "accepted",
        accepted: true,
      });

      // Verify DB membership was created
      const membership = sqlite
        .prepare(
          "SELECT user_id, project_id, role FROM project_memberships WHERE project_id = 'proj-1' AND user_id = 'user-ulikoss'",
        )
        .get() as { user_id: string; project_id: string; role: string };
      expect(membership).toEqual({
        user_id: "user-ulikoss",
        project_id: "proj-1",
        role: "collaborator",
      });

      // Verify invitation status updated
      const invitation = sqlite
        .prepare(
          "SELECT status, accepted_by_user_id FROM project_invitations WHERE id = 'pinv-accept-1'",
        )
        .get() as { status: string; accepted_by_user_id: string };
      expect(invitation.status).toBe("accepted");
      expect(invitation.accepted_by_user_id).toBe("user-ulikoss");
    });

    it("rejects acceptance by a different authenticated user", async () => {
      const { sqlite, env } = createTestEnv();
      const future = new Date(Date.now() + 86400000).toISOString();

      sqlite.exec(`
        INSERT INTO project_invitations (id, project_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-wrong', 'proj-1', 'ulikossnokia@gmail.com', 'collaborator', 'hash-w', 'user-vitalii', 'pending', '${future}', '${future}', '${future}');
      `);

      const req = new Request(
        "https://conclave.test/api/invitations/pinv-wrong/accept",
        {
          method: "POST",
          headers: { authorization: "Bearer other" },
        },
      );
      await expect(
        handleAcceptProjectInvitation(req, env as never, "pinv-wrong"),
      ).rejects.toThrow("Invitation email does not match signed-in user");
    });

    it("rejects acceptance of expired invitation", async () => {
      const { sqlite, env } = createTestEnv();
      const past = new Date(Date.now() - 86400000).toISOString();

      sqlite.exec(`
        INSERT INTO project_invitations (id, project_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-exp-acc', 'proj-1', 'ulikossnokia@gmail.com', 'collaborator', 'hash-ea', 'user-vitalii', 'pending', '${past}', '${past}', '${past}');
      `);

      const req = new Request(
        "https://conclave.test/api/invitations/pinv-exp-acc/accept",
        {
          method: "POST",
          headers: { authorization: "Bearer ulikoss" },
        },
      );
      await expect(
        handleAcceptProjectInvitation(req, env as never, "pinv-exp-acc"),
      ).rejects.toThrow("Project invitation expired");
    });
  });

  describe("POST /api/invitations/:id/decline", () => {
    it("marks invitation declined and records audit entry", async () => {
      const { sqlite, env } = createTestEnv();
      const future = new Date(Date.now() + 86400000).toISOString();

      sqlite.exec(`
        INSERT INTO project_invitations (id, project_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-dec-1', 'proj-1', 'ulikossnokia@gmail.com', 'collaborator', 'hash-dec', 'user-vitalii', 'pending', '${future}', '${future}', '${future}');
      `);

      const req = new Request(
        "https://conclave.test/api/invitations/pinv-dec-1/decline",
        {
          method: "POST",
          headers: { authorization: "Bearer ulikoss" },
        },
      );
      const res = await handleDeclineProjectInvitation(
        req,
        env as never,
        "pinv-dec-1",
      );
      expect(res.status).toBe(200);
      const body = (await res.json()) as Record<string, unknown>;
      expect(body).toMatchObject({
        id: "pinv-dec-1",
        projectId: "proj-1",
        status: "declined",
        declined: true,
      });

      // Verify DB status
      const invitation = sqlite
        .prepare("SELECT status FROM project_invitations WHERE id = 'pinv-dec-1'")
        .get() as { status: string };
      expect(invitation.status).toBe("declined");

      // Verify audit log
      const audit = sqlite
        .prepare(
          "SELECT action, target_id FROM project_audit_log WHERE action = 'project.invitation.declined'",
        )
        .get() as { action: string; target_id: string };
      expect(audit).toMatchObject({
        action: "project.invitation.declined",
        target_id: "pinv-dec-1",
      });
    });

    it("rejects decline by non-recipient user", async () => {
      const { sqlite, env } = createTestEnv();
      const future = new Date(Date.now() + 86400000).toISOString();

      sqlite.exec(`
        INSERT INTO project_invitations (id, project_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-dec-wrong', 'proj-1', 'ulikossnokia@gmail.com', 'collaborator', 'hash-dw', 'user-vitalii', 'pending', '${future}', '${future}', '${future}');
      `);

      const req = new Request(
        "https://conclave.test/api/invitations/pinv-dec-wrong/decline",
        {
          method: "POST",
          headers: { authorization: "Bearer other" },
        },
      );
      await expect(
        handleDeclineProjectInvitation(req, env as never, "pinv-dec-wrong"),
      ).rejects.toThrow("Invitation email does not match signed-in user");
    });
  });
});
