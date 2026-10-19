import { describe, expect, it } from "vitest";
import {
  createMockEmailTransport,
  sendRenderedEmail,
  sendTemplateEmail,
} from "../../src/email/email-service.js";
import {
  emailTemplateCatalog,
  renderEmail,
  renderEmailTemplate,
} from "../../src/email/templates/index.js";
import {
  EMAIL_PREVIEW_ORIGIN,
  emailPreviewFixtures,
} from "../../src/email/preview-fixtures.js";

describe("email template architecture", () => {
  it("keeps every initial template uniquely identified and renderable", () => {
    const ids = emailTemplateCatalog.map((template) => template.id);
    expect(new Set(ids).size).toBe(ids.length);
    expect(ids).toEqual([
      "auth.verify-email.v1",
      "auth.verify-email-code.v1",
      "auth.reset-password.v1",
      "auth.password-changed.v1",
      "auth.confirm-email-change.v1",
      "auth.email-changed.v1",
      "space.invitation.v1",
      "space.invitation-accepted.v1",
      "space.access-revoked.v1",
      "auth.welcome.v1",
      "auth.account-deleted.v1",
    ]);
  });

  it("provides synthetic fixtures for every catalog template", () => {
    for (const template of emailTemplateCatalog) {
      const rendered = renderEmail(
        template.id,
        emailPreviewFixtures[template.id],
        { approvedOrigins: [EMAIL_PREVIEW_ORIGIN] },
      );
      expect(rendered.templateId).toBe(template.id);
      expect(rendered.html).toContain("Conclave AX");
      expect(rendered.text).toContain("Conclave AX");
      expect(rendered.html).not.toContain("preview-secret");
    }
  });

  it("renders the supported auth and invitation events as HTML and text", () => {
    const cases = [
      renderEmailTemplate("auth.verify-email.v1", {
        recipientName: "Ada",
        verificationUrl: "https://app.conclaveax.com/verify?token=abc",
        expiresInMinutes: 60,
      }),
      renderEmailTemplate("auth.reset-password.v1", {
        recipientName: "Ada",
        resetUrl: "https://app.conclaveax.com/reset?token=abc",
        expiresInMinutes: 60,
      }),
      renderEmailTemplate("auth.confirm-email-change.v1", {
        recipientName: "Ada",
        newEmail: "ada@example.com",
        confirmationUrl: "https://app.conclaveax.com/change?token=abc",
        expiresInMinutes: 60,
      }),
      renderEmailTemplate("space.invitation.v1", {
        inviterName: "Grace",
        spaceName: "Research",
        role: "member",
        invitationUrl: "https://app.conclaveax.com/?invitation=abc",
        recipientEmail: "ada@example.com",
      }),
      renderEmailTemplate("space.invitation-accepted.v1", {
        recipientName: "Grace",
        memberName: "Ada",
        spaceName: "Research",
        role: "member",
      }),
      renderEmailTemplate("space.access-revoked.v1", {
        recipientName: "Ada",
        spaceName: "Research",
        reason: "Membership ended",
      }),
    ];

    for (const rendered of cases) {
      expect(rendered.subject.length).toBeGreaterThan(10);
      expect(rendered.html).toContain("<!doctype html>");
      expect(rendered.html).toContain("Conclave AX");
      expect(rendered.html).toContain("conclave_email_logo.png");
      expect(rendered.html).toContain(
        "@media only screen and (max-width:620px)",
      );
      expect(rendered.html).toContain("prefers-color-scheme:dark");
      expect(rendered.text).toContain("Conclave AX");
      expect(rendered.html.length).toBeGreaterThan(200);
      expect(rendered.text.length).toBeGreaterThan(40);
    }
    expect(cases[0]?.text).toContain("This link is valid for 60 minutes.");
    expect(cases[1]?.text).toContain("This link is valid for 60 minutes.");
    expect(cases[2]?.text).toContain("This link is valid for 60 minutes.");
    expect(cases[0]?.text).toContain("Verify email address:");
    expect(cases[1]?.text).toContain("Reset password:");
    expect(cases[2]?.text).toContain("Confirm email change:");
    expect(cases[1]?.text).toContain("If you did not request a password reset");
    expect(cases[3]?.text).toContain("Sign in with ada@example.com to accept");
  });

  it("escapes dynamic values in both output forms and rejects unsafe URLs", () => {
    const rendered = renderEmailTemplate("space.invitation.v1", {
      inviterName: "<script>alert(1)</script>",
      spaceName: 'R&D "private"',
      role: "member",
      invitationUrl: "https://app.conclaveax.com/?invitation=abc",
      recipientEmail: "person@example.com",
    });

    expect(rendered.html).not.toContain("<script>");
    expect(rendered.html).toContain("&lt;script&gt;");
    expect(rendered.html).toContain("R&amp;D &quot;private&quot;");
    expect(() =>
      renderEmailTemplate("auth.verify-email.v1", {
        verificationUrl: "javascript:alert(1)",
        expiresInMinutes: 60,
      }),
    ).toThrow("absolute http(s) URL");
  });

  it("does not invent a sender or delivery behavior", () => {
    const rendered = renderEmailTemplate("auth.welcome.v1", {
      recipientName: "Ada",
      appUrl: "https://app.conclaveax.com",
    });
    expect(rendered.html).not.toContain("auth@auth.earthuc.com");
    expect(rendered.html).not.toContain("CONCLAVE_EMAIL");
  });

  it("returns a versioned result with safe metadata and deterministic content", () => {
    const input = {
      recipientName: "Ada",
      verificationUrl: "https://app.conclaveax.com/verify?token=abc",
      expiresInMinutes: 60,
    } as const;
    const first = renderEmail("auth.verify-email.v1", input);
    const second = renderEmail("auth.verify-email.v1", input);

    expect(first).toEqual(second);
    expect(first.templateVersion).toBe(1);
    expect(first.metadata).toEqual({
      variant: "action-required",
      category: "essential",
    });
    expect(JSON.stringify(first.metadata)).not.toContain("token");
    expect(JSON.stringify(first.metadata)).not.toContain("app.conclaveax.com");
  });

  it("requires an approved application origin for action URLs", () => {
    expect(() =>
      renderEmail(
        "auth.verify-email.v1",
        {
          verificationUrl: "https://evil.example/verify",
          expiresInMinutes: 60,
        },
        { approvedOrigins: ["https://app.conclaveax.com"] },
      ),
    ).toThrow("origin is not approved");
  });

  it("rejects missing required event fields before rendering", () => {
    expect(() =>
      renderEmail("space.invitation.v1", {
        inviterName: "Grace",
        spaceName: "",
        role: "member",
        invitationUrl: "https://app.conclaveax.com/?invitation=abc",
        recipientEmail: "person@example.com",
      }),
    ).toThrow("spaceName is required");
  });

  it("renders completely before sending and never calls the binding on failure", async () => {
    let calls = 0;
    const env = {
      CONCLAVE_EMAIL: {
        send: async () => {
          calls += 1;
          return { messageId: "message-1" };
        },
      },
    };

    await expect(
      sendTemplateEmail(env, {
        to: "person@example.com",
        templateId: "auth.verify-email.v1",
        input: {
          verificationUrl: "javascript:alert(1)",
          expiresInMinutes: 60,
        },
      }),
    ).rejects.toThrow("absolute http(s) URL");
    expect(calls).toBe(0);

    const result = await sendTemplateEmail(env, {
      to: "person@example.com",
      templateId: "auth.verify-email.v1",
      input: {
        verificationUrl: "https://app.conclaveax.com/verify",
        expiresInMinutes: 60,
      },
    });
    expect(result.status).toBe("accepted");
    expect(calls).toBe(1);
  });

  it("supports an explicit mock transport without changing production delivery", async () => {
    const transport = createMockEmailTransport();
    const rendered = renderEmail("auth.welcome.v1", {
      recipientName: "Ada",
      appUrl: "https://app.conclaveax.com",
    });

    await sendRenderedEmail(
      {
        CONCLAVE_EMAIL: transport,
      },
      { to: "ada@example.com", rendered },
    );

    expect(transport.messages).toHaveLength(1);
    expect(transport.messages[0]).toMatchObject({
      to: "ada@example.com",
      subject: "Welcome to Conclave AX",
      from: { email: "conclave@conclaveax.com", name: "Conclave AX" },
    });
  });

  it("keeps security and action variants visually distinct while preserving text fallback", () => {
    const security = renderEmailTemplate("auth.password-changed.v1", {
      recipientName: "Ada",
      changedAt: "2026-10-12T08:00:00.000Z",
    });
    const action = renderEmailTemplate("auth.verify-email.v1", {
      recipientName: "Ada",
      verificationUrl: "https://app.conclaveax.com/verify?token=a&next=/home",
      expiresInMinutes: 60,
    });

    expect(security.html).toContain("#fff8eb");
    expect(action.html).toContain("If the button does not work");
    expect(action.text).toContain(
      "https://app.conclaveax.com/verify?token=a&next=/home",
    );
    expect(action.text).toContain(
      "If you did not create a Conclave AX account",
    );
    expect(action.text).toContain("This link is valid for 60 minutes.");
  });

  it("requires an accurate positive validity period for action links", () => {
    expect(() =>
      renderEmailTemplate("auth.verify-email.v1", {
        verificationUrl: "https://app.conclaveax.com/verify",
        expiresInMinutes: 0,
      }),
    ).toThrow("positive whole number of minutes");
    expect(() =>
      renderEmailTemplate("auth.reset-password.v1", {
        resetUrl: "https://app.conclaveax.com/reset",
        expiresInMinutes: 1.5,
      }),
    ).toThrow("positive whole number of minutes");
  });

  it("rejects oversized dynamic fields before producing a preview", () => {
    expect(() =>
      renderEmailTemplate("space.invitation.v1", {
        inviterName: "A".repeat(4097),
        spaceName: "Research",
        role: "member",
        invitationUrl: "https://app.conclaveax.com/?invitation=preview",
        recipientEmail: "ada@example.com",
      }),
    ).toThrow("at most 4096 characters");
  });

  it("keeps long translated content intact for natural client wrapping", () => {
    const longName = "A".repeat(600);
    const rendered = renderEmailTemplate("auth.welcome.v1", {
      recipientName: longName,
      appUrl: "https://app.conclaveax.com",
    });

    expect(rendered.text).toContain(longName);
    expect(rendered.html).toContain("word-break:break-word");
  });

  it("keeps representative preview layouts stable for narrow clients and missing images", () => {
    const rendered = renderEmailTemplate("space.invitation.v1", {
      inviterName: "Grace Hopper",
      spaceName: "Research ".repeat(120),
      role: "collaborator",
      invitationUrl: "https://app.conclaveax.com/?invitation=preview",
      recipientEmail: "ada@example.com",
    });
    expect(rendered.html).toContain("max-width:600px");
    expect(rendered.html).toContain("max-width:620px");
    expect(rendered.html).toContain('alt="Conclave AX"');
    expect(rendered.html).toContain('content="light dark"');
    expect(rendered.text).toContain("Research Research");
  });
});
