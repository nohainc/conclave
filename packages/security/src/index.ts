export const ROLES = [
  "owner",
  "admin",
  "operator",
  "reviewer",
  "member",
  "viewer",
] as const;
export type Role = (typeof ROLES)[number];

export const PERMISSIONS = [
  "org:manage",
  "project:read",
  "project:write",
  "run:create",
  "run:control",
  "workers:manage",
  "secrets:manage",
  "audit:read",
  "usage:read",
] as const;
export type Permission = (typeof PERMISSIONS)[number];

const ROLE_PERMISSIONS: Record<Role, readonly Permission[]> = {
  owner: PERMISSIONS,
  admin: [
    "org:manage",
    "project:read",
    "project:write",
    "run:create",
    "run:control",
    "workers:manage",
    "secrets:manage",
    "audit:read",
    "usage:read",
  ],
  operator: ["project:read", "run:create", "run:control", "usage:read"],
  reviewer: ["project:read", "audit:read", "usage:read"],
  member: ["project:read", "project:write", "run:create"],
  viewer: ["project:read"],
};

export interface SecurityContext {
  readonly userId: string;
  readonly organizationId: string;
  readonly organizationRoles: readonly Role[];
  readonly projectRoles: Readonly<Record<string, readonly Role[]>>;
  readonly suspended?: boolean;
}

export class AuthorizationError extends Error {
  readonly code = "FORBIDDEN";

  constructor(permission: Permission, resourceId?: string) {
    super(
      `Permission ${permission} is required${resourceId ? ` for ${resourceId}` : ""}`,
    );
    this.name = "AuthorizationError";
  }
}

export function permissionsFor(
  roles: readonly Role[],
): ReadonlySet<Permission> {
  return new Set(roles.flatMap((role) => ROLE_PERMISSIONS[role]));
}

export function canAccessProject(
  context: SecurityContext,
  projectId: string,
): boolean {
  if (context.suspended) return false;
  const organizationPermissions = permissionsFor(context.organizationRoles);
  if (organizationPermissions.has("org:manage")) return true;
  return context.projectRoles[projectId] !== undefined;
}

export function authorize(
  context: SecurityContext,
  permission: Permission,
  projectId?: string,
): void {
  if (context.suspended) throw new AuthorizationError(permission, projectId);
  const roles = projectId
    ? (context.projectRoles[projectId] ?? context.organizationRoles)
    : context.organizationRoles;
  if (projectId && !canAccessProject(context, projectId)) {
    throw new AuthorizationError(permission, projectId);
  }
  if (!permissionsFor(roles).has(permission)) {
    throw new AuthorizationError(permission, projectId);
  }
}

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

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const bytesToBase64 = (bytes: Uint8Array): string =>
  btoa(String.fromCharCode(...bytes));
const base64ToBytes = (value: string): Uint8Array =>
  Uint8Array.from(atob(value), (character) => character.charCodeAt(0));

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
    iv: bytesToBase64(iv),
    ciphertext: bytesToBase64(new Uint8Array(ciphertext)),
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
      iv: base64ToBytes(envelope.iv) as BufferSource,
    },
    key,
    base64ToBytes(envelope.ciphertext) as BufferSource,
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
  readonly organizationId: string;
  readonly actorUserId: string | null;
  readonly action: string;
  readonly resourceType: string;
  readonly resourceId: string | null;
  readonly outcome: "success" | "denied" | "failure";
  readonly metadata: Readonly<Record<string, string | number | boolean | null>>;
  readonly occurredAt: string;
  readonly retentionUntil: string;
}
