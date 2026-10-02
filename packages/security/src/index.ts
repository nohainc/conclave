/** Security primitives for current Conclave identities and resources. */

export const PROJECT_ROLES = ["owner", "collaborator", "viewer"] as const;
export type ProjectRole = (typeof PROJECT_ROLES)[number];

export const PERMISSIONS = [
  "projects:read",
  "projects:write",
  "projects:manage",
  "run.start",
  "runs:control",
  "workspace:manage",
  "profiles:admin",
  "profiles:release:manage",
  "audit:read",
  "usage:read",
] as const;
export type Permission = (typeof PERMISSIONS)[number];

export const PROJECT_ROLE_PERMISSIONS: Record<
  ProjectRole,
  readonly Permission[]
> = {
  owner: [
    "projects:read",
    "projects:write",
    "projects:manage",
    "run.start",
    "runs:control",
  ],
  collaborator: ["projects:read", "projects:write", "run.start"],
  viewer: ["projects:read"],
};

export class AuthorizationError extends Error {
  readonly code = "FORBIDDEN";
  constructor(
    readonly permission: Permission,
    readonly resourceId?: string,
  ) {
    super(
      `Permission '${permission}' is required${resourceId ? ` for resource '${resourceId}'` : ""}`,
    );
    this.name = "AuthorizationError";
  }
}

export class AuthenticationError extends Error {
  readonly code = "UNAUTHORIZED";
  constructor(message: string) {
    super(message);
    this.name = "AuthenticationError";
  }
}

export type ClientType = "web" | "desktop" | "cli" | "api";

export interface AuthenticatedUser {
  readonly id: string;
  readonly email: string;
  readonly displayName: string;
  readonly avatarUrl?: string | null;
  readonly status: "active" | "suspended" | "deactivated";
}

/** Request identity and current Project memberships; resource access is checked separately. */
export interface SecurityContext {
  readonly userId: string;
  readonly user: AuthenticatedUser;
  readonly projectRoles: Readonly<Record<string, ProjectRole>>;
  readonly sessionId: string;
  readonly clientType: ClientType;
}

export function canAccessProject(
  context: SecurityContext,
  projectId: string,
): boolean {
  return context.user.status === "active" && !!context.projectRoles[projectId];
}

export function authorize(
  context: SecurityContext,
  permission: Permission,
  projectId?: string,
): void {
  if (context.user.status !== "active") {
    throw new AuthorizationError(permission, projectId);
  }
  // Unscoped Project listing/creation starts from authenticated identity and
  // is filtered/owned by its handler. Every other permission needs an explicit
  // Project, Workspace owner, or Profile administrator check.
  if (!projectId) {
    if (permission === "projects:read" || permission === "projects:manage") return;
    throw new AuthorizationError(permission);
  }
  const role = context.projectRoles[projectId];
  if (!role || !PROJECT_ROLE_PERMISSIONS[role]?.includes(permission)) {
    throw new AuthorizationError(permission, projectId);
  }
}

export interface DatabaseStatement {
  bind(...values: unknown[]): DatabaseStatement;
  first<T = Record<string, unknown>>(): Promise<T | null>;
  all<T = Record<string, unknown>>(): Promise<{
    results?: readonly T[];
  }>;
  run(): Promise<{ success?: boolean }>;
}

export interface DatabaseAdapter {
  prepare(query: string): DatabaseStatement;
}

export interface AuthenticatedIdentity {
  readonly userId: string;
  readonly email: string;
  readonly name: string;
  readonly sessionId: string;
}

export async function resolveProjectSecurityContextFromIdentity(
  db: DatabaseAdapter,
  identity: AuthenticatedIdentity,
): Promise<SecurityContext> {
  const userRow = await db
    .prepare(
      `SELECT id, email, display_name, avatar_url, status
       FROM users WHERE id = ?1`,
    )
    .bind(identity.userId)
    .first<{
      id: string;
      email: string;
      display_name: string;
      avatar_url: string | null;
      status: string;
    }>();
  if (!userRow) throw new AuthenticationError("Conclave user not found");
  if (!["active", "suspended", "deactivated"].includes(userRow.status)) {
    throw new AuthenticationError("Invalid Conclave user status");
  }
  const user: AuthenticatedUser = {
    id: userRow.id,
    email: userRow.email,
    displayName: userRow.display_name,
    avatarUrl: userRow.avatar_url,
    status: userRow.status as AuthenticatedUser["status"],
  };
  if (user.status !== "active") {
    throw new AuthenticationError(`User account is ${user.status}`);
  }
  const memberships = await db
    .prepare(
      `SELECT pm.project_id, pm.role
       FROM project_memberships pm JOIN projects p ON p.id = pm.project_id
       WHERE pm.user_id = ?1`,
    )
    .bind(user.id)
    .all<{ project_id: string; role: ProjectRole }>();
  const projectRoles: Record<string, ProjectRole> = {};
  for (const membership of memberships.results ?? []) {
    if (PROJECT_ROLES.includes(membership.role)) {
      projectRoles[membership.project_id] = membership.role;
    }
  }
  return {
    userId: user.id,
    user,
    projectRoles,
    sessionId: identity.sessionId,
    clientType: "web",
  };
}

