import { betterAuth } from "better-auth";
import { passkey } from "@better-auth/passkey";
import {
  recordAuthAuditEvent,
  recordAuthMetric,
  safeAuthProvider,
} from "./observability.js";

type SocialProviderCredentials = {
  clientId: string;
  clientSecret: string;
  scope: string[];
};

export type BetterAuthRuntimeEnv = Pick<Env, "CONCLAVE_DB"> & {
  CONCLAVE_ENVIRONMENT: string;
  CONCLAVE_E2E?: string;
  BETTER_AUTH_SECRET?: string;
  BETTER_AUTH_URL?: string;
  BETTER_AUTH_TRUSTED_ORIGINS?: string;
  BETTER_AUTH_RP_ID?: string;
  BETTER_AUTH_ORIGIN?: string;
  CONCLAVE_EMAIL?: SendEmail;
  CONCLAVE_EMAIL_FROM?: string;
  CONCLAVE_AUTH_GITHUB_CLIENT_ID?: string;
  CONCLAVE_AUTH_GITHUB_CLIENT_SECRET?: string;
  CONCLAVE_AUTH_GOOGLE_CLIENT_ID?: string;
  CONCLAVE_AUTH_GOOGLE_CLIENT_SECRET?: string;
};

function providerCredentials(
  clientId: string | undefined,
  clientSecret: string | undefined,
  scope: string[],
): SocialProviderCredentials | undefined {
  if (!clientId || !clientSecret) return undefined;
  return { clientId, clientSecret, scope };
}

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

async function sendAuthEmail(
  env: BetterAuthRuntimeEnv,
  user: { email: string; name?: string | null },
  url: string,
  subject: string,
  action: string,
): Promise<void> {
  if (!env.CONCLAVE_EMAIL) {
    if (env.CONCLAVE_ENVIRONMENT === "development") {
      console.info("auth.email.development", {
        action,
        email: user.email,
        url,
      });
      return;
    }
    throw new Error("CONCLAVE_EMAIL is required for authentication emails");
  }

  const safeUrl = escapeHtml(url);
  const safeName = escapeHtml(user.name?.trim() || "there");
  await env.CONCLAVE_EMAIL.send({
    to: user.email,
    from: {
      email: env.CONCLAVE_EMAIL_FROM ?? "auth@auth.earthuc.com",
      name: "Conclave AX",
    },
    subject,
    text: `Hi ${user.name?.trim() || "there"},\n\n${action}: ${url}\n\nIf you did not request this, you can ignore this email.`,
    html: `<p>Hi ${safeName},</p><p>${action}:</p><p><a href="${safeUrl}">${safeUrl}</a></p><p>If you did not request this, you can ignore this email.</p>`,
  });
}

/**
 * Build the Better Auth instance for one Worker request.
 *
 * Better Auth is intentionally confined to this module. The rest of Cloud
 * consumes IdentityService instead of importing Better Auth APIs.
 */
export function createBetterAuth(env: BetterAuthRuntimeEnv) {
  return betterAuth(buildBetterAuthOptions(env));
}

