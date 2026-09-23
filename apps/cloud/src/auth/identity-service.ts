import { createBetterAuth, type BetterAuthRuntimeEnv } from "./better-auth.js";

export interface AuthenticatedIdentity {
  readonly userId: string;
  readonly email: string;
  readonly name: string;
  readonly sessionId: string;
}

interface AuthSessionReader {
  api: {
    getSession(input: { headers: Headers }): Promise<{
      user: {
        id: string;
        email: string;
        name: string;
      };
      session: {
        id: string;
      };
    } | null>;
  };
}

type AuthSessionReaderFactory = (
  env: BetterAuthRuntimeEnv,
) => AuthSessionReader;

/** Application-facing human identity boundary. */
export class IdentityService {
  constructor(
    private readonly authFactory: AuthSessionReaderFactory = createBetterAuth,
  ) {}

  async resolve(
    request: Request,
    env: BetterAuthRuntimeEnv,
  ): Promise<AuthenticatedIdentity | null> {
    const session = await this.authFactory(env).api.getSession({
      headers: request.headers,
    });
    if (!session) return null;

    return {
      userId: session.user.id,
      email: session.user.email,
      name: session.user.name,
      sessionId: session.session.id,
    };
  }
}

export const identityService = new IdentityService();
