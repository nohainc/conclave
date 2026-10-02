import {
  handleBetterAuthRequest,
  identityService,
  provisionConclaveUser,
  recordAuthAuditEvent,
} from "../auth/index.js";
import { extractBearerToken, hashToken } from "@conclave/security";
import { HttpError, json, recordAudit, securityContext } from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";

export async function handleSession(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  return json({
    authenticated: true,
    user: context.user,
    sessionId: context.sessionId,
    clientType: context.clientType,
  });
}

/** Completes a session-bound step-up proof after a strong authentication ceremony. */
export async function handleCompleteStepUp(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const event = await env.CONCLAVE_DB.prepare(
    `SELECT id, method FROM auth_step_up_events
     WHERE user_id = ?1 AND consumed_at IS NULL
     ORDER BY created_at DESC LIMIT 1`,
  )
    .bind(context.userId)
    .first<{ id: string; method: "passkey" | "totp" }>();
  if (!event) {
    return json(
      { error: "No recent strong authentication ceremony is available" },
      { status: 428 },
    );
  }

  const now = new Date();
  const authenticatedAt = now.toISOString();
  const expiresAt = new Date(now.getTime() + 10 * 60 * 1000).toISOString();
  await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      `INSERT INTO auth_step_up_sessions
           (id, user_id, session_id, method, authenticated_at, expires_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(session_id) DO UPDATE SET
           method = excluded.method,
           authenticated_at = excluded.authenticated_at,
           expires_at = excluded.expires_at`,
    ).bind(
      crypto.randomUUID(),
      context.userId,
      context.sessionId,
      event.method,
      authenticatedAt,
      expiresAt,
    ),
    env.CONCLAVE_DB.prepare(
      "UPDATE auth_step_up_events SET consumed_at = ?1 WHERE id = ?2 AND consumed_at IS NULL",
    ).bind(authenticatedAt, event.id),
  ]);
  await recordAuthAuditEvent(env.CONCLAVE_DB, {
    action: "auth.step_up.completed",
    outcome: "success",
    userId: context.userId,
    sessionId: context.sessionId,
    provider: event.method,
    operation: "step_up",
  });
  return json({ ok: true, method: event.method, expiresAt });
}

export async function handleSessionLogout(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const headers = new Headers(request.headers);
  headers.delete("content-length");
  headers.set("content-type", "application/json");
  const authRequest = new Request(new URL("/api/auth/sign-out", request.url), {
    method: "POST",
    headers,
    body: JSON.stringify({ disableRedirect: true }),
  });
  const response = await handleBetterAuthRequest(authRequest, env);
  if (response.ok && env.CONCLAVE_DB) {
    await recordAudit(env, context, "logout", "session", context.sessionId);
  }
  return response;
}

const DESKTOP_HUMAN_AUDIENCE = "conclave.desktop.management" as const;
const DESKTOP_HUMAN_SESSION_MS = 30 * 24 * 60 * 60 * 1000;

export function randomSecret(prefix: string): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return `${prefix}${btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "")}`;
}

