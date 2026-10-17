import { hashToken } from "@conclave/security";
import {
  HttpError,
  json,
  securityContext,
  type SecurityEnv,
} from "./http-security.js";

const INVITATION_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_PENDING_PER_WORKSPACE = 20;

async function ownedWorkspace(
  env: SecurityEnv,
  workspaceId: string,
  userId: string,
) {
  const workspace = await env.CONCLAVE_DB.prepare(
    "SELECT id FROM execution_workspaces WHERE id = ?1 AND owner_user_id = ?2 AND status != 'revoked'",
  )
    .bind(workspaceId, userId)
    .first();
  if (!workspace) throw new HttpError(404, "Workspace not found");
}

/**
 * Owner-only: list (GET), create (POST {email}) and revoke
 * (POST .../:invitationId/revoke) Workspace invitations. The invitation grants
 * nothing until the invitee accepts it.
 */
export async function handleWorkspaceInvitations(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  invitationId?: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  await ownedWorkspace(env, workspaceId, context.userId);
  const now = new Date().toISOString();
  if (invitationId !== undefined) {
    if (request.method !== "POST") throw new HttpError(405, "Unsupported method");
    const revoked = await env.CONCLAVE_DB.prepare(
      "UPDATE workspace_invitations SET status='revoked',updated_at=?3 WHERE id=?1 AND workspace_id=?2 AND status='pending'",
    )
      .bind(invitationId, workspaceId, now)
      .run();
    if (!revoked.meta?.changes)
      throw new HttpError(404, "Pending invitation not found");
    return json({ revoked: true });
  }
  if (request.method === "GET") {
    const rows = await env.CONCLAVE_DB.prepare(
      `SELECT id, email, status, expires_at AS expiresAt, created_at AS createdAt
       FROM workspace_invitations WHERE workspace_id = ?1 ORDER BY created_at DESC LIMIT 100`,
    )
      .bind(workspaceId)
      .all();
    return json({ invitations: rows.results ?? [] });
  }
  if (request.method !== "POST") throw new HttpError(405, "Unsupported method");
  const body = (await request.json().catch(() => null)) as Record<
    string,
    unknown
  > | null;
  if (
    !body ||
    typeof body.email !== "string" ||
    Object.keys(body).some((key) => key !== "email")
  )
    throw new HttpError(400, "An email address is required");
  const email = body.email.trim().toLowerCase();
  if (!email.includes("@") || email.length > 254)
    throw new HttpError(400, "Enter a valid email address");
  if (email === context.user.email.trim().toLowerCase())
    throw new HttpError(400, "You cannot invite yourself");
  await env.CONCLAVE_DB.prepare(
    "UPDATE workspace_invitations SET status='expired',updated_at=?2 WHERE workspace_id=?1 AND status='pending' AND expires_at<=?2",
  )
    .bind(workspaceId, now)
    .run();
  const already = await env.CONCLAVE_DB.prepare(
    `SELECT 1 AS found FROM workspace_person_grants g JOIN users u ON u.id = g.user_id
     WHERE g.workspace_id = ?1 AND g.status = 'active' AND LOWER(u.email) = ?2`,
  )
    .bind(workspaceId, email)
    .first();
  if (already) throw new HttpError(409, "This person already has access");
  const pending = await env.CONCLAVE_DB.prepare(
    "SELECT COUNT(*) AS n, SUM(LOWER(email) = ?2) AS same FROM workspace_invitations WHERE workspace_id = ?1 AND status = 'pending'",
  )
    .bind(workspaceId, email)
    .first<{ n: number; same: number | null }>();
  if (pending?.same) throw new HttpError(409, "An invitation is already pending");
  if ((pending?.n ?? 0) >= MAX_PENDING_PER_WORKSPACE)
    throw new HttpError(429, "Too many pending invitations");
  const id = `winv-${crypto.randomUUID()}`;
  const token = `workspace_invite_${crypto.randomUUID()}_${crypto.randomUUID()}`;
  const expiresAt = new Date(Date.now() + INVITATION_TTL_MS).toISOString();
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO workspace_invitations(id,workspace_id,email,token_hash,invited_by_user_id,status,expires_at,created_at,updated_at)
     VALUES(?1,?2,?3,?4,?5,'pending',?6,?7,?7)`,
  )
    .bind(
      id,
      workspaceId,
      email,
      await hashToken(token),
      context.userId,
      expiresAt,
      now,
    )
    .run();
  return json({ id, email, status: "pending", expiresAt }, { status: 201 });
}

/** The signed-in person's pending Workspace invitations, matched by email. */
export async function handleMyWorkspaceInvitations(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (request.method !== "GET") throw new HttpError(405, "Unsupported method");
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT i.id, ew.name AS workspaceName, u.display_name AS ownerName, i.expires_at AS expiresAt
     FROM workspace_invitations i
     JOIN execution_workspaces ew ON ew.id = i.workspace_id AND ew.status != 'revoked'
     JOIN users u ON u.id = ew.owner_user_id
     WHERE LOWER(i.email) = ?1 AND i.status = 'pending' AND i.expires_at > ?2
     ORDER BY i.created_at DESC`,
  )
    .bind(context.user.email.trim().toLowerCase(), new Date().toISOString())
    .all();
  return json({ invitations: rows.results ?? [] });
}

