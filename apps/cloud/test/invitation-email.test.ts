import { describe, expect, it, vi } from "vitest";
import {
  sendSpaceInvitationEmail,
  resolveAppUrl,
} from "../src/invitation-email.js";
import { handleCreateSpaceInvitation } from "../src/routes/spaces.js";
import { sqliteD1 } from "./helpers/sqlite-d1.js";

describe("Invitation Email Delivery", () => {
  it("resolves app URL from CONCLAVE_APP_URL, BETTER_AUTH_URL, or request URL", () => {
    const req = new Request(
      "https://conclave.internal/api/spaces/proj-1/invitations",
    );
    expect(
      resolveAppUrl(req, {
        CONCLAVE_APP_URL: "https://app.conclave.dev/",
      } as never),
    ).toBe("https://app.conclave.dev");
    expect(
      resolveAppUrl(req, {
        BETTER_AUTH_URL: "https://auth.conclave.dev/",
      } as never),
    ).toBe("https://auth.conclave.dev");
    expect(resolveAppUrl(req, {} as never)).toBe("https://conclave.internal");
  });

  it("sends formatted email via CONCLAVE_EMAIL binding", async () => {
    const sentEmails: Array<{
      to: string;
      from: { email: string; name: string };
      subject: string;
      text: string;
      html: string;
    }> = [];

    const mockEmail = {
      send: vi.fn(async (msg: unknown) => {
        sentEmails.push(msg as (typeof sentEmails)[0]);
      }),
    };

    const env = {
      CONCLAVE_EMAIL: mockEmail,
      CONCLAVE_EMAIL_FROM: "invitations@conclaveax.com",
    };

    const ok = await sendSpaceInvitationEmail(env as never, {
      recipientEmail: "ulikossnokia@gmail.com",
      inviterName: "Vitalii Noha",
      spaceName: "Conclave AX Development",
      role: "collaborator",
      appUrl: "https://app.conclave.dev/?invitation=pinv-123",
    });

    expect(ok).toBe(true);
    expect(mockEmail.send).toHaveBeenCalledOnce();
    const sent = sentEmails[0]!;
    expect(sent).toMatchObject({
      to: "ulikossnokia@gmail.com",
      from: {
        email: "invitations@conclaveax.com",
        name: "Conclave AX",
      },
      subject: "Vitalii Noha invited you to Conclave AX Development",
    });
    expect(sent.text).toContain(
      'Vitalii Noha invited you to join "Conclave AX Development" as a collaborator on Conclave AX.',
    );
    expect(sent.text).toContain(
      "https://app.conclave.dev/?invitation=pinv-123",
    );
    expect(sent.text).toContain(
      "Sign in with ulikossnokia@gmail.com to accept.",
    );
    expect(sent.html).toContain("<strong>Vitalii Noha</strong>");
    expect(sent.html).toContain("<strong>Conclave AX Development</strong>");
    expect(sent.html).toContain(
      'href="https://app.conclave.dev/?invitation=pinv-123"',
    );
  });

  it("escapes HTML in user inputs for security", async () => {
    const sentEmails: Array<{ html: string }> = [];
    const mockEmail = {
      send: vi.fn(async (msg: unknown) => {
        sentEmails.push(msg as (typeof sentEmails)[0]);
      }),
    };

    const env = {
      CONCLAVE_EMAIL: mockEmail,
    };

    await sendSpaceInvitationEmail(env as never, {
      recipientEmail: "malicious<script>@example.com",
      inviterName: "<script>alert('xss')</script>",
      spaceName: "Space <img src=x onerror=alert(1)>",
      role: "viewer",
      appUrl: "https://app.conclave.dev/?invitation=pinv-xss",
    });

    const sent = sentEmails[0]!;
    expect(sent.html).not.toContain("<script>");
    expect(sent.html).toContain(
      "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;",
    );
    expect(sent.html).toContain("Space &lt;img src=x onerror=alert(1)&gt;");
  });

  it("sends email and creates invitation on handleCreateSpaceInvitation", async () => {
    const { sqlite, db } = sqliteD1();
    const now = new Date().toISOString();

    sqlite.exec(`
      INSERT INTO users (id, email, display_name, status, created_at, updated_at)
      VALUES ('user-vitalii', 'vitalii@nohainc.com', 'Vitalii Noha', 'active', '${now}', '${now}');
      INSERT INTO spaces (id, name, owner_user_id, created_at, updated_at)
      VALUES ('proj-1', 'Conclave AX Development', 'user-vitalii', '${now}', '${now}');
      INSERT INTO space_memberships (id, space_id, user_id, role, created_at, updated_at)
      VALUES ('pm-1', 'proj-1', 'user-vitalii', 'owner', '${now}', '${now}');
    `);

    const sentEmails: unknown[] = [];
    const env = {
      CONCLAVE_ENVIRONMENT: "development",
      CONCLAVE_DB: db,
      CONCLAVE_APP_URL: "https://app.conclave.dev",
      CONCLAVE_EMAIL: {
        send: vi.fn(async (msg: unknown) => {
          sentEmails.push(msg);
        }),
      },
      TEST_AUTHENTICATION: async () => ({
        userId: "user-vitalii",
        user: {
          id: "user-vitalii",
          email: "vitalii@nohainc.com",
          displayName: "Vitalii Noha",
          status: "active",
        },
        workspaceId: "",
        spaceRoles: { "proj-1": "owner" },
        sessionId: "sess-vitalii",
        clientType: "web",
      }),
    };

    const req = new Request(
      "https://conclave.internal/api/spaces/proj-1/invitations",
      {
        method: "POST",
        headers: {
          authorization: "Bearer vitalii",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          email: "ulikossnokia@gmail.com",
          role: "collaborator",
        }),
      },
    );

    const res = await handleCreateSpaceInvitation(req, env as never, "proj-1");
    expect(res.status).toBe(201);
    expect(sentEmails).toHaveLength(1);
    expect(sentEmails[0]).toMatchObject({
      to: "ulikossnokia@gmail.com",
      subject: "Vitalii Noha invited you to Conclave AX Development",
    });
  });
});