export function buildBetterAuthOptions(env: BetterAuthRuntimeEnv) {
  if (!env.BETTER_AUTH_SECRET) {
    throw new Error("BETTER_AUTH_SECRET is required to use Better Auth");
  }

  const github = providerCredentials(
    env.CONCLAVE_AUTH_GITHUB_CLIENT_ID,
    env.CONCLAVE_AUTH_GITHUB_CLIENT_SECRET,
    ["user:email"],
  );
  const google = providerCredentials(
    env.CONCLAVE_AUTH_GOOGLE_CLIENT_ID,
    env.CONCLAVE_AUTH_GOOGLE_CLIENT_SECRET,
    ["email", "profile"],
  );
  const trustedOrigins = [
    "https://app.conclaveax.com",
    "http://localhost:3000",
    "http://localhost:8080",
    "http://localhost:8787",
    "http://127.0.0.1:3000",
    "http://127.0.0.1:8080",
    "http://127.0.0.1:8787",
    ...(env.BETTER_AUTH_URL ? [new URL(env.BETTER_AUTH_URL).origin] : []),
    ...(env.BETTER_AUTH_TRUSTED_ORIGINS?.split(",") ?? []),
  ]
    .map((origin) => origin.trim().replace(/\/$/, ""))
    .filter(
      (origin, index, origins) =>
        origin.length > 0 && origins.indexOf(origin) === index,
    );

  const passkeyOptions = {
    rpID: env.BETTER_AUTH_RP_ID,
    rpName: "Conclave",
    origin: env.BETTER_AUTH_ORIGIN,
    schema: {
      passkey: {
        modelName: "passkeys",
        fields: {
          publicKey: "public_key",
          userId: "user_id",
          credentialID: "credential_id",
          deviceType: "device_type",
          backedUp: "backed_up",
          createdAt: "created_at",
        },
      },
    },
    authentication: {
      afterVerification: async ({
        clientData,
      }: {
        clientData: { id?: string };
      }) => {
        const credentialId = clientData.id;
        if (!credentialId) return;
        await env.CONCLAVE_DB.prepare(
          `INSERT INTO auth_step_up_events
             (id, user_id, method, created_at)
           SELECT ?1, user_id, 'passkey', ?2
           FROM passkeys WHERE credential_id = ?3`,
        )
          .bind(crypto.randomUUID(), new Date().toISOString(), credentialId)
          .run();
      },
    },
  };

  const requestFromContext = (context: unknown): Request | undefined => {
    if (!context || typeof context !== "object") return undefined;
    const request = (context as { request?: unknown }).request;
    return request instanceof Request ? request : undefined;
  };
  const providerFromContext = (context: unknown): string | undefined => {
    const request = requestFromContext(context);
    if (!request) return undefined;
    const path = new URL(request.url).pathname;
    const match = path.match(
      /(?:sign-in|callback|link-social)\/(github|google|passkey)/,
    );
    return safeAuthProvider(match?.[1]);
  };

  return {
    database: env.CONCLAVE_DB,
    secret: env.BETTER_AUTH_SECRET,
    baseURL: env.BETTER_AUTH_URL,
    user: {
      modelName: "users",
      fields: {
        name: "display_name",
        image: "avatar_url",
        emailVerified: "email_verified",
        createdAt: "created_at",
        updatedAt: "updated_at",
      },
    },
    account: {
      modelName: "auth_accounts",
      fields: {
        userId: "user_id",
        accountId: "account_id",
        providerId: "provider_id",
        accessToken: "access_token",
        refreshToken: "refresh_token",
        idToken: "id_token",
        accessTokenExpiresAt: "access_token_expires_at",
        refreshTokenExpiresAt: "refresh_token_expires_at",
        createdAt: "created_at",
        updatedAt: "updated_at",
      },
      encryptOAuthTokens: true,
      accountLinking: {
        enabled: true,
        disableImplicitLinking: true,
        trustedProviders: ["github", "google"],
        allowDifferentEmails: false,
      },
    },
    verification: {
      modelName: "auth_verifications",
      fields: {
        expiresAt: "expires_at",
        createdAt: "created_at",
        updatedAt: "updated_at",
      },
    },
    emailVerification: {
      sendVerificationEmail: async ({
        user,
        url,
      }: {
        user: { email: string; name?: string | null };
        url: string;
      }) =>
        sendAuthEmail(
          env,
          user,
          url,
          "Verify your Conclave AX email address",
          "Verify your email address",
        ),
      expiresIn: 60 * 60,
    },
    emailAndPassword: {
      enabled: true,
      disableSignUp: false,
      minPasswordLength: 8,
      maxPasswordLength: 128,
      autoSignIn: true,
      revokeSessionsOnPasswordReset: true,
      resetPasswordTokenExpiresIn: 60 * 60,
      sendResetPassword: async ({
        user,
        url,
      }: {
        user: { email: string; name?: string | null };
        url: string;
      }) =>
        sendAuthEmail(
          env,
          user,
          url,
          "Reset your Conclave AX password",
          "Reset your password",
        ),
    },
    socialProviders: {
      ...(github ? { github } : {}),
      ...(google ? { google } : {}),
    },
    plugins: [passkey(passkeyOptions)],
    databaseHooks: {
      session: {
        create: {
          after: async (
            session: { userId: string; id: string },
            context: unknown,
          ) => {
            try {
              await recordAuthAuditEvent(env.CONCLAVE_DB, {
                action: "auth.sign_in",
                outcome: "success",
                userId: session.userId,
                sessionId: session.id,
                provider: providerFromContext(context),
              });
              recordAuthMetric(providerFromContext(context), "success");
            } catch {
              // Authentication must remain available if observability storage is unavailable.
            }
          },
        },
        delete: {
          after: async (session: { userId: string; id: string }) => {
            try {
              await recordAuthAuditEvent(env.CONCLAVE_DB, {
                action: "auth.session.revoked",
                outcome: "success",
                userId: session.userId,
                sessionId: session.id,
              });
            } catch {
              // Best-effort audit only.
            }
          },
        },
      },
    },
    session: {
      modelName: "auth_sessions",
      fields: {
        userId: "user_id",
        expiresAt: "expires_at",
        createdAt: "created_at",
        updatedAt: "updated_at",
        ipAddress: "ip_address",
        userAgent: "user_agent",
      },
      cookieCache: {
        enabled: false,
      },
      expiresIn: 60 * 60 * 24 * 14,
      updateAge: 60 * 60 * 24,
      disableSessionRefresh: false,
    },
    trustedOrigins,
    advanced: {
      ...(env.CONCLAVE_ENVIRONMENT === "development" &&
      env.CONCLAVE_E2E === "true"
        ? { database: { validateSchema: false } }
        : {}),
      useSecureCookies:
        env.CONCLAVE_ENVIRONMENT === "production" &&
        Boolean(env.BETTER_AUTH_URL?.startsWith("https://")),
      defaultCookieAttributes: {
        httpOnly: true,
        sameSite: "Lax" as const,
        path: "/",
      },
    },
  };
}