export async function handleCreateDesktopAuthIntent(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const body = (await request.json().catch(() => ({}))) as {
    clientName?: unknown;
    contractVersion?: unknown;
  };
  if (
    !body ||
    typeof body !== "object" ||
    Array.isArray(body) ||
    Object.keys(body).some(
      (key) => !["clientName", "contractVersion"].includes(key),
    ) ||
    body.contractVersion !== "1.1" ||
    typeof body.clientName !== "string" ||
    !body.clientName.trim()
  ) {
    throw new HttpError(
      400,
      "A supported contract version and client name are required",
    );
  }
  const intentId = crypto.randomUUID();
  const pollToken = randomSecret("conclave_dap_");
  const createdAt = new Date();
  const expiresAt = new Date(createdAt.getTime() + 10 * 60_000);
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO desktop_auth_intents
       (id, poll_token_hash, client_name, created_at, expires_at)
     VALUES (?1, ?2, ?3, ?4, ?5)`,
  )
    .bind(
      intentId,
      await hashToken(pollToken),
      body.clientName.trim().slice(0, 128),
      createdAt.toISOString(),
      expiresAt.toISOString(),
    )
    .run();

  const verificationUrl = new URL("/desktop-auth/approve", request.url);
  verificationUrl.searchParams.set("intentId", intentId);
  return json(
    {
      intentId,
      pollToken,
      verificationUrl: verificationUrl.toString(),
      expiresAt: expiresAt.toISOString(),
      pollIntervalMs: 2000,
    },
    { status: 201 },
  );
}

export async function handleDesktopAuthIntentStatus(
  request: Request,
  env: SecurityEnv,
  intentId: string,
): Promise<Response> {
  const pollToken = extractBearerToken(request.headers);
  if (!pollToken)
    throw new HttpError(401, "Desktop auth polling credential required");
  const intent = await env.CONCLAVE_DB.prepare(
    `SELECT expires_at AS expiresAt, approved_at AS approvedAt,
            claimed_at AS claimedAt, denied_at AS deniedAt
       FROM desktop_auth_intents WHERE id = ?1 AND poll_token_hash = ?2`,
  )
    .bind(intentId, await hashToken(pollToken))
    .first<{
      expiresAt: string;
      approvedAt: string | null;
      claimedAt: string | null;
      deniedAt: string | null;
    }>();
  if (!intent) throw new HttpError(404, "Desktop auth intent not found");
  const status = intent.claimedAt
    ? "claimed"
    : intent.deniedAt
      ? "denied"
      : intent.approvedAt
        ? "approved"
        : intent.expiresAt <= new Date().toISOString()
          ? "expired"
          : "pending";
  return json({ intentId, status, expiresAt: intent.expiresAt });
}

/** Public, non-secret state for tabs opened by the desktop system browser. */
export async function handleDesktopAuthIntentBrowserStatus(
  _request: Request,
  env: SecurityEnv,
  intentId: string,
): Promise<Response> {
  const intent = await env.CONCLAVE_DB.prepare(
    `SELECT expires_at AS expiresAt, approved_at AS approvedAt,
            claimed_at AS claimedAt, denied_at AS deniedAt
       FROM desktop_auth_intents WHERE id = ?1`,
  )
    .bind(intentId)
    .first<{
      expiresAt: string;
      approvedAt: string | null;
      claimedAt: string | null;
      deniedAt: string | null;
    }>();
  if (!intent) throw new HttpError(404, "Desktop auth intent not found");
  const status = intent.claimedAt
    ? "claimed"
    : intent.deniedAt
      ? "denied"
      : intent.approvedAt
        ? "approved"
        : intent.expiresAt <= new Date().toISOString()
          ? "expired"
          : "pending";
  return json({ intentId, status, expiresAt: intent.expiresAt });
}

export async function handleCancelDesktopAuthIntent(
  request: Request,
  env: SecurityEnv,
  intentId: string,
): Promise<Response> {
  const pollToken = extractBearerToken(request.headers);
  if (!pollToken) {
    throw new HttpError(401, "Desktop auth polling credential required");
  }
  const now = new Date().toISOString();
  const result = await env.CONCLAVE_DB.prepare(
    `UPDATE desktop_auth_intents SET denied_at = ?1
      WHERE id = ?2 AND poll_token_hash = ?3 AND approved_at IS NULL
        AND claimed_at IS NULL AND denied_at IS NULL AND expires_at > ?1`,
  )
    .bind(now, intentId, await hashToken(pollToken))
    .run();
  if ((result.meta?.changes ?? 0) !== 1) {
    throw new HttpError(409, "Desktop sign-in is no longer pending");
  }
  return json({ intentId, cancelled: true });
}

export async function handleDenyDesktopAuthIntent(
  request: Request,
  env: SecurityEnv,
  intentId: string,
): Promise<Response> {
  const identity = await identityService.resolve(request, env);
  if (!identity)
    throw new HttpError(401, "Sign in before canceling this request");
  const now = new Date().toISOString();
  const result = await env.CONCLAVE_DB.prepare(
    `UPDATE desktop_auth_intents SET denied_at = ?1
      WHERE id = ?2 AND approved_at IS NULL AND claimed_at IS NULL
        AND denied_at IS NULL AND expires_at > ?1`,
  )
    .bind(now, intentId)
    .run();
  if ((result.meta?.changes ?? 0) !== 1) {
    throw new HttpError(409, "Desktop sign-in is no longer pending");
  }
  return json({ intentId, cancelled: true });
}

export async function handleApproveDesktopAuthIntent(
  request: Request,
  env: SecurityEnv,
  intentId: string,
): Promise<Response> {
  const identity = await identityService.resolve(request, env);
  if (!identity)
    throw new HttpError(
      401,
      "Sign in to Conclave AX before approving Workspace sign-in",
    );
  await provisionConclaveUser(env.CONCLAVE_DB, identity);
  const body: unknown = await request.json().catch(() => ({}));
  if (
    !body ||
    typeof body !== "object" ||
    Array.isArray(body) ||
    Object.keys(body).length !== 0
  ) {
    throw new HttpError(400, "Desktop approval does not accept request fields");
  }
  const now = new Date().toISOString();
  const result = await env.CONCLAVE_DB.prepare(
    `UPDATE desktop_auth_intents
        SET approved_at = ?1, approved_user_id = ?2
      WHERE id = ?3 AND approved_at IS NULL
        AND claimed_at IS NULL AND denied_at IS NULL AND expires_at > ?1`,
  )
    .bind(now, identity.userId, intentId)
    .run();
  if ((result.meta?.changes ?? 0) !== 1) {
    throw new HttpError(
      409,
      "This sign-in request is invalid, expired, or already used",
    );
  }
  return json({
    approved: true,
    approvedAt: now,
    user: {
      userId: identity.userId,
      displayName: identity.name,
      email: identity.email,
    },
  });
}

export async function handleClaimDesktopAuthIntent(
  request: Request,
  env: SecurityEnv,
  intentId: string,
): Promise<Response> {
  const body = (await request.json().catch(() => ({}))) as {
    pollToken?: unknown;
  };
  const pollToken = typeof body.pollToken === "string" ? body.pollToken : "";
  if (!pollToken)
    throw new HttpError(401, "Desktop auth polling credential required");
  const intent = await env.CONCLAVE_DB.prepare(
    `SELECT approved_user_id AS userId, expires_at AS expiresAt
       FROM desktop_auth_intents
      WHERE id = ?1 AND poll_token_hash = ?2 AND approved_at IS NOT NULL
        AND claimed_at IS NULL AND denied_at IS NULL AND expires_at > ?3`,
  )
    .bind(intentId, await hashToken(pollToken), new Date().toISOString())
    .first<{ userId: string; expiresAt: string }>();
  if (!intent)
    throw new HttpError(
      409,
      "Desktop sign-in is not approved, expired, or already claimed",
    );
  const user = await env.CONCLAVE_DB.prepare(
    "SELECT id AS userId, email, display_name AS displayName FROM users WHERE id = ?1 AND status = 'active'",
  )
    .bind(intent.userId)
    .first<{ userId: string; email: string; displayName: string }>();
  if (!user) throw new HttpError(403, "Conclave account is unavailable");

  const sessionId = crypto.randomUUID();
  const credential = randomSecret("conclave_dhs_");
  const tokenHash = await hashToken(credential);
  const issuedAt = new Date();
  const expiresAt = new Date(issuedAt.getTime() + DESKTOP_HUMAN_SESSION_MS);
  const results = await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      `UPDATE desktop_auth_intents SET claimed_at = ?1, claimed_session_id = ?2
        WHERE id = ?3 AND poll_token_hash = ?4 AND approved_at IS NOT NULL
          AND claimed_at IS NULL AND denied_at IS NULL AND expires_at > ?1`,
    ).bind(
      issuedAt.toISOString(),
      sessionId,
      intentId,
      await hashToken(pollToken),
    ),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at)
       SELECT ?1, ?2, ?3, ?4, ?5, ?5, ?6 FROM desktop_auth_intents
        WHERE id = ?7 AND claimed_session_id = ?1`,
    ).bind(
      sessionId,
      user.userId,
      tokenHash,
      DESKTOP_HUMAN_AUDIENCE,
      issuedAt.toISOString(),
      expiresAt.toISOString(),
      intentId,
    ),
  ]);
  const changes =
    (results[0] as { meta?: { changes?: number } } | undefined)?.meta
      ?.changes ?? 0;
  if (changes !== 1)
    throw new HttpError(409, "Desktop sign-in is already claimed or expired");
  return json({
    credential,
    user: {
      userId: user.userId,
      displayName: user.displayName,
      email: user.email,
    },
    issuedAt: issuedAt.toISOString(),
    expiresAt: expiresAt.toISOString(),
    sessionId,
    audience: DESKTOP_HUMAN_AUDIENCE,
  });
}

