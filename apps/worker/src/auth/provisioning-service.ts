import type { AuthenticatedIdentity } from "./identity-service.js";

export interface ProvisioningStatement {
  bind(...values: unknown[]): ProvisioningStatement;
  first<T = Record<string, unknown>>(): Promise<T | null>;
  all<T = Record<string, unknown>>(): Promise<{ results?: readonly T[] }>;
  run(): Promise<unknown>;
}

export interface ProvisioningDatabase {
  prepare(query: string): ProvisioningStatement & {
    first<T = Record<string, unknown>>(): Promise<T | null>;
    all<T = Record<string, unknown>>(): Promise<{ results?: readonly T[] }>;
    run(): Promise<unknown>;
  };
  batch(statements: readonly ProvisioningStatement[]): Promise<unknown>;
}

export interface PendingInvitation {
  readonly id: string;
  readonly workspaceId: string;
  readonly projectId: string | null;
  readonly email: string;
  readonly role: "admin" | "member" | "viewer";
  readonly status: "pending";
  readonly expiresAt: string;
}

function personalWorkspaceId(userId: string): string {
  return `ws-personal-${userId}`;
}

function personalWorkspaceSlug(userId: string): string {
  const safeUserId = userId.replace(/[^a-zA-Z0-9_-]/g, "-").slice(0, 160);
  return `personal-${safeUserId || "user"}`;
}

function personalWorkspaceName(identity: AuthenticatedIdentity): string {
  const name = identity.name.trim() || identity.email.split("@", 1)[0];
  return `${name}'s Personal Workspace`;
}

/**
 * Initialize Conclave application state after Better Auth has authenticated
 * the human. This deliberately does not run in an OAuth provider callback.
 */
export async function provisionConclaveUser(
  db: ProvisioningDatabase,
  identity: AuthenticatedIdentity,
  now = new Date().toISOString(),
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO users (id, email, display_name, email_verified, status, created_at, updated_at)
       VALUES (?1, ?2, ?3, 0, 'active', ?4, ?4)
       ON CONFLICT(id) DO UPDATE SET
         email = excluded.email,
         display_name = excluded.display_name,
         updated_at = excluded.updated_at`,
    )
    .bind(identity.userId, identity.email, identity.name, now)
    .run();

  const membership = await db
    .prepare(
      `SELECT wm.workspace_id
       FROM workspace_memberships wm
       JOIN workspaces w ON w.id = wm.workspace_id
       WHERE wm.user_id = ?1 AND wm.status = 'active' AND w.status = 'active'
       LIMIT 1`,
    )
    .bind(identity.userId)
    .first<{ workspace_id: string }>();
  if (membership) return;

  const workspaceId = personalWorkspaceId(identity.userId);
  await db.batch([
    db
      .prepare(
        `INSERT INTO workspaces (id, name, slug, status, created_at, updated_at)
         VALUES (?1, ?2, ?3, 'active', ?4, ?4)
         ON CONFLICT(id) DO NOTHING`,
      )
      .bind(
        workspaceId,
        personalWorkspaceName(identity),
        personalWorkspaceSlug(identity.userId),
        now,
      ),
    db
      .prepare(
        `INSERT INTO workspace_memberships
           (id, workspace_id, user_id, role, status, created_at, updated_at)
         VALUES (?1, ?2, ?3, 'owner', 'active', ?4, ?4)
         ON CONFLICT(workspace_id, user_id) DO UPDATE SET
           role = 'owner', status = 'active', updated_at = excluded.updated_at`,
      )
      .bind(
        `wm-personal-${identity.userId}`,
        workspaceId,
        identity.userId,
        now,
      ),
  ]);
}

export async function listPendingInvitations(
  db: ProvisioningDatabase,
  email: string,
  now = new Date().toISOString(),
): Promise<PendingInvitation[]> {
  const rows = await db
    .prepare(
      `SELECT id, workspace_id AS workspaceId, project_id AS projectId,
              email, role, status, expires_at AS expiresAt
       FROM workspace_invitations
       WHERE lower(email) = lower(?1) AND status = 'pending' AND expires_at > ?2
       ORDER BY created_at ASC`,
    )
    .bind(email, now)
    .all<PendingInvitation>();
  return [...(rows.results ?? [])];
}
