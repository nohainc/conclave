/**
 * Conclave AX Architecture v2 Security, Authentication & Multi-Tenancy Engine.
 *
 * v5 enforces User ownership and Project membership. The v4 Workspace
 * context remains below only as a migration compatibility surface.
 * Secure browser sessions + Desktop OAuth/PKCE authorization code flow.
 */

// =========================================================================
// 1. Roles & Permissions Model
// =========================================================================

export const WORKSPACE_ROLES = ["owner", "admin", "member", "viewer"] as const;
export type WorkspaceRole = (typeof WORKSPACE_ROLES)[number];

export const PROJECT_ROLES = [
  "owner",
  "collaborator",
  "viewer",
  "lead",
] as const;
export type ProjectRole = (typeof PROJECT_ROLES)[number];

// Legacy alias for compatibility
export const ROLES = WORKSPACE_ROLES;
export type Role = WorkspaceRole;

export const PERMISSIONS = [
  // V4 canonical Cloud authorization permissions.
  "host.view",
  "host.manage",
  "host.use",
  "host.bind_workspace",
  "host.revoke",
  "worker.install",
  "worker.manage_on_host",
  "credential.create",
  "credential.share",
  "credential.use",
  "run.start",
  "run.control",
  "workspace:manage",
  "members:manage",
  "billing:manage",
  "projects:manage",
  "projects:read",
  "projects:write",
  "agents:manage",
  "agents:read",
  "hosts:manage",
  "hosts:read",
  "workers:manage",
  "workers:read",
  "chats:create",
  "chats:read",
  "goals:create",
  "runs:control",
  "audit:read",
  "usage:read",
  // Legacy permissions compatibility
  "org:manage",
  "project:read",
  "project:write",
  "run:create",
  "run:control",
  "workers:manage",
  "secrets:manage",
] as const;
export type Permission = (typeof PERMISSIONS)[number];

export const WORKSPACE_ROLE_PERMISSIONS: Record<
  WorkspaceRole,
  readonly Permission[]
> = {
  owner: PERMISSIONS,
  admin: [
    "host.view",
    "host.manage",
    "host.use",
    "host.bind_workspace",
    "host.revoke",
    "worker.install",
    "worker.manage_on_host",
    "credential.create",
    "credential.share",
    "credential.use",
    "run.start",
    "run.control",
    "members:manage",
    "projects:manage",
    "projects:read",
    "projects:write",
    "agents:manage",
    "agents:read",
    "hosts:manage",
    "hosts:read",
    "workers:manage",
    "workers:read",
    "chats:create",
    "chats:read",
    "goals:create",
    "runs:control",
    "audit:read",
    "usage:read",
    "org:manage",
    "project:read",
    "project:write",
    "run:create",
    "run:control",
    "secrets:manage",
  ],
  member: [
    "host.view",
    "host.use",
    "credential.create",
    "credential.use",
    "run.start",
    "run.control",
    "projects:read",
    "projects:write",
    "agents:read",
    "hosts:read",
    "workers:read",
    "chats:create",
    "chats:read",
    "goals:create",
    "runs:control",
    "usage:read",
    "project:read",
    "project:write",
    "run:create",
  ],
  viewer: [
    "host.view",
    "projects:read",
    "agents:read",
    "hosts:read",
    "workers:read",
    "chats:read",
    "project:read",
  ],
};

export const PROJECT_ROLE_PERMISSIONS: Record<
  ProjectRole,
  readonly Permission[]
