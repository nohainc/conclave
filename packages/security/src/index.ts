/**
 * Conclave AX Architecture v2 Security, Authentication & Multi-Tenancy Engine.
 *
 * Enforces:
 * User -> Workspace -> Project hierarchy
 * Roles: owner, admin, member, viewer
 * Secure browser sessions + Desktop OAuth/PKCE authorization code flow.
 */

// =========================================================================
// 1. Roles & Permissions Model
// =========================================================================

export const WORKSPACE_ROLES = ["owner", "admin", "member", "viewer"] as const;
export type WorkspaceRole = (typeof WORKSPACE_ROLES)[number];

export const PROJECT_ROLES = ["lead", "collaborator", "viewer"] as const;
export type ProjectRole = (typeof PROJECT_ROLES)[number];

// Legacy alias for compatibility
export const ROLES = WORKSPACE_ROLES;
export type Role = WorkspaceRole;

export const PERMISSIONS = [
  "workspace:manage",
  "members:manage",
  "billing:manage",
  "projects:manage",
  "projects:read",
  "projects:write",
  "agents:manage",
  "agents:read",
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
    "members:manage",
    "projects:manage",
    "projects:read",
    "projects:write",
    "agents:manage",
    "agents:read",
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
    "projects:read",
    "projects:write",
    "agents:read",
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
    "projects:read",
    "agents:read",
    "workers:read",
    "chats:read",
    "project:read",
  ],
};

export const PROJECT_ROLE_PERMISSIONS: Record<
  ProjectRole,
  readonly Permission[]