export async function handleRevokeDesktopHumanSession(
  request: Request,
  env: SecurityEnv,
  sessionId: string,
): Promise<Response> {
  const credential = extractBearerToken(request.headers);
  if (!credential) throw new HttpError(401, "Desktop human session required");
  const now = new Date().toISOString();
  const result = await env.CONCLAVE_DB.prepare(
    `UPDATE desktop_human_sessions SET revoked_at = ?1
      WHERE id = ?2 AND token_hash = ?3 AND revoked_at IS NULL AND expires_at > ?1`,
  )
    .bind(now, sessionId, await hashToken(credential))
    .run();
  if ((result.meta?.changes ?? 0) !== 1)
    throw new HttpError(401, "Desktop human session is invalid or revoked");
  return json({ revoked: true, revokedAt: now });
}

export async function findDesktopHumanSession(
  request: Request,
  env: SecurityEnv,
  sessionId?: string,
) {
  const credential = extractBearerToken(request.headers);
  if (!credential) throw new HttpError(401, "Desktop human session required");
  const now = new Date().toISOString();
  const session = await env.CONCLAVE_DB.prepare(
    `SELECT s.id AS sessionId, s.user_id AS userId, s.created_at AS createdAt,
            s.expires_at AS expiresAt,
            u.email, u.display_name AS displayName
       FROM desktop_human_sessions s JOIN users u ON u.id = s.user_id
      WHERE s.token_hash = ?1 AND s.audience = ?2 AND s.revoked_at IS NULL
        AND s.expires_at > ?3 AND u.status = 'active'
        AND (?4 IS NULL OR s.id = ?4)`,
  )
    .bind(
      await hashToken(credential),
      DESKTOP_HUMAN_AUDIENCE,
      now,
      sessionId ?? null,
    )
    .first<{
      sessionId: string;
      userId: string;
      createdAt: string;
      expiresAt: string;
      email: string;
      displayName: string;
    }>();
  if (!session)
    throw new HttpError(
      401,
      "Desktop human session is invalid, expired, or revoked",
    );
  await env.CONCLAVE_DB.prepare(
    "UPDATE desktop_human_sessions SET last_used_at = ?1 WHERE id = ?2",
  )
    .bind(now, session.sessionId)
    .run();
  return { credential, session, now };
}

