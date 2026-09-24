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

/**
 * Initialize Conclave application state after Better Auth has authenticated
 * the human. V6 does not create an execution Workspace as a side effect of
 * sign-in; Workspace creation is an explicit user action.
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

}

export async function listPendingInvitations(
  db: ProvisioningDatabase,
  email: string,
  now = new Date().toISOString(),
): Promise<PendingInvitation[]> {
  void db;
  void email;
  void now;
  return [];
}