/**
 * Accept an invitation as the invited email. Single use. Creates only the
 * Person Grant; when the Workspace has no default policy the person starts
 * with chat-only access to no Workers, so the owner must choose what to share.
 */
export async function handleAcceptWorkspaceInvitation(
  request: Request,
  env: SecurityEnv,
  invitationId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (request.method !== "POST") throw new HttpError(405, "Unsupported method");
  const invitation = await env.CONCLAVE_DB.prepare(
    `SELECT i.id, i.workspace_id AS workspaceId, i.email, i.status, i.expires_at AS expiresAt,
            i.invited_by_user_id AS invitedBy, ew.owner_user_id AS ownerId
     FROM workspace_invitations i
     JOIN execution_workspaces ew ON ew.id = i.workspace_id AND ew.status != 'revoked'
     WHERE i.id = ?1`,
  )
    .bind(invitationId)
    .first<{
      id: string;
      workspaceId: string;
      email: string;
      status: string;
      expiresAt: string;
      invitedBy: string;
      ownerId: string;
    }>();
  if (!invitation || invitation.status !== "pending")
    throw new HttpError(404, "Workspace invitation not found");
  if (new Date(invitation.expiresAt).getTime() <= Date.now())
    throw new HttpError(410, "Workspace invitation expired");
  if (
    context.user.email.trim().toLowerCase() !==
    invitation.email.trim().toLowerCase()
  )
    throw new HttpError(
      403,
      "Invitation recipient does not match signed-in user",
    );
  // The inviter must still own the Workspace.
  if (invitation.ownerId !== invitation.invitedBy)
    throw new HttpError(403, "The inviter can no longer lend this Workspace");
  if (invitation.ownerId === context.userId)
    throw new HttpError(400, "You already own this Workspace");
  const now = new Date().toISOString();
  const results = await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      "UPDATE workspace_invitations SET status='accepted',accepted_by_user_id=?1,accepted_at=?2,updated_at=?2 WHERE id=?3 AND status='pending' AND expires_at>?2",
    ).bind(context.userId, now, invitation.id),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO workspace_person_grants(workspace_id,user_id,granted_by_user_id,status,created_at,updated_at)
       SELECT ?1,?2,?3,'active',?4,?4 WHERE EXISTS (SELECT 1 FROM workspace_invitations WHERE id=?5 AND status='accepted' AND accepted_by_user_id=?2 AND accepted_at=?4)
       ON CONFLICT(workspace_id,user_id) DO UPDATE SET status='active',granted_by_user_id=excluded.granted_by_user_id,updated_at=excluded.updated_at`,
    ).bind(
      invitation.workspaceId,
      context.userId,
      invitation.ownerId,
      now,
      invitation.id,
    ),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO workspace_member_overrides(workspace_id,user_id,policy_json,updated_at)
       SELECT ?1,?2,'{"schemaVersion":1,"mode":"chat","workers":{}}',?3
       WHERE EXISTS (SELECT 1 FROM workspace_person_grants WHERE workspace_id=?1 AND user_id=?2 AND updated_at=?3)
         AND NOT EXISTS (SELECT 1 FROM workspace_member_access WHERE workspace_id=?1)
       ON CONFLICT(workspace_id,user_id) DO NOTHING`,
    ).bind(invitation.workspaceId, context.userId, now),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO workspace_audit_log(id,workspace_id,actor_type,actor_id,action,target_type,target_id,details_json,created_at)
       SELECT ?1,?2,'user',?3,'workspace.person_grant.created','user',?3,'{}',?4
       WHERE EXISTS (SELECT 1 FROM workspace_person_grants WHERE workspace_id=?2 AND user_id=?3 AND updated_at=?4)`,
    ).bind(crypto.randomUUID(), invitation.workspaceId, context.userId, now),
  ]);
  if (!results[0]?.meta?.changes)
    throw new HttpError(409, "Workspace invitation is no longer pending");
  return json({ workspaceId: invitation.workspaceId, status: "active" });
}

/**
 * Owner-only: end a person's grant. They lose access at their next request,
 * and every Space grant their Spaces hold on this Workspace is revoked so the
 * scheduler stops dispatching to it.
 */
export async function handleRevokePersonGrant(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  personId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  await ownedWorkspace(env, workspaceId, context.userId);
  if (request.method !== "POST") throw new HttpError(405, "Unsupported method");
  const now = new Date().toISOString();
  const results = await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      "UPDATE workspace_person_grants SET status='revoked',updated_at=?3 WHERE workspace_id=?1 AND user_id=?2 AND status='active'",
    ).bind(workspaceId, personId, now),
    env.CONCLAVE_DB.prepare(
      `UPDATE workspace_space_grants SET status='revoked',updated_at=?3
       WHERE workspace_id=?1 AND status IN ('active','suspended')
         AND space_id IN (SELECT id FROM spaces WHERE owner_user_id=?2)`,
    ).bind(workspaceId, personId, now),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO workspace_audit_log(id,workspace_id,actor_type,actor_id,action,target_type,target_id,details_json,created_at)
       SELECT ?1,?2,'user',?3,'workspace.person_grant.revoked','user',?4,'{}',?5
       WHERE EXISTS (SELECT 1 FROM workspace_person_grants WHERE workspace_id=?2 AND user_id=?4 AND status='revoked' AND updated_at=?5)`,
    ).bind(crypto.randomUUID(), workspaceId, context.userId, personId, now),
  ]);
  if (!results[0]?.meta?.changes)
    throw new HttpError(404, "Active grant not found");
  return json({ revoked: true });
}

/**
 * Owner-only: set a borrower's concurrent request limit (1-10) on this
 * Workspace. Enforced when a request is admitted.
 */
export async function handlePersonGrantQuota(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  personId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  await ownedWorkspace(env, workspaceId, context.userId);
  if (request.method !== "PUT") throw new HttpError(405, "Unsupported method");
  const body = (await request.json().catch(() => null)) as Record<
    string,
    unknown
  > | null;
  const limit = body?.maxConcurrentRequests;
  if (
    !body ||
    Object.keys(body).some((key) => key !== "maxConcurrentRequests") ||
    typeof limit !== "number" ||
    !Number.isInteger(limit) ||
    limit < 1 ||
    limit > 10
  )
    throw new HttpError(400, "maxConcurrentRequests must be a whole number from 1 to 10");
  const updated = await env.CONCLAVE_DB.prepare(
    "UPDATE workspace_person_grants SET max_concurrent_requests=?3,updated_at=?4 WHERE workspace_id=?1 AND user_id=?2 AND status='active'",
  )
    .bind(workspaceId, personId, limit, new Date().toISOString())
    .run();
  if (!updated.meta?.changes) throw new HttpError(404, "Active grant not found");
  return json({ maxConcurrentRequests: limit });
}
