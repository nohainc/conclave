import type { SecurityEnv } from "./routes/handlers.js";

function escapeHtml(value: string): string {
  return value.replace(
    /[&<>"']/g,
    (character) =>
      ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;",
      })[character] ?? character,
  );
}

export function resolveAppUrl(request: Request, env: SecurityEnv): string {
  if (env.CONCLAVE_APP_URL && env.CONCLAVE_APP_URL.trim().length > 0) {
    return env.CONCLAVE_APP_URL.trim().replace(/\/+$/, "");
  }
  if (env.BETTER_AUTH_URL && env.BETTER_AUTH_URL.trim().length > 0) {
    return env.BETTER_AUTH_URL.trim().replace(/\/+$/, "");
  }
  try {
    const url = new URL(request.url);
    return `${url.protocol}//${url.host}`;
  } catch {
    return "https://conclaveax.com";
  }
}

export interface SendInvitationEmailParams {
  readonly recipientEmail: string;
  readonly inviterName: string;
  readonly spaceName: string;
  readonly role: string;
  readonly appUrl: string;
}

export async function sendSpaceInvitationEmail(
  env: SecurityEnv,
  params: SendInvitationEmailParams,
): Promise<boolean> {
  const { recipientEmail, inviterName, spaceName, role, appUrl } = params;
  const subject = `${inviterName} invited you to ${spaceName}`;
  const safeInviter = escapeHtml(inviterName);
  const safeSpace = escapeHtml(spaceName);
  const safeRole = escapeHtml(role);
  const safeAppUrl = escapeHtml(appUrl);
  const safeRecipient = escapeHtml(recipientEmail);

  if (!env.CONCLAVE_EMAIL) {
    if (
      env.CONCLAVE_ENVIRONMENT === "development" ||
      env.CONCLAVE_ENVIRONMENT === "test"
    ) {
      console.info("invitation.email.development", {
        recipientEmail,
        inviterName,
        spaceName,
        role,
        appUrl,
      });
      return true;
    }
    console.warn("CONCLAVE_EMAIL is not configured; invitation email skipped");
    return false;
  }

  try {
    await env.CONCLAVE_EMAIL.send({
      to: recipientEmail,
      from: {
        email: env.CONCLAVE_EMAIL_FROM ?? "auth@auth.earthuc.com",
        name: "Conclave AX",
      },
      subject,
      text: `Hi,\n\n${inviterName} invited you to join "${spaceName}" as a ${role} on Conclave AX.\n\nOpen Conclave AX to view and accept the invitation:\n${appUrl}\n\nSign in with ${recipientEmail} to accept. If you were not expecting this invitation, you can safely ignore this email.`,
      html: `<p>Hi,</p><p><strong>${safeInviter}</strong> invited you to join <strong>${safeSpace}</strong> as a <strong>${safeRole}</strong> on Conclave AX.</p><p style="margin:20px 0;"><a href="${safeAppUrl}" style="display:inline-block;padding:10px 18px;background-color:#7c6cf0;color:#ffffff;text-decoration:none;border-radius:6px;font-weight:600;font-size:14px;">View invitation</a></p><p style="font-size:12px;color:#666;">Or copy and paste this URL into your browser:<br/><a href="${safeAppUrl}">${safeAppUrl}</a></p><p style="font-size:12px;color:#888;">Sign in with <strong>${safeRecipient}</strong> to accept. If you were not expecting this invitation, you can safely ignore this email.</p>`,
    });
    return true;
  } catch (error) {
    console.error("Failed to send invitation email", error);
    return false;
  }
}
