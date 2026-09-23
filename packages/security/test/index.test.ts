import { describe, expect, it } from "vitest";
import {
  authorize,
  canAccessProject,
  generateSecureToken,
  hashToken,
  generatePkceChallenge,
  verifyPkceChallenge,
  extractBearerToken,
  resolveSecurityContextFromIdentity,
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
  canUseCredentialProfile,
  authorizeCredentialProfileUse,
  authorizeHostWorkspaceBinding,
  authorizeHostWorkspaceAction,
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

    it("uses canonical v4 permissions: members use, administrators manage", () => {
      expect(() => authorize(sampleContext, "credential.use")).not.toThrow();
      expect(() => authorize(sampleContext, "run.start")).not.toThrow();
      expect(() => authorize(sampleContext, "host.manage")).toThrow(
        AuthorizationError,
      );
      expect(() => authorize(sampleContext, "worker.install")).toThrow(
        AuthorizationError,
      );

      const adminContext = {
        ...sampleContext,
        workspaceRole: "admin" as const,
        roles: ["admin" as const],
      };
      expect(() => authorize(adminContext, "host.manage")).not.toThrow();
      expect(() => authorize(adminContext, "credential.share")).not.toThrow();
      expect(() => authorize(sampleContext, "host.use")).not.toThrow();
      expect(() => authorize(sampleContext, "host.revoke")).toThrow(
        AuthorizationError,
      );
      expect(() => authorize(sampleContext, "worker.manage_on_host")).toThrow(
        AuthorizationError,
      );
      expect(() =>
        authorize(adminContext, "host.bind_workspace"),
      ).not.toThrow();
      expect(() => authorize(adminContext, "host.revoke")).not.toThrow();
      expect(() =>
        authorize(adminContext, "worker.manage_on_host"),
      ).not.toThrow();
    });

    it("authorizes Host management through a current active binding", async () => {
      const db: DatabaseAdapter = {
        prepare(query: string) {
          return {
            bind() {
              return this;
            },
            async first<T>() {
              return null as T;
            },
            async all<T>() {
              return query.includes("host_workspace_bindings")
                ? ({
                    results: [{ workspaceId: "ws-primary", role: "admin" }],
                  } as { results: T[] })
                : ({ results: [] } as { results: T[] });
            },
            async run() {
              return { success: true };
            },
          };
        },
      };
      await expect(
        authorizeHostWorkspaceAction(db, "user-123", "host-a", "host.manage"),
      ).resolves.toEqual({ workspaceId: "ws-primary", role: "admin" });
      await expect(
        authorizeHostWorkspaceAction(db, "user-123", "host-a", "host.revoke"),
      ).resolves.toEqual({ workspaceId: "ws-primary", role: "admin" });
    });

    it("denies private profiles and accepts explicit user/workspace grants", () => {
      const profile = {
        id: "profile-a",
        workspace_id: "ws-primary",
        owner_type: "user" as const,
        owner_id: "user-owner",
        sharing_policy: "owner_controlled" as const,
      };
      expect(
        canUseCredentialProfile(
          sampleContext,
          { ...profile, sharing_policy: "private_only" },
          [],
        ),
      ).toBe(false);
      expect(
        canUseCredentialProfile(sampleContext, profile, [
          { grantee_type: "user", grantee_id: "user-123", use_permission: 1 },
        ]),
      ).toBe(true);
      expect(
        canUseCredentialProfile(sampleContext, profile, [
          {
            grantee_type: "user",
            grantee_id: "user-123",
            use_permission: 1,
            revoked_at: "2026-01-01",
          },
        ]),
      ).toBe(false);
    });

    it("rejects a host that is not actively bound to the requested workspace", async () => {
      const db: DatabaseAdapter = {
        prepare(query: string) {
          return {
            bind() {
              return this;
            },
            async first<T>() {
              if (query.includes("host_workspace_bindings")) return null as T;
              return null as T;
            },
            async all<T>() {
              return { results: [] as T[] };
            },
            async run() {
              return { success: true };
            },
          };
        },
      };
      await expect(
        authorizeHostWorkspaceBinding(db, "ws-other", "host-a"),
      ).rejects.toThrow(AuthorizationError);
    });

    it("enforces credential grants at the database boundary", async () => {
      const db: DatabaseAdapter = {
        prepare(query: string) {
          return {
            bind() {
              return this;
            },
            async first<T>() {
              return query.includes("credential_profiles")
                ? ({
                    id: "profile-a",
                    workspace_id: "ws-primary",
                    owner_type: "user",
                    owner_id: "owner",
                    sharing_policy: "owner_controlled",
                  } as T)
                : (null as T);
            },
            async all<T>() {
              return {
                results: [
                  {
                    grantee_type: "user",
                    grantee_id: "user-123",
                    use_permission: 1,
                  },
                ] as T[],
              };
            },
            async run() {
              return { success: true };
            },
          };
        },
      };
      await expect(
        authorizeCredentialProfileUse(db, sampleContext, "profile-a"),
      ).resolves.toBeUndefined();
    });

    it("denies suspended users and removed Workspace members", async () => {
      expect(() =>
        authorize(
          { ...sampleContext, user: { ...sampleUser, status: "suspended" } },
          "projects:read",
          "proj-conclave",
        ),
      ).toThrow(AuthorizationError);

      const removedMemberDb: DatabaseAdapter = {
        prepare(query: string) {
          return {
            bind() {
              return this;
            },
            async first<T>() {
              if (query.includes("FROM users WHERE id")) {
                return {
                  id: "user-1",
                  email: "alice@example.com",
                  display_name: "Alice",
                  avatar_url: null,
                  status: "active",
                } as T;
              }
              return null;
            },
            async all<T>() {
              return { results: [] as T[] };
            },
            async run() {
              return { success: true };
            },
          };
        },
      };
      await expect(
        resolveSecurityContextFromIdentity(
          removedMemberDb,
          {
            userId: "user-1",
            email: "alice@example.com",
            name: "Alice",
            sessionId: "session-1",
          },
          { requestedWorkspaceId: "ws-removed" },
        ),
      ).rejects.toThrow(AuthorizationError);
    });

    it("rejects Workspace and Project ID substitution", async () => {
      await expect(
        resolveSecurityContextFromIdentity(
          {
            prepare(query: string) {
              return {
                bind() {
                  return this;
                },
                async first<T>() {
                  return query.includes("FROM users WHERE id")
                    ? ({
                        id: "user-1",
                        email: "alice@example.com",
                        display_name: "Alice",
                        avatar_url: null,
                        status: "active",
                      } as T)
                    : null;
                },
                async all<T>() {
                  return {
                    results: [
                      {
                        workspace_id: "ws-owned",
                        role: "member",
                        workspace_status: "active",
                      },
                    ] as T[],
                  };
                },
                async run() {
                  return { success: true };
                },
              };
            },
          },
          {
            userId: "user-1",
            email: "alice@example.com",
            name: "Alice",
            sessionId: "session-1",
          },
          { requestedWorkspaceId: "ws-other" },
        ),
      ).rejects.toThrow(AuthorizationError);

      expect(canAccessProject(sampleContext, "proj-other")).toBe(false);
    });

    it("requires an owner or valid grant for Credential Profile access", () => {
      const privateProfile = {
        id: "profile-private",
        workspace_id: "ws-primary",
        owner_type: "user" as const,
        owner_id: "another-user",
        sharing_policy: "private_only" as const,
      };
      expect(canUseCredentialProfile(sampleContext, privateProfile, [])).toBe(
        false,
      );
      expect(
        canUseCredentialProfile(sampleContext, privateProfile, [
          {
            grantee_type: "user",
            grantee_id: "user-123",
            use_permission: 1,
            expires_at: "2020-01-01T00:00:00.000Z",
          },
        ]),
      ).toBe(false);
      expect(
        canUseCredentialProfile(
          { ...sampleContext, workspaceId: "ws-other" },
          privateProfile,
          [{ grantee_type: "user", grantee_id: "user-123", use_permission: 1 }],
        ),
      ).toBe(false);
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

  describe("Service Bearer Credential Extraction", () => {
    it("extracts token from Authorization Bearer header", () => {
      const headers = new Headers({
        authorization: "Bearer token-xyz-123",
      });
      expect(extractBearerToken(headers)).toBe("token-xyz-123");
      expect(
        extractBearerToken({ cookie: "conclave_session=legacy-token" }),
      ).toBeNull();
    });
  });

  describe("Database-Backed Security Context Resolution", () => {
    function createIdentityDb(
      workspaceRows = [
        {
          workspace_id: "ws-team",
          role: "member" as "owner" | "admin" | "member" | "viewer",
          workspace_status: "active",
        },
      ],
    ): DatabaseAdapter {
      return {
        prepare(query: string) {
          let boundValues: unknown[] = [];
          return {
            bind(...values: unknown[]) {
              boundValues = values;
              return this;
            },
            async first<T>() {
              if (query.includes("FROM users WHERE id")) {
                expect(boundValues).toEqual(["user-1"]);
                return {
                  id: "user-1",
                  email: "alice@example.com",
                  display_name: "Alice",
                  avatar_url: null,
                  status: "active",
                } as T;
              }
              return null;
            },
            async all<T>() {
              if (query.includes("FROM workspace_memberships wm")) {
                return {
                  results: workspaceRows as unknown as readonly T[],
                };
              }
              if (query.includes("FROM project_memberships pm")) {
                return {
                  results: [
                    { project_id: "proj-1", role: "lead" },
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

    it("maps Better Auth identity into existing workspace authorization", async () => {
      const ctx = await resolveSecurityContextFromIdentity(
        createIdentityDb(),
        {
          userId: "user-1",
          email: "alice@example.com",
          name: "Alice",
          sessionId: "better-auth-session",
        },
        { requestedWorkspaceId: "ws-team" },
      );

      expect(ctx.userId).toBe("user-1");
      expect(ctx.workspaceId).toBe("ws-team");
      expect(ctx.workspaceRole).toBe("member");
      expect(ctx.authorizedProjectIds).toEqual(["proj-1"]);
      expect(ctx.projectRoles).toEqual({ "proj-1": "lead" });
      expect(ctx.sessionId).toBe("better-auth-session");
      expect(ctx.clientType).toBe("web");
    });

    it("rejects an authenticated identity without a Conclave user", async () => {
      const db: DatabaseAdapter = {
        prepare() {
          return {
            bind() {
              return this;
            },
            async first() {
              return null;
            },
            async all() {
              return { results: [] };
            },
            async run() {
              return { success: true };
            },
          };
        },
      };

      await expect(
        resolveSecurityContextFromIdentity(db, {
          userId: "missing-user",
          email: "missing@example.com",
          name: "Missing",
          sessionId: "better-auth-session",
        }),
      ).rejects.toThrow(AuthenticationError);
    });

    it("honors an explicitly selected Workspace for a multi-Workspace user", async () => {
      const ctx = await resolveSecurityContextFromIdentity(
        createIdentityDb([
          {
            workspace_id: "ws-personal",
            role: "owner",
            workspace_status: "active",
          },
          {
            workspace_id: "ws-company",
            role: "member",
            workspace_status: "active",
          },
        ]),
        {
          userId: "user-1",
          email: "alice@example.com",
          name: "Alice",
          sessionId: "better-auth-session",
        },
        { requestedWorkspaceId: "ws-company" },
      );

      expect(ctx.workspaceId).toBe("ws-company");
      expect(ctx.workspaceRole).toBe("member");
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
