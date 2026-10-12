import type { SecurityEnv } from "./routes/handlers.js";
import { classifyEmailDeliveryFailure } from "./email/email-config.js";
import { sendTemplateEmail } from "./email/email-service.js";

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
      });
      return true;
    }
    console.warn("CONCLAVE_EMAIL is not configured; invitation email skipped");
  }

  try {
    const configuredOrigin = env.CONCLAVE_APP_URL ?? env.BETTER_AUTH_URL;
    const approvedOrigin = configuredOrigin
      ? new URL(configuredOrigin).origin
      : new URL(appUrl).origin;
    await sendTemplateEmail(env, {
      to: recipientEmail,
      templateId: "space.invitation.v1",
      input: {
        inviterName,
        spaceName,
        role,
        invitationUrl: appUrl,
        recipientEmail,
      },
      renderOptions: { approvedOrigins: [approvedOrigin] },
    });
    return true;
  } catch (error) {
    const failure = classifyEmailDeliveryFailure(error);
    console.error("Failed to send invitation email", {
      status: failure.status,
      providerCode: failure.providerCode,
    });
    return false;
  }
}
