import { recordAuthAuditEvent } from "../auth/index.js";
import { HttpError, json, securityContext } from "./handlers.js";
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