export async function handleGetDesktopHumanSession(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const { session } = await findDesktopHumanSession(request, env);
  return json({
    sessionId: session.sessionId,
    user: {
      userId: session.userId,
      displayName: session.displayName,
      email: session.email,
    },
    audience: DESKTOP_HUMAN_AUDIENCE,
    expiresAt: session.expiresAt,
  });
}

export async function handleRotateDesktopHumanSession(
  request: Request,
  env: SecurityEnv,
  sessionId: string,
): Promise<Response> {
  const {
    credential: currentCredential,
    session,
    now,
  } = await findDesktopHumanSession(request, env, sessionId);
  const nextCredential = randomSecret("conclave_dhs_");
  const expiresAt = new Date(
    Date.now() + DESKTOP_HUMAN_SESSION_MS,
  ).toISOString();
  const result = await env.CONCLAVE_DB.prepare(
    `UPDATE desktop_human_sessions SET token_hash = ?1,
       last_used_at = ?2, expires_at = ?3
      WHERE id = ?4 AND token_hash = ?5 AND revoked_at IS NULL`,
  )
    .bind(
      await hashToken(nextCredential),
      now,
      expiresAt,
      session.sessionId,
      await hashToken(currentCredential),
    )
    .run();
  if ((result.meta?.changes ?? 0) !== 1) {
    throw new HttpError(401, "Desktop human session changed or was revoked");
  }
  return json({
    credential: nextCredential,
    user: {
      userId: session.userId,
      displayName: session.displayName,
      email: session.email,
    },
    issuedAt: now,
    expiresAt,
    sessionId: session.sessionId,
    audience: DESKTOP_HUMAN_AUDIENCE,
  });
}