> = {
  owner: [
    "projects:read",
    "projects:write",
    "projects:manage",
    "chats:create",
    "chats:read",
    "goals:create",
    "run.start",
    "runs:control",
    "project:read",
    "project:write",
    "run:create",
    "run:control",
  ],
  lead: [
    "projects:read",
    "projects:write",
    "chats:create",
    "chats:read",
    "goals:create",
    "runs:control",
    "project:read",
    "project:write",
    "run:create",
    "run:control",
  ],
  collaborator: [
    "projects:read",
    "projects:write",
    "chats:create",
    "chats:read",
    "goals:create",
    "run.start",
    "project:read",
    "project:write",
    "run:create",
    "run:control",
  ],
  viewer: ["projects:read", "chats:read", "project:read"],
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

// =========================================================================
// 2. Authenticated Context & Invariants
// =========================================================================

export type ClientType = "web" | "desktop" | "cli" | "api";

export interface AuthenticatedUser {
  readonly id: string;
  readonly email: string;
  readonly displayName: string;
  readonly avatarUrl?: string | null;
  readonly status: "active" | "suspended" | "deactivated";
}

export interface WorkspaceSecurityContext {
  readonly userId: string;
  readonly user: AuthenticatedUser;
  readonly workspaceId: string;
  readonly workspaceRole: WorkspaceRole;
  readonly roles: readonly WorkspaceRole[];
  readonly authorizedProjectIds: readonly string[];
  readonly projectRoles: Readonly<Record<string, ProjectRole>>;
  readonly sessionId: string;
  readonly clientType: ClientType;
  readonly suspended?: boolean;

  // Backward compatibility fields
  readonly organizationId: string;
  readonly organizationRoles: readonly Role[];
  /** Active resolver model. v5 contexts never select a Workspace. */
  readonly authorizationModel?: "v4" | "v5";
  readonly ownedWorkspaceIds?: readonly string[];
  readonly ownedAccountIds?: readonly string[];
}

export type SecurityContext = WorkspaceSecurityContext;

export function permissionsFor(
  roles: readonly WorkspaceRole[],
): ReadonlySet<Permission> {
  return new Set(
    roles.flatMap((role) => WORKSPACE_ROLE_PERMISSIONS[role] ?? []),
  );
}

export function canAccessProject(
  context: WorkspaceSecurityContext,
  projectId: string,
): boolean {
  if (context.suspended || context.user.status !== "active") return false;
  if (context.authorizationModel === "v5") {
    return context.authorizedProjectIds.includes(projectId);
  }
  // Historical v4 owners and admins had workspace-wide project access.
  if (context.workspaceRole === "owner" || context.workspaceRole === "admin") {
    return true;
  }
  return context.authorizedProjectIds.includes(projectId);
}

export function authorize(
  context: WorkspaceSecurityContext,
  permission: Permission,
  projectId?: string,
): void {
  if (context.suspended || context.user.status !== "active") {
    throw new AuthorizationError(permission, projectId);
  }

  if (context.authorizationModel === "v5") {
    if (projectId) {
      const projectRole = context.projectRoles[projectId];
      if (!projectRole) throw new AuthorizationError(permission, projectId);
      if (!PROJECT_ROLE_PERMISSIONS[projectRole].includes(permission)) {
        throw new AuthorizationError(permission, projectId);
      }
      return;
    }
    return;
  }

  if (projectId) {
    if (!canAccessProject(context, projectId)) {
      throw new AuthorizationError(permission, projectId);
    }
    const projectRole = context.projectRoles[projectId];
    if (projectRole) {
      const projectPerms = new Set(PROJECT_ROLE_PERMISSIONS[projectRole]);
      if (projectPerms.has(permission)) return;
    }
  }

  const workspacePerms = permissionsFor(context.roles);
  if (!workspacePerms.has(permission)) {
    throw new AuthorizationError(permission, projectId);
  }
}

export interface CredentialProfileAccessRecord {
  readonly id: string;
  readonly workspace_id: string;
  readonly owner_type: "user" | "workspace";
  readonly owner_id: string;
  readonly sharing_policy:
    "private_only" | "owner_controlled" | "workspace" | "workspace_capable";
}

export interface CredentialGrantAccessRecord {
  readonly grantee_type: "user" | "workspace" | "role";
  readonly grantee_id: string;
  readonly use_permission?: number | boolean | null;
  readonly expires_at?: string | null;
  readonly revoked_at?: string | null;
}

/** Authorize a current Project membership, re-reading membership state. */
export async function authorizeProjectMembership(
  db: DatabaseAdapter,
  context: Pick<WorkspaceSecurityContext, "userId" | "user" | "suspended">,
  projectId: string,
  permission: Permission,
): Promise<{ role: ProjectRole }> {
  if (context.suspended || context.user.status !== "active") {
    throw new AuthorizationError(permission, projectId);
  }
  const membership = await db
    .prepare(
      `SELECT pm.role
       FROM project_memberships pm
       JOIN projects p ON p.id = pm.project_id
       WHERE pm.project_id = ?1 AND pm.user_id = ?2`,
    )
    .bind(projectId, context.userId)
    .first<{ role: ProjectRole }>();
  if (
    !membership ||
    !PROJECT_ROLE_PERMISSIONS[membership.role]?.includes(permission)
  ) {
    throw new AuthorizationError(permission, projectId);
  }
  return membership;
}

/** Workspaces are user-owned resources, never Project-member resources. */
export async function authorizeWorkspaceOwner(
  db: DatabaseAdapter,
  context: Pick<WorkspaceSecurityContext, "userId" | "user" | "suspended">,
  workspaceId: string,
  permission: Permission,
): Promise<void> {
  if (context.suspended || context.user.status !== "active") {
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
  context: Pick<WorkspaceSecurityContext, "userId" | "user" | "suspended">,
  projectId: string,
  permission: Permission = "projects:manage",
): Promise<void> {
  if (context.suspended || context.user.status !== "active") {
    throw new AuthorizationError(permission, projectId);
  }
  const owner = await db
    .prepare("SELECT id FROM projects WHERE id = ?1 AND owner_user_id = ?2")
    .bind(projectId, context.userId)
    .first<{ id: string }>();
  if (!owner) throw new AuthorizationError(permission, projectId);
}

/**
 * V4 credential authorization is intentionally data-shaped: role membership
 * and explicit grants are evaluated directly, without a policy DSL and
 * without ever returning a secret or a secret-read capability.
 */
export function canUseCredentialProfile(
  context: Pick<
    WorkspaceSecurityContext,
    "userId" | "workspaceId" | "workspaceRole"
  >,
  profile: CredentialProfileAccessRecord,
  grants: readonly CredentialGrantAccessRecord[],
  now = new Date(),
): boolean {
  if (profile.workspace_id !== context.workspaceId) return false;
  if (profile.owner_type === "user" && profile.owner_id === context.userId) {
    return true;
  }
  if (
    profile.owner_type === "workspace" &&
    (profile.sharing_policy === "workspace" ||
      profile.sharing_policy === "workspace_capable")
  ) {
    return true;
  }
  if (profile.sharing_policy === "private_only") return false;

  return grants.some((grant) => {
    if (
      grant.revoked_at ||
      grant.use_permission === false ||
      grant.use_permission === 0
    ) {
      return false;
    }
    if (
      grant.expires_at &&
      new Date(grant.expires_at).getTime() <= now.getTime()
    ) {
      return false;
    }
    if (grant.grantee_type === "user")
      return grant.grantee_id === context.userId;
    if (grant.grantee_type === "workspace")
      return grant.grantee_id === context.workspaceId;
    return (
      grant.grantee_type === "role" &&
      grant.grantee_id === context.workspaceRole
    );
  });
}

export async function authorizeCredentialProfileUse(
  db: DatabaseAdapter,
  context: Pick<
    WorkspaceSecurityContext,
    "userId" | "workspaceId" | "workspaceRole"
  >,
  credentialProfileId: string,
  now = new Date(),
): Promise<void> {
  const profile = await db
    .prepare(
      `SELECT id, workspace_id, owner_type, owner_id, sharing_policy
       FROM credential_profiles WHERE id = ?1 AND workspace_id = ?2`,
    )
    .bind(credentialProfileId, context.workspaceId)
    .first<CredentialProfileAccessRecord>();
  if (!profile)
    throw new AuthorizationError("credential.use", credentialProfileId);

  const grants = await db
    .prepare(
      `SELECT grantee_type, grantee_id, use_permission, expires_at, revoked_at
       FROM credential_grants
       WHERE credential_profile_id = ?1 AND workspace_id = ?2`,
    )
    .bind(credentialProfileId, context.workspaceId)
    .all<CredentialGrantAccessRecord>();
  if (!canUseCredentialProfile(context, profile, grants.results ?? [], now)) {
    throw new AuthorizationError("credential.use", credentialProfileId);
  }
}

/**
 * V5 Account authorization is independent from execution Workspace access.
 * The secret is never returned; this only proves that the requester may use
 * the provider identity for the specified Project.
 */
export async function authorizeProjectAccountUse(
  db: DatabaseAdapter,
  context: Pick<WorkspaceSecurityContext, "userId" | "user" | "suspended">,
  projectId: string,
  accountId: string,
  now = new Date(),
): Promise<void> {
  if (context.suspended || context.user.status !== "active") {
    throw new AuthorizationError("credential.use", accountId);
  }
  const account = await db
    .prepare(
      `SELECT owner_user_id, status, sharing_mode, provider_metadata_json
       FROM ai_accounts WHERE id = ?1`,
    )
    .bind(accountId)
    .first<{
      owner_user_id: string;
      status: string;
      sharing_mode: "private_only" | "project_shared";
      provider_metadata_json: string;
    }>();
  if (!account || account.status !== "ready") {
    throw new AuthorizationError("credential.use", accountId);
  }
  if (account.owner_user_id === context.userId) return;
  let providerMetadata: Record<string, unknown> = {};
  try {
    const parsed: unknown = JSON.parse(account.provider_metadata_json || "{}");
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      providerMetadata = parsed as Record<string, unknown>;
    }
  } catch {
    // Invalid metadata is treated as non-shareable.
    throw new AuthorizationError("credential.use", accountId);
  }
  if (
    account.sharing_mode === "private_only" ||
    providerMetadata.providerSharingPolicy === "private_only"
  ) {
    throw new AuthorizationError("credential.use", accountId);
  }
  const membership = await db
    .prepare(
      `SELECT role FROM project_memberships
       WHERE project_id = ?1 AND user_id = ?2`,
    )
    .bind(projectId, context.userId)
    .first<{ role: ProjectRole }>();
  if (!membership) throw new AuthorizationError("credential.use", accountId);
  const grant = await db
    .prepare(
      `SELECT id FROM project_account_grants
       WHERE project_id = ?1 AND account_id = ?2 AND status = 'active'
         AND (grantee_user_id IS NULL OR grantee_user_id = ?3)
         AND (expires_at IS NULL OR expires_at > ?4)
       ORDER BY CASE WHEN grantee_user_id = ?3 THEN 0 ELSE 1 END
       LIMIT 1`,
    )
    .bind(projectId, accountId, context.userId, now.toISOString())
    .first<{ id: string }>();
  if (!grant) throw new AuthorizationError("credential.use", accountId);
}

export async function authorizeHostWorkspaceBinding(
  db: DatabaseAdapter,
  workspaceId: string,
  hostId: string,
): Promise<void> {
  const binding = await db
    .prepare(
      `SELECT host_id FROM host_workspace_bindings
       WHERE host_id = ?1 AND workspace_id = ?2 AND status = 'active'`,
    )
    .bind(hostId, workspaceId)
    .first<{ host_id: string }>();
  if (!binding) throw new AuthorizationError("host.view", hostId);
}

/**
 * Authorize a Host action through a currently active Workspace binding. The
 * installer is not an ownership principal: every action is re-evaluated from
 * the requester's current membership and role on each request.
 */
export async function authorizeHostWorkspaceAction(
  db: DatabaseAdapter,
  userId: string,
  hostId: string,
  permission: Permission,
): Promise<{ workspaceId: string; role: WorkspaceRole }> {
  const memberships = await db
    .prepare(
      `SELECT b.workspace_id as workspaceId, m.role
       FROM host_workspace_bindings b
       JOIN workspace_memberships m
         ON m.workspace_id = b.workspace_id
        AND m.user_id = ?2
        AND m.status = 'active'
       JOIN hosts h ON h.id = b.host_id AND h.revoked_at IS NULL
       WHERE b.host_id = ?1 AND b.status = 'active'`,
    )
    .bind(hostId, userId)
    .all<{ workspaceId: string; role: WorkspaceRole }>();

  for (const membership of memberships.results ?? []) {
    if (permissionsFor([membership.role]).has(permission)) return membership;
  }
  throw new AuthorizationError(permission, hostId);
}

// =========================================================================
// 3. Cryptographic Token, Hash & PKCE Utilities
// =========================================================================

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

export function bytesToBase64Url(bytes: Uint8Array): string {
  const base64 = btoa(String.fromCharCode(...bytes));
  return base64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function base64UrlToBytes(base64Url: string): Uint8Array {
  let base64 = base64Url.replace(/-/g, "+").replace(/_/g, "/");
  while (base64.length % 4 !== 0) {
    base64 += "=";
  }
  return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
}

/**
 * Generates a cryptographically strong random token.
 */
export function generateSecureToken(byteLength = 32): string {
  const bytes = globalThis.crypto.getRandomValues(new Uint8Array(byteLength));
  return bytesToBase64Url(bytes);
}

/**
 * Hashes a token using SHA-256 for secure storage.
 */
export async function hashToken(token: string): Promise<string> {
  const hashBuffer = await globalThis.crypto.subtle.digest(
    "SHA-256",
    encoder.encode(token),
  );
  return bytesToHex(new Uint8Array(hashBuffer));
}

/**
 * Generates a PKCE code_challenge from a code_verifier using SHA-256.
 */
export async function generatePkceChallenge(
  codeVerifier: string,
): Promise<string> {
  const hashBuffer = await globalThis.crypto.subtle.digest(
    "SHA-256",
    encoder.encode(codeVerifier),
  );
  return bytesToBase64Url(new Uint8Array(hashBuffer));
}

/**
 * Verifies a PKCE code_verifier against a code_challenge.
 */
export async function verifyPkceChallenge(
  codeVerifier: string,
  codeChallenge: string,
  method: "S256" | "plain" = "S256",
): Promise<boolean> {
  if (method === "plain") {
    return codeVerifier === codeChallenge;
  }
  const computed = await generatePkceChallenge(codeVerifier);
  return computed === codeChallenge;
}

/**
 * Constant-time string comparison to prevent timing attacks.
 */
export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

/**
 * Computes SHA-256 digest of binary buffer or string payload.
 * Returns formatted "sha256:<hex>".
 */
export async function computePackageDigest(
  data: Uint8Array | ArrayBuffer | string,
): Promise<string> {
  let bufferSource: BufferSource;
  if (typeof data === "string") {
    bufferSource = encoder.encode(data);
  } else if (data instanceof ArrayBuffer) {
    bufferSource = data;
  } else if (ArrayBuffer.isView(data)) {
    bufferSource = data as BufferSource;
  } else {
    bufferSource = new Uint8Array(data);
  }
  const hashBuffer = await globalThis.crypto.subtle.digest(
    "SHA-256",
    bufferSource,
  );
  return `sha256:${bytesToHex(new Uint8Array(hashBuffer))}`;
}

/**
 * Signs a package digest using HMAC-SHA256 with trusted signing key / secret.
 * Returns formatted "sig_pkg_<hex>".
 */
export async function signPackageDigest(
  digest: string,
  signingKeyOrSecret: string,
): Promise<string> {
  const key = await globalThis.crypto.subtle.importKey(
    "raw",
    encoder.encode(signingKeyOrSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await globalThis.crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(digest),
  );
  return `sig_pkg_${bytesToHex(new Uint8Array(signature))}`;
}

/**
 * Verifies a package digest signature using HMAC-SHA256.
 */
export async function verifyPackageDigestSignature(
  digest: string,
  signature: string,
  signingKeyOrSecret: string,
): Promise<boolean> {
  if (!signature || !signature.startsWith("sig_pkg_")) return false;
  const expectedSig = await signPackageDigest(digest, signingKeyOrSecret);
  return timingSafeEqual(signature, expectedSig);
}

// =========================================================================
// 4. Service Credential Extraction
// =========================================================================

/**
 * Extracts a service credential from an Authorization: Bearer <token> header.
 * Human browser sessions are handled exclusively by Better Auth.
 */
export function extractBearerToken(
  headers: Headers | Record<string, string | undefined>,
): string | null {
  const getHeader = (name: string): string | null => {
    if (typeof (headers as Headers).get === "function") {
      return (headers as Headers).get(name);
    }
    const record = headers as Record<string, string | undefined>;
    return record[name] ?? record[name.toLowerCase()] ?? null;
  };

  // 1. Authorization header: Bearer <token>
  const authHeader = getHeader("authorization");
  if (authHeader) {
    const match = authHeader.match(/^Bearer\s+([A-Za-z0-9\-_.~]+)$/i);
    if (match && match[1]) {
      return match[1];
    }
  }

  return null;
}

// =========================================================================
// 5. Database-Backed Security Context Resolution
// =========================================================================

export interface DatabaseStatement {
  bind(...values: unknown[]): DatabaseStatement;
  first<T = Record<string, unknown>>(): Promise<T | null>;
  all<T = Record<string, unknown>>(): Promise<{ results?: readonly T[] }>;
  run(): Promise<{ success?: boolean }>;
}

export interface DatabaseAdapter {
  prepare(query: string): DatabaseStatement;
}

/** Identity returned by the application authentication boundary. */
export interface AuthenticatedIdentity {
  readonly userId: string;
  readonly email: string;
  readonly name: string;
  readonly sessionId: string;
}

/**
 * Resolve the v5 browser context without a Workspace selector. Every request
 * receives the user's current Project memberships; Workspace ownership is
 * checked only when a specific execution Workspace is addressed.
 */
export async function resolveProjectSecurityContextFromIdentity(
  db: DatabaseAdapter,
  identity: AuthenticatedIdentity,
): Promise<WorkspaceSecurityContext> {
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
  if (userRow.status !== "active") {
    throw new AuthenticationError(`User account is ${userRow.status}`);
  }

  const user: AuthenticatedUser = {
    id: userRow.id,
    email: userRow.email,
    displayName: userRow.display_name,
    avatarUrl: userRow.avatar_url,
    status: userRow.status as AuthenticatedUser["status"],
  };
  const memberships = await db
    .prepare(
      `SELECT project_id, role
       FROM project_memberships
       WHERE user_id = ?1`,
    )
    .bind(user.id)
    .all<{ project_id: string; role: ProjectRole }>()
    .catch(() => ({ results: [] }));
  const authorizedProjectIds: string[] = [];
  const projectRoles: Record<string, ProjectRole> = {};
  for (const membership of memberships.results ?? []) {
    authorizedProjectIds.push(membership.project_id);
    projectRoles[membership.project_id] = membership.role;
  }
  const workspaces = await db
    .prepare(
      "SELECT id FROM execution_workspaces WHERE owner_user_id = ?1 AND status <> 'revoked'",
    )
    .bind(user.id)
    .all<{ id: string }>()
    .catch(() => ({ results: [] }));
  const accounts = await db
    .prepare("SELECT id FROM ai_accounts WHERE owner_user_id = ?1")
    .bind(user.id)
    .all<{ id: string }>()
    .catch(() => ({ results: [] }));

  return {
    userId: user.id,
    user,
    // Compatibility fields are deliberately empty: v5 has no active browser
    // Workspace selection or Workspace role inheritance.
    workspaceId: "",
    workspaceRole: "viewer",
    roles: ["viewer"],
    authorizedProjectIds,
    projectRoles,
    sessionId: identity.sessionId,
    clientType: "web",
    organizationId: "",
    organizationRoles: ["viewer"],
    authorizationModel: "v5",
    ownedWorkspaceIds: (workspaces.results ?? []).map((row) => row.id),
    ownedAccountIds: (accounts.results ?? []).map((row) => row.id),
  };
}

/**
 * Resolve Conclave authorization from an already-authenticated human.
 * Better Auth is deliberately not imported here: this package owns only the
 * User -> Workspace -> Project authorization boundary.
 */
export async function resolveSecurityContextFromIdentity(
  db: DatabaseAdapter,
  identity: AuthenticatedIdentity,
  options?: { requestedWorkspaceId?: string },
): Promise<WorkspaceSecurityContext> {
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
  if (userRow.status !== "active") {
    throw new AuthenticationError(`User account is ${userRow.status}`);
  }

  return resolveWorkspaceSecurityContext(
    db,
    {
      id: userRow.id,
      email: userRow.email,
      displayName: userRow.display_name,
      avatarUrl: userRow.avatar_url,
      status: userRow.status,
    },
    identity.sessionId,
    "web",
    options,
  );
}

async function resolveWorkspaceSecurityContext(
  db: DatabaseAdapter,
  user: AuthenticatedUser,
  sessionId: string,
  clientType: ClientType,
  options?: { requestedWorkspaceId?: string },
): Promise<WorkspaceSecurityContext> {
  let memberships: {
    results?: readonly {
      workspace_id: string;
      role: WorkspaceRole;
      workspace_status: string;
    }[];
  };
  try {
    memberships = await db
      .prepare(
        `SELECT wm.workspace_id, wm.role, w.status AS workspace_status
         FROM workspace_memberships wm
         JOIN workspaces w ON wm.workspace_id = w.id
         WHERE wm.user_id = ?1 AND wm.status = 'active' AND w.status = 'active'`,
      )
      .bind(user.id)
      .all();
  } catch {
    memberships = await db
      .prepare(
        `SELECT wm.workspace_id, wm.role, w.status AS workspace_status
         FROM workspace_memberships wm
         JOIN workspaces w ON wm.workspace_id = w.id
         WHERE wm.user_id = ?1 AND w.status = 'active'`,
      )
      .bind(user.id)
      .all();
  }

  const activeMemberships = memberships.results ?? [];
  if (activeMemberships.length === 0) {
    if (options?.requestedWorkspaceId) {
      throw new AuthorizationError(
        "workspace:manage",
        options.requestedWorkspaceId,
      );
    }
    return {
      userId: user.id,
      user,
      workspaceId: "",
      workspaceRole: "viewer",
      roles: ["viewer"],
      authorizedProjectIds: [],
      projectRoles: {},
      sessionId,
      clientType,
      organizationId: "",
      organizationRoles: ["viewer"],
    };
  }

  const targetMembership = options?.requestedWorkspaceId
    ? activeMemberships.find(
        (membership) =>
          membership.workspace_id === options.requestedWorkspaceId,
      )
    : activeMemberships[0];
  if (!targetMembership) {
    throw new AuthorizationError(
      "workspace:manage",
      options?.requestedWorkspaceId,
    );
  }

  const workspaceId = targetMembership.workspace_id;
  const workspaceRole = targetMembership.role;
  let authorizedProjectIds: string[] = [];
  const projectRoles: Record<string, ProjectRole> = {};

  if (workspaceRole === "owner" || workspaceRole === "admin") {
    const allProjects = await db
      .prepare("SELECT id FROM projects WHERE workspace_id = ?1")
      .bind(workspaceId)
      .all<{ id: string }>();
    authorizedProjectIds = (allProjects.results ?? []).map(
      (project) => project.id,
    );
  } else {
    const projectMemberships = await db
      .prepare(
        `SELECT pm.project_id, pm.role
         FROM project_memberships pm
         JOIN projects p ON pm.project_id = p.id
         WHERE pm.user_id = ?1 AND p.workspace_id = ?2`,
      )
      .bind(user.id, workspaceId)
      .all<{ project_id: string; role: ProjectRole }>();
    for (const membership of projectMemberships.results ?? []) {
      authorizedProjectIds.push(membership.project_id);
      projectRoles[membership.project_id] = membership.role;
    }
  }

  return {
    userId: user.id,
    user,
    workspaceId,
    workspaceRole,
    roles: [workspaceRole],
    authorizedProjectIds,
    projectRoles,
    sessionId,
    clientType,
    organizationId: workspaceId,
    organizationRoles: [workspaceRole],
  };
}

// =========================================================================
// 6. Rate Limiting, Budgets, Credentials & Retention
// =========================================================================

export interface RateLimitPolicy {
  readonly requests: number;
  readonly windowSeconds: number;
}

export interface RateLimitDecision {
  readonly allowed: boolean;
  readonly remaining: number;
  readonly resetAt: string;
  readonly retryAfterSeconds: number;
}

export function consumeRateLimit(
  state: { count: number; windowStartedAt: number },
  policy: RateLimitPolicy,
  nowMs = Date.now(),
): RateLimitDecision {
  const windowMs = policy.windowSeconds * 1000;
  if (nowMs - state.windowStartedAt >= windowMs) {
    state.count = 0;
    state.windowStartedAt = nowMs;
  }
  const resetAtMs = state.windowStartedAt + windowMs;
  const allowed = state.count < policy.requests;
  if (allowed) state.count += 1;
  return {
    allowed,
    remaining: Math.max(0, policy.requests - state.count),
    resetAt: new Date(resetAtMs).toISOString(),
    retryAfterSeconds: Math.max(0, Math.ceil((resetAtMs - nowMs) / 1000)),
  };
}

export interface EncryptedCredentialEnvelope {
  readonly version: 1;
  readonly algorithm: "AES-GCM";
  readonly keyId: string;
  readonly iv: string;
  readonly ciphertext: string;
  readonly createdAt: string;
  readonly expiresAt?: string;
}

export async function encryptCredential(
  plaintext: string,
  key: CryptoKey,
  keyId: string,
  expiresAt?: string,
): Promise<EncryptedCredentialEnvelope> {
  const iv = globalThis.crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await globalThis.crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    key,
    encoder.encode(plaintext),
  );
  return {
    version: 1,
    algorithm: "AES-GCM",
    keyId,
    iv: bytesToBase64Url(iv),
    ciphertext: bytesToBase64Url(new Uint8Array(ciphertext)),
    createdAt: new Date().toISOString(),
    ...(expiresAt ? { expiresAt } : {}),
  };
}

export async function decryptCredential(
  envelope: EncryptedCredentialEnvelope,
  key: CryptoKey,
): Promise<string> {
  if (envelope.version !== 1 || envelope.algorithm !== "AES-GCM") {
    throw new Error("Unsupported credential envelope");
  }
  const plaintext = await globalThis.crypto.subtle.decrypt(
    {
      name: "AES-GCM",
      iv: base64UrlToBytes(envelope.iv) as BufferSource,
    },
    key,
    base64UrlToBytes(envelope.ciphertext) as BufferSource,
  );
  return decoder.decode(plaintext);
}

export interface RetentionPolicy {
  readonly auditDays: number;
  readonly artifactDays: number;
  readonly usageDays: number;
}

export function retentionExpiresAt(createdAt: string, days: number): string {
  return new Date(
    new Date(createdAt).getTime() + days * 86_400_000,
  ).toISOString();
}

export function isRetained(expiresAt: string, nowMs = Date.now()): boolean {
  return new Date(expiresAt).getTime() > nowMs;
}

export interface AuditRecord {
  readonly id: string;
  readonly workspaceId: string;
  readonly actorUserId: string | null;
  readonly action: string;
  readonly resourceType: string;
  readonly resourceId: string | null;
  readonly outcome: "success" | "denied" | "failure";
  readonly metadata: Readonly<Record<string, string | number | boolean | null>>;
  readonly occurredAt: string;
  readonly retentionUntil: string;
}

// =========================================================================
// 7. External-user hardening primitives
// =========================================================================

export const DEFAULT_PLUGIN_PERMISSION_ALLOWLIST = [
  "workspace:read",
  "workspace:write",
  "network:outbound",
  "process:spawn",
  "git:read",
  "git:write",
] as const;

export function assertAllowedPermissions(
  requested: readonly string[],
  allowed: readonly string[] = DEFAULT_PLUGIN_PERMISSION_ALLOWLIST,
): void {
  const allowedSet = new Set(allowed);
  const forbidden = requested.filter(
    (permission) => !allowedSet.has(permission),
  );
  if (forbidden.length > 0) {
    throw new AuthorizationError("workspace:manage");
  }
}

export interface CredentialRotationPolicy {
  readonly maxAgeDays: number;
  readonly overlapGraceDays: number;
}

export function credentialExpiresAt(
  issuedAt: string,
  policy: CredentialRotationPolicy,
): string {
  return new Date(
    new Date(issuedAt).getTime() + policy.maxAgeDays * 86_400_000,
  ).toISOString();
}

export function isCredentialRotationRequired(
  issuedAt: string,
  policy: CredentialRotationPolicy,
  nowMs = Date.now(),
): boolean {
  return new Date(credentialExpiresAt(issuedAt, policy)).getTime() <= nowMs;
}

export class SlidingWindowRateLimiter {
  private readonly windows = new Map<
    string,
    { count: number; windowStartedAt: number }
  >();

  consume(
    key: string,
    policy: RateLimitPolicy,
    nowMs = Date.now(),
  ): RateLimitDecision {
    const state = this.windows.get(key) ?? { count: 0, windowStartedAt: nowMs };
    const decision = consumeRateLimit(state, policy, nowMs);
    this.windows.set(key, state);
    return decision;
  }

  clear(key?: string): void {
    if (key) this.windows.delete(key);
    else this.windows.clear();
  }
}

export interface RetentionExportManifest {
  readonly format: "conclave-retention-export-v1";
  readonly workspaceId: string;
  readonly exportedAt: string;
  readonly includes: readonly string[];
  readonly encrypted: boolean;
}

export function createRetentionExportManifest(
  workspaceId: string,
  exportedAt = new Date().toISOString(),
): RetentionExportManifest {
  return {
    format: "conclave-retention-export-v1",
    workspaceId,
    exportedAt,
    includes: ["goals", "runs", "events", "artifacts", "audit", "usage"],
    encrypted: true,
  };
}
