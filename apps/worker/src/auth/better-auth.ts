import { betterAuth } from "better-auth";

type SocialProviderCredentials = {
  clientId: string;
  clientSecret: string;
  scope: string[];
};

export type BetterAuthRuntimeEnv = Pick<Env, "CONCLAVE_DB"> & {
  CONCLAVE_ENVIRONMENT: string;
  BETTER_AUTH_SECRET?: string;
  BETTER_AUTH_URL?: string;
  BETTER_AUTH_TRUSTED_ORIGINS?: string;
  GITHUB_CLIENT_ID?: string;
  GITHUB_CLIENT_SECRET?: string;
  GOOGLE_CLIENT_ID?: string;
  GOOGLE_CLIENT_SECRET?: string;
};

function providerCredentials(
  clientId: string | undefined,
  clientSecret: string | undefined,
  scope: string[],
): SocialProviderCredentials | undefined {
  if (!clientId || !clientSecret) return undefined;
  return { clientId, clientSecret, scope };
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
    env.GITHUB_CLIENT_ID,
    env.GITHUB_CLIENT_SECRET,
    ["user:email"],
  );
  const google = providerCredentials(
    env.GOOGLE_CLIENT_ID,
    env.GOOGLE_CLIENT_SECRET,
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
    socialProviders: {
      ...(github ? { github } : {}),
      ...(google ? { google } : {}),
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
      useSecureCookies: env.CONCLAVE_ENVIRONMENT === "production",
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
    const response = await createBetterAuth(env).handler(authRequest);
    if (!response.ok) return response;
    const body = (await response.json()) as { url?: unknown };
    if (typeof body.url !== "string") {
      return new Response("Authentication provider did not return a redirect", {
        status: 502,
      });
    }
    return Response.redirect(body.url, 302);
  }

  return createBetterAuth(env).handler(request);
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
