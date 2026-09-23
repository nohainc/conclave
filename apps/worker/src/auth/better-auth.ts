import { betterAuth } from "better-auth";

type SocialProviderCredentials = {
  clientId: string;
  clientSecret: string;
};

export type BetterAuthRuntimeEnv = Pick<
  Env,
  "CONCLAVE_DB" | "CONCLAVE_ENVIRONMENT"
> & {
  BETTER_AUTH_SECRET?: string;
  BETTER_AUTH_URL?: string;
  GITHUB_CLIENT_ID?: string;
  GITHUB_CLIENT_SECRET?: string;
  GOOGLE_CLIENT_ID?: string;
  GOOGLE_CLIENT_SECRET?: string;
};

function providerCredentials(
  clientId: string | undefined,
  clientSecret: string | undefined,
): SocialProviderCredentials | undefined {
  if (!clientId || !clientSecret) return undefined;
  return { clientId, clientSecret };
}

/**
 * Build the Better Auth instance for one Worker request.
 *
 * Better Auth is intentionally confined to this module. The rest of Cloud
 * consumes IdentityService instead of importing Better Auth APIs.
 */
export function createBetterAuth(env: BetterAuthRuntimeEnv) {
  if (!env.BETTER_AUTH_SECRET) {
    throw new Error("BETTER_AUTH_SECRET is required to use Better Auth");
  }

  const github = providerCredentials(
    env.GITHUB_CLIENT_ID,
    env.GITHUB_CLIENT_SECRET,
  );
  const google = providerCredentials(
    env.GOOGLE_CLIENT_ID,
    env.GOOGLE_CLIENT_SECRET,
  );

  return betterAuth({
    database: env.CONCLAVE_DB,
    secret: env.BETTER_AUTH_SECRET,
    baseURL: env.BETTER_AUTH_URL,
    socialProviders: {
      ...(github ? { github } : {}),
      ...(google ? { google } : {}),
    },
    session: {
      cookieCache: {
        enabled: false,
      },
    },
  });
}

export async function handleBetterAuthRequest(
  request: Request,
  env: BetterAuthRuntimeEnv,
): Promise<Response> {
  return createBetterAuth(env).handler(request);
}