export async function handleBetterAuthRequest(
  request: Request,
  env: BetterAuthRuntimeEnv,
): Promise<Response> {
  let auth: ReturnType<typeof createBetterAuth>;
  try {
    auth = createBetterAuth(env);
  } catch {
    return new Response(
      JSON.stringify({
        error: "Authentication is not configured on this deployment",
        code: "auth_not_configured",
      }),
      {
        status: 503,
        headers: { "content-type": "application/json" },
      },
    );
  }
  const url = new URL(request.url);
  const socialSignIn = url.pathname.match(
    /^\/api\/auth\/sign-in\/(github|google)$/,
  );

  if (request.method === "GET" && socialSignIn?.[1]) {
    const callbackURL = safeAuthReturnTo(
      request,
      url.searchParams.get("returnTo"),
    );
    const errorCallbackURL = new URL("/login", request.url);
    errorCallbackURL.searchParams.set("returnTo", callbackURL);
    const authRequest = new Request(
      new URL("/api/auth/sign-in/social", request.url),
      {
        method: "POST",
        headers: {
          accept: "application/json",
          "content-type": "application/json",
          origin: request.headers.get("origin") ?? url.origin,
          ...(request.headers.get("cookie")
            ? { cookie: request.headers.get("cookie") as string }
            : {}),
        },
        body: JSON.stringify({
          provider: socialSignIn[1],
          callbackURL,
          errorCallbackURL: errorCallbackURL.toString(),
        }),
      },
    );
    const response = await auth.handler(authRequest);
    if (!response.ok) {
      recordAuthMetric(socialSignIn[1], "failure", "invalid_callback");
      return response;
    }
    const body = (await response.json()) as { url?: unknown };
    if (typeof body.url !== "string") {
      recordAuthMetric(socialSignIn[1], "failure", "invalid_callback");
      return new Response("Authentication provider did not return a redirect", {
        status: 502,
      });
    }
    recordAuthMetric(socialSignIn[1], "success");
    const redirect = new Response(null, {
      status: 302,
      headers: { location: body.url },
    });
    copySetCookieHeaders(response.headers, redirect.headers);
    return redirect;
  }

  const metadata = await requestMetadata(request);
  const before = await sessionSummary(request, env);
  const response = await auth.handler(request);
  const statusOutcome = response.status >= 400 ? "failure" : "success";
  if (metadata.signIn) {
    if (statusOutcome === "failure") {
      recordAuthMetric(metadata.provider, "failure", "invalid_credentials");
      await safeRecord(env, {
        action: "auth.sign_in_failure",
        outcome: "failure",
        provider: metadata.provider,
        reason: "invalid_credentials",
      });
    }
  } else if (before && statusOutcome === "success" && metadata.action) {
    await safeRecord(env, {
      action: metadata.action,
      outcome: "success",
      userId: before.userId,
      sessionId: before.sessionId,
      provider: metadata.provider,
    });
  }
  return response;
}