> = {
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
  // Owners and Admins have workspace-wide project access
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
// 4. Session Tokens & Header/Cookie Extraction
// =========================================================================

export const SESSION_COOKIE_NAME = "conclave_session";

/**
 * Extracts session token from Authorization: Bearer <token> or Cookie header.
 */
export function extractAuthToken(
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

  // 2. Cookie header: conclave_session=<token>
  const cookieHeader = getHeader("cookie");
  if (cookieHeader) {
    const cookies = cookieHeader.split(";").map((c) => c.trim());
    for (const cookie of cookies) {
      const [name, val] = cookie.split("=");
      if (name === SESSION_COOKIE_NAME && val) {
        return val;
      }
    }
  }

  return null;
}

/**
 * Creates a Set-Cookie header value for secure session storage in browser.
 */
export function formatSessionCookie(
  token: string,
  options: {
    maxAgeSeconds?: number;
    secure?: boolean;
    sameSite?: "Strict" | "Lax" | "None";
    path?: string;
    domain?: string;
  } = {},
): string {
  const {
    maxAgeSeconds = 30 * 24 * 60 * 60, // 30 days default
    secure = true,
    sameSite = "Lax",
    path = "/",
    domain,
  } = options;

  const parts = [
    `${SESSION_COOKIE_NAME}=${token}`,
    `Path=${path}`,
    `Max-Age=${maxAgeSeconds}`,
    `SameSite=${sameSite}`,
    "HttpOnly",
  ];

  if (secure) parts.push("Secure");
  if (domain) parts.push(`Domain=${domain}`);

  return parts.join("; ");
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

export async function resolveSecurityContextFromDb(
  db: DatabaseAdapter,
  token: string,
  options?: { requestedWorkspaceId?: string },
): Promise<WorkspaceSecurityContext> {
  const tokenHash = await hashToken(token);
  const now = new Date().toISOString();

  // 1. Resolve auth session
  const session = await db
    .prepare(
      `SELECT s.id AS session_id, s.user_id, s.client_type, s.expires_at, s.revoked_at,
              u.id AS u_id, u.email, u.display_name, u.avatar_url, u.status AS user_status
       FROM auth_sessions s
       JOIN users u ON s.user_id = u.id
       WHERE s.token_hash = ?1`,
    )
    .bind(tokenHash)
    .first<{
      session_id: string;
      user_id: string;
      client_type: ClientType;
      expires_at: string;
      revoked_at: string | null;
      u_id: string;
      email: string;
      display_name: string;
      avatar_url: string | null;
      user_status: string;
    }>();

  if (!session) {
    throw new AuthenticationError("Invalid authentication token");
  }

  if (session.revoked_at || session.expires_at < now) {
    throw new AuthenticationError("Session expired or revoked");
  }

  if (session.user_status !== "active") {
    throw new AuthenticationError(`User account is ${session.user_status}`);
  }

  const user: AuthenticatedUser = {
    id: session.u_id,
    email: session.email,
    displayName: session.display_name,
    avatarUrl: session.avatar_url,
    status: session.user_status as "active",
  };

  // 2. Resolve Workspace Memberships
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
    // Development databases created before V2-21 do not have membership status.
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
      sessionId: session.session_id,
      clientType: session.client_type,
      organizationId: "",
      organizationRoles: ["viewer"],
    };
  }

  // 3. Select Target Workspace
  const targetMembership = options?.requestedWorkspaceId
    ? activeMemberships.find(
        (m) => m.workspace_id === options.requestedWorkspaceId,
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

  // 4. Resolve Project Access
  let authorizedProjectIds: string[] = [];
  const projectRoles: Record<string, ProjectRole> = {};

  if (workspaceRole === "owner" || workspaceRole === "admin") {
    // Owners and Admins have access to all projects in workspace
    const allProjects = await db
      .prepare("SELECT id FROM projects WHERE workspace_id = ?1")
      .bind(workspaceId)
      .all<{ id: string }>();
    authorizedProjectIds = (allProjects.results ?? []).map((p) => p.id);
  } else {
    // Members & Viewers resolve explicit project memberships
    const projectMems = await db
      .prepare(
        `SELECT pm.project_id, pm.role
         FROM project_memberships pm
         JOIN projects p ON pm.project_id = p.id
         WHERE pm.user_id = ?1 AND p.workspace_id = ?2`,
      )
      .bind(user.id, workspaceId)
      .all<{ project_id: string; role: ProjectRole }>();

    for (const pm of projectMems.results ?? []) {
      authorizedProjectIds.push(pm.project_id);
      projectRoles[pm.project_id] = pm.role;
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
    sessionId: session.session_id,
    clientType: session.client_type,
    // Backward compatibility aliases
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

export interface UsageTotals {
  readonly inputTokens: number;
  readonly outputTokens: number;
  readonly costMicros: number;
}

export interface BudgetPolicy {
  readonly maxInputTokens?: number;
  readonly maxOutputTokens?: number;
  readonly maxCostMicros?: number;
}

export class BudgetExceededError extends Error {
  readonly code = "BUDGET_EXCEEDED";
  constructor(readonly field: keyof UsageTotals) {
    super(`Budget exceeded for ${field}`);
    this.name = "BudgetExceededError";
  }
}

export function assertWithinBudget(
  policy: BudgetPolicy,
  current: UsageTotals,
  next: UsageTotals,
): UsageTotals {
  const total = {
    inputTokens: current.inputTokens + next.inputTokens,
    outputTokens: current.outputTokens + next.outputTokens,
    costMicros: current.costMicros + next.costMicros,
  };
  if (
    policy.maxInputTokens !== undefined &&
    total.inputTokens > policy.maxInputTokens
  )
    throw new BudgetExceededError("inputTokens");
  if (
    policy.maxOutputTokens !== undefined &&
    total.outputTokens > policy.maxOutputTokens
  )
    throw new BudgetExceededError("outputTokens");
  if (
    policy.maxCostMicros !== undefined &&
    total.costMicros > policy.maxCostMicros
  )
    throw new BudgetExceededError("costMicros");
  return total;
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
  const forbidden = requested.filter((permission) => !allowedSet.has(permission));
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
  private readonly windows = new Map<string, { count: number; windowStartedAt: number }>();

  consume(key: string, policy: RateLimitPolicy, nowMs = Date.now()): RateLimitDecision {
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
