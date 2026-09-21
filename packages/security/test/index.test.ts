import { describe, expect, it } from "vitest";
import {
  authorize,
  canAccessProject,
  generateSecureToken,
  hashToken,
  generatePkceChallenge,
  verifyPkceChallenge,
  extractAuthToken,
  formatSessionCookie,
  resolveSecurityContextFromDb,
  encryptCredential,
  decryptCredential,
  consumeRateLimit,
  assertWithinBudget,
  computePackageDigest,
  signPackageDigest,
  verifyPackageDigestSignature,
  assertAllowedPermissions,
  credentialExpiresAt,
  isCredentialRotationRequired,
  SlidingWindowRateLimiter,
  createRetentionExportManifest,
  AuthorizationError,
  AuthenticationError,
  type WorkspaceSecurityContext,
  type DatabaseAdapter,
} from "../src/index.js";

describe("Architecture v2 Security & Authentication Suite", () => {
  const sampleUser = {
    id: "user-123",
    email: "dev@conclaveax.com",
    displayName: "Lead Developer",
    status: "active" as const,
  };

  const sampleContext: WorkspaceSecurityContext = {
    userId: "user-123",
    user: sampleUser,
    workspaceId: "ws-primary",
    workspaceRole: "member",
    roles: ["member"],
    authorizedProjectIds: ["proj-conclave", "proj-mobile"],
    projectRoles: {
      "proj-conclave": "lead",
      "proj-mobile": "collaborator",
    },
    sessionId: "sess-abc",
    clientType: "desktop",
    organizationId: "ws-primary",
    organizationRoles: ["member"],
  };

  describe("Role & Project Authorizations", () => {
    it("allows member to read and write authorized projects", () => {
      expect(() =>
        authorize(sampleContext, "projects:read", "proj-conclave"),
      ).not.toThrow();
      expect(() =>
        authorize(sampleContext, "projects:write", "proj-conclave"),
      ).not.toThrow();
    });

    it("denies access to unauthorized projects", () => {
      expect(() =>
        authorize(sampleContext, "projects:read", "proj-secret"),
      ).toThrow(AuthorizationError);
    });

    it("denies administrative operations to regular member", () => {
      expect(() => authorize(sampleContext, "workspace:manage")).toThrow(
        AuthorizationError,
      );
      expect(() => authorize(sampleContext, "members:manage")).toThrow(
        AuthorizationError,
      );
    });

    it("allows owner full workspace and project access", () => {
      const ownerContext: WorkspaceSecurityContext = {
        ...sampleContext,
        workspaceRole: "owner",
        roles: ["owner"],
        authorizedProjectIds: ["proj-conclave"],
        projectRoles: {},
        organizationRoles: ["owner"],
      };

      expect(() => authorize(ownerContext, "workspace:manage")).not.toThrow();
      expect(() => authorize(ownerContext, "members:manage")).not.toThrow();
      // Owner has automatic access to any project in workspace
      expect(canAccessProject(ownerContext, "proj-unlisted")).toBe(true);
    });
  });

  describe("Cryptographic Token & PKCE Utilities", () => {
    it("generates random secure tokens and reproducible SHA-256 hashes", async () => {
      const token = generateSecureToken(32);
      expect(typeof token).toBe("string");
      expect(token.length).toBeGreaterThan(30);

      const hash1 = await hashToken(token);
      const hash2 = await hashToken(token);
      expect(hash1).toBe(hash2);
      expect(hash1.length).toBe(64); // 32 bytes in hex = 64 chars
    });

    it("generates and verifies valid S256 PKCE challenges", async () => {
      const codeVerifier = generateSecureToken(32);
      const challenge = await generatePkceChallenge(codeVerifier);

      const valid = await verifyPkceChallenge(codeVerifier, challenge, "S256");
      expect(valid).toBe(true);

      const invalid = await verifyPkceChallenge(
        "wrong-verifier",
        challenge,
        "S256",
      );
      expect(invalid).toBe(false);
    });
  });

  describe("Header & Cookie Session Extraction", () => {
    it("extracts token from Authorization Bearer header", () => {
      const headers = new Headers({
        authorization: "Bearer token-xyz-123",
      });
      expect(extractAuthToken(headers)).toBe("token-xyz-123");
    });

    it("extracts token from Cookie header", () => {
      const headers = {
        cookie: "other=123; conclave_session=cookie-session-token; theme=dark",
      };
      expect(extractAuthToken(headers)).toBe("cookie-session-token");
    });

    it("formats secure HttpOnly Set-Cookie header", () => {
      const cookie = formatSessionCookie("test-token", {
        secure: true,
        maxAgeSeconds: 3600,
      });
      expect(cookie).toContain("conclave_session=test-token");
      expect(cookie).toContain("HttpOnly");
      expect(cookie).toContain("Secure");
      expect(cookie).toContain("Max-Age=3600");
    });
  });

  describe("Database-Backed Security Context Resolution", () => {
    function createMockDb(token: string, tokenHash: string): DatabaseAdapter {
      return {
        prepare(query: string) {
          let boundValues: unknown[] = [];
          return {
            bind(...values: unknown[]) {
              boundValues = values;
              return this;
            },
            async first<T>() {
              if (query.includes("FROM auth_sessions s")) {
                if (boundValues[0] === tokenHash) {
                  return {
                    session_id: "sess-1",
                    user_id: "user-1",
                    client_type: "desktop",
                    expires_at: "2099-01-01T00:00:00Z",
                    revoked_at: null,
                    u_id: "user-1",
                    email: "dev@conclaveax.com",
                    display_name: "Alice",
                    avatar_url: null,
                    user_status: "active",
                  } as T;
                }
                return null;
              }
              return null;
            },
            async all<T>() {
              if (query.includes("FROM workspace_memberships wm")) {
                return {
                  results: [
                    {
                      workspace_id: "ws-personal",
                      role: "owner",
                      workspace_status: "active",
                    },
                    {
                      workspace_id: "ws-team",
                      role: "member",
                      workspace_status: "active",
                    },
                  ] as unknown as readonly T[],
                };
              }
              if (query.includes("FROM project_memberships pm")) {
                return {
                  results: [
                    { project_id: "proj-1", role: "lead" },
                  ] as unknown as readonly T[],
                };
              }
              if (query.includes("FROM projects WHERE workspace_id")) {
                return {
                  results: [
                    { id: "proj-1" },
                    { id: "proj-2" },
                  ] as unknown as readonly T[],
                };
              }
              return { results: [] };
            },
            async run() {
              return { success: true };
            },
          };
        },
      };
    }

    it("resolves security context with active workspace, roles and authorized projects", async () => {
      const token = "valid-session-token";
      const tokenHash = await hashToken(token);
      const mockDb = createMockDb(token, tokenHash);

      const ctx = await resolveSecurityContextFromDb(mockDb, token, {
        requestedWorkspaceId: "ws-personal",
      });

      expect(ctx.userId).toBe("user-1");
      expect(ctx.workspaceId).toBe("ws-personal");
      expect(ctx.workspaceRole).toBe("owner");
      expect(ctx.roles).toEqual(["owner"]);
      // Owner automatically gets all workspace projects
      expect(ctx.authorizedProjectIds).toEqual(["proj-1", "proj-2"]);
    });

    it("resolves member workspace with explicit project memberships", async () => {
      const token = "valid-session-token";
      const tokenHash = await hashToken(token);
      const mockDb = createMockDb(token, tokenHash);

      const ctx = await resolveSecurityContextFromDb(mockDb, token, {
        requestedWorkspaceId: "ws-team",
      });

      expect(ctx.workspaceId).toBe("ws-team");
      expect(ctx.workspaceRole).toBe("member");
      expect(ctx.authorizedProjectIds).toEqual(["proj-1"]);
      expect(ctx.projectRoles).toEqual({ "proj-1": "lead" });
    });

    it("rejects token when user is not a member of requested workspace", async () => {
      const token = "valid-session-token";
      const tokenHash = await hashToken(token);
      const mockDb = createMockDb(token, tokenHash);

      await expect(
        resolveSecurityContextFromDb(mockDb, token, {
          requestedWorkspaceId: "ws-unauthorized",
        }),
      ).rejects.toThrow(AuthorizationError);
    });

    it("rejects invalid or non-existent token", async () => {
      const token = "unknown-token";
      const mockDb = createMockDb("token", "different-hash");

      await expect(resolveSecurityContextFromDb(mockDb, token)).rejects.toThrow(
        AuthenticationError,
      );
    });
  });

  describe("Encrypted Credentials, Rate Limiting & Budgets", () => {
    it("encrypts and decrypts credentials with AES-GCM", async () => {
      const cryptoKey = await globalThis.crypto.subtle.generateKey(
        { name: "AES-GCM", length: 256 },
        true,
        ["encrypt", "decrypt"],
      );

      const envelope = await encryptCredential(
        "sk-secret-token",
        cryptoKey,
        "key-1",
      );
      expect(envelope.algorithm).toBe("AES-GCM");

      const decrypted = await decryptCredential(envelope, cryptoKey);
      expect(decrypted).toBe("sk-secret-token");
    });

    it("enforces rate limits", () => {
      const state = { count: 0, windowStartedAt: Date.now() };
      const policy = { requests: 2, windowSeconds: 60 };

      const r1 = consumeRateLimit(state, policy);
      expect(r1.allowed).toBe(true);
      const r2 = consumeRateLimit(state, policy);
      expect(r2.allowed).toBe(true);
      const r3 = consumeRateLimit(state, policy);
      expect(r3.allowed).toBe(false);
    });

    it("enforces budget limits", () => {
      const current = { inputTokens: 100, outputTokens: 50, costMicros: 1000 };
      const next = { inputTokens: 50, outputTokens: 25, costMicros: 500 };
      const policy = { maxCostMicros: 2000 };

      const total = assertWithinBudget(policy, current, next);
      expect(total.costMicros).toBe(1500);

      expect(() =>
        assertWithinBudget({ maxCostMicros: 1200 }, current, next),
      ).toThrow(/Budget exceeded/);
    });

    it("computes package digest, generates HMAC signature, and verifies successfully", async () => {
      const packageContent = "console.log('hello world plugin');";
      const digest = await computePackageDigest(packageContent);
      expect(digest).toMatch(/^sha256:[a-f0-9]{64}$/);

      const secret = "platform_signing_secret_key_123456";
      const signature = await signPackageDigest(digest, secret);
      expect(signature).toMatch(/^sig_pkg_[a-f0-9]{64}$/);

      const isValid = await verifyPackageDigestSignature(
        digest,
        signature,
        secret,
      );
      expect(isValid).toBe(true);

      const isInvalidSecret = await verifyPackageDigestSignature(
        digest,
        signature,
        "wrong_secret",
      );
      expect(isInvalidSecret).toBe(false);

      const isInvalidDigest = await verifyPackageDigestSignature(
        "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        signature,
        secret,
      );
      expect(isInvalidDigest).toBe(false);
    });

    it("enforces hardening primitives", () => {
      expect(() => assertAllowedPermissions(["workspace:read"])).not.toThrow();
      expect(() => assertAllowedPermissions(["credential:export"])).toThrow();

      const issuedAt = "2026-01-01T00:00:00.000Z";
      expect(
        credentialExpiresAt(issuedAt, { maxAgeDays: 30, overlapGraceDays: 2 }),
      ).toBe("2026-01-31T00:00:00.000Z");
      expect(
        isCredentialRotationRequired(
          issuedAt,
          { maxAgeDays: 30, overlapGraceDays: 2 },
          Date.parse("2026-02-01T00:00:00.000Z"),
        ),
      ).toBe(true);

      const limiter = new SlidingWindowRateLimiter();
      expect(
        limiter.consume("user-1", { requests: 1, windowSeconds: 60 }, 1_000)
          .allowed,
      ).toBe(true);
      expect(
        limiter.consume("user-1", { requests: 1, windowSeconds: 60 }, 2_000)
          .allowed,
      ).toBe(false);
      expect(
        limiter.consume("user-1", { requests: 1, windowSeconds: 60 }, 62_000)
          .allowed,
      ).toBe(true);

      expect(createRetentionExportManifest("ws-1")).toMatchObject({
        format: "conclave-retention-export-v1",
        workspaceId: "ws-1",
        encrypted: true,
      });
    });
  });
});