/** Preserve Better Auth's OAuth state/CSRF cookies across the redirect shim. */
export function copySetCookieHeaders(source: Headers, target: Headers): void {
  const getSetCookie = (source as Headers & { getSetCookie?: () => string[] })
    .getSetCookie;
  const cookies =
    typeof getSetCookie === "function"
      ? getSetCookie.call(source)
      : source.get("set-cookie")
        ? [source.get("set-cookie") as string]
        : [];
  for (const cookie of cookies) target.append("set-cookie", cookie);
}

type AuthRequestMetadata = {
  action?:
    | "auth.logout"
    | "auth.provider.linked"
    | "auth.provider.unlinked"
    | "auth.passkey.enrolled"
    | "auth.passkey.removed";
  provider?: string;
  signIn?: boolean;
};

async function requestMetadata(request: Request): Promise<AuthRequestMetadata> {
  const path = new URL(request.url).pathname;
  if (path.endsWith("/sign-out")) return { action: "auth.logout" };
  if (path.endsWith("/link-social")) {
    return {
      action: "auth.provider.linked",
      provider: await bodyProvider(request),
    };
  }
  if (path.endsWith("/unlink-account")) {
    return {
      action: "auth.provider.unlinked",
      provider: await bodyProvider(request),
    };
  }
  if (path.endsWith("/add-passkey"))
    return { action: "auth.passkey.enrolled", provider: "passkey" };
  if (path.endsWith("/delete-passkey"))
    return { action: "auth.passkey.removed", provider: "passkey" };
  if (path.endsWith("/sign-in/social") || path.endsWith("/sign-in/passkey")) {
    return { signIn: true, provider: await bodyProvider(request) };
  }
  return {};
}

async function bodyProvider(request: Request): Promise<string | undefined> {
  try {
    const body = (await request.clone().json()) as { provider?: unknown };
    return safeAuthProvider(body.provider);
  } catch {
    return undefined;
  }
}

async function sessionSummary(
  request: Request,
  env: BetterAuthRuntimeEnv,
): Promise<{ userId: string; sessionId: string } | undefined> {
  try {
    const session = await createBetterAuth(env).api.getSession({
      headers: request.headers,
    });
    if (!session?.user?.id || !session.session?.id) return undefined;
    return { userId: session.user.id, sessionId: session.session.id };
  } catch {
    return undefined;
  }
}

async function safeRecord(
  env: BetterAuthRuntimeEnv,
  event: Parameters<typeof recordAuthAuditEvent>[1],
): Promise<void> {
  try {
    await recordAuthAuditEvent(env.CONCLAVE_DB, event);
  } catch {
    // Do not turn a successful authentication or account operation into a 500.
  }
}

/** Keep OAuth callbacks on this Studio origin and prevent open redirects. */
export function safeAuthReturnTo(
  request: Request,
  value: string | null,
): string {
  if (!value) return "/";
  try {
    const candidate = new URL(value, request.url);
    const requestOrigin = new URL(request.url).origin;
    if (
      candidate.origin !== requestOrigin ||
      !candidate.pathname.startsWith("/") ||
      candidate.pathname.startsWith("/api/auth")
    ) {
      return "/";
    }
    return `${candidate.pathname}${candidate.search}${candidate.hash}`;
  } catch {
    return "/";
  }
}