export async function authorizeProjectMembership(
  db: DatabaseAdapter,
  context: Pick<SecurityContext, "userId" | "user">,
  projectId: string,
  permission: Permission,
): Promise<{ role: ProjectRole }> {
  if (context.user.status !== "active") {
    throw new AuthorizationError(permission, projectId);
  }
  const membership = await db
    .prepare(
      `SELECT pm.role FROM project_memberships pm
       JOIN projects p ON p.id = pm.project_id
       WHERE pm.project_id = ?1 AND pm.user_id = ?2`,
    )
    .bind(projectId, context.userId)
    .first<{ role: ProjectRole }>();
  if (
    !membership ||
    !PROJECT_ROLES.includes(membership.role) ||
    !PROJECT_ROLE_PERMISSIONS[membership.role].includes(permission)
  ) {
    throw new AuthorizationError(permission, projectId);
  }
  return membership;
}

export async function authorizeWorkspaceOwner(
  db: DatabaseAdapter,
  context: Pick<SecurityContext, "userId" | "user">,
  workspaceId: string,
  permission: Permission = "workspace:manage",
): Promise<void> {
  if (context.user.status !== "active") {
    throw new AuthorizationError(permission, workspaceId);
  }
  const workspace = await db
    .prepare(
      "SELECT id FROM execution_workspaces WHERE id = ?1 AND owner_user_id = ?2 AND status <> 'revoked'",
    )
    .bind(workspaceId, context.userId)
    .first<{ id: string }>();
  if (!workspace) throw new AuthorizationError(permission, workspaceId);
}

export async function authorizeProjectOwner(
  db: DatabaseAdapter,
  context: Pick<SecurityContext, "userId" | "user">,
  projectId: string,
  permission: Permission = "projects:manage",
): Promise<void> {
  if (context.user.status !== "active") {
    throw new AuthorizationError(permission, projectId);
  }
  const owner = await db
    .prepare("SELECT id FROM projects WHERE id = ?1 AND owner_user_id = ?2")
    .bind(projectId, context.userId)
    .first<{ id: string }>();
  if (!owner) throw new AuthorizationError(permission, projectId);
}

export function authorizeProfileAdmin(
  context: Pick<SecurityContext, "userId" | "user">,
  adminUserIds: readonly string[],
  permission: "profiles:admin" | "profiles:release:manage" = "profiles:admin",
): void {
  if (
    context.user.status !== "active" ||
    !adminUserIds.includes(context.userId)
  ) {
    throw new AuthorizationError(permission);
  }
}

const encoder = new TextEncoder();

export function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

export function bytesToBase64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

export async function hashToken(token: string): Promise<string> {
  const digest = await globalThis.crypto.subtle.digest(
    "SHA-256",
    encoder.encode(token),
  );
  return bytesToHex(new Uint8Array(digest));
}

export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) {
    difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return difference === 0;
}

export async function computePackageDigest(
  data: Uint8Array | ArrayBuffer | string,
): Promise<string> {
  const source =
    typeof data === "string"
      ? encoder.encode(data)
      : data instanceof ArrayBuffer
        ? data
        : (data as BufferSource);
  const digest = await globalThis.crypto.subtle.digest("SHA-256", source);
  return `sha256:${bytesToHex(new Uint8Array(digest))}`;
}

export function extractBearerToken(headers: Headers): string | null {
  const value = headers.get("authorization");
  if (!value) return null;
  const match = value.match(/^Bearer\s+(.+)$/i);
  return match?.[1]?.trim() || null;
}
