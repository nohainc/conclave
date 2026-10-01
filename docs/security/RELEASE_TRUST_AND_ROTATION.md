# Workspace, Engine, and Tool Profile Release Trust

**Current target:** Architecture v8 separates trust for the Workspace
application, the generic CLI Worker Engine, and immutable Tool Profile
Releases. Architecture v7 is the historical baseline; Worker Runtime v2 is its
process-boundary predecessor. Any provider-specific Worker signatures, routes,
or release records below are migration history only.

## Trust model

Conclave Workspace verifies release metadata with Ed25519 public keys. Signing
seeds remain in GitHub/production release infrastructure and are never shipped
in Workspace or Worker releases. Release metadata binds the publisher, key ID,
version, channel, platform/architecture, and archive digest. Worker release
signatures also bind the canonical manifest (excluding its signature field)
and the package file-tree digest.

Workspace application, CLI Worker Engine, and Tool Profile release classes use
explicit trust separation. Workspace application signing material must never
be reused for Engine/Profile release signing. Profile signing must not use the
historical per-Worker signing trust class. They share the public-key trust-root
configuration format, but a key for one release class must not be reused for
the other.
Apple Developer ID signing and notarization verify macOS origin/platform
requirements; Conclave release metadata verification remains required.

Production builds fail closed when no trusted public verification key is
configured. Development fixture signing is separate and must never be promoted
as a production key.

## Key material and configuration

The release workflows use GitHub Environments and repository variables:

| Purpose | Secret | Variable |
| --- | --- | --- |
| Native Worker manifest/package signing | `CONCLAVE_WORKER_SIGNING_SEED` | `CONCLAVE_WORKER_SIGNING_KEY_ID` |
| Workspace app release metadata | `CONCLAVE_WORKSPACE_ED25519_SEED` | `CONCLAVE_WORKSPACE_SIGNING_KEY_ID` |
| Release publication authorization | `CONCLAVE_RELEASE_PUBLISH_TOKEN` | `CLOUD_API_URL` |
| macOS Developer ID/notarization | `CONCLAVE_MACOS_CERTIFICATE_P12`, password and Apple credentials | — |
| Workspace client trust anchors | — | `CONCLAVE_RELEASE_TRUST_KEYS_JSON` |

Ed25519 seeds are 32-byte raw keys encoded as base64. Public roots are raw 32-byte
Ed25519 public keys encoded as base64, keyed by publisher and key ID in
`CONCLAVE_RELEASE_TRUST_KEYS_JSON`. Never print or upload signing seeds,
certificate passwords, Apple credentials, or publication tokens in workflow
logs or artifacts.

## Planned rotation

Use an overlap window; do not replace a key in place:

1. Generate an independent new seed/key ID for the relevant release class in
   the protected release environment.
2. Add the new public key to `CONCLAVE_RELEASE_TRUST_KEYS_JSON` while retaining
   the old key. Build and distribute a Workspace release containing both keys
   before signing releases with the new key.
3. Publish a canary release using the new key. Download it back and run the
   normal Workspace signature, digest, platform, permission, and health
   admission checks.
4. Promote only through a new immutable release record. Do not rewrite an
   existing release/version record.
5. After supported clients trust the new key, revoke the old key ID through
   Cloud's release-trust revocation mechanism and remove it from a later client
   trust-root build.
6. Record key ID, release class, activation date, overlap, revocation reason,
   and last supported client version in the release operations record.

Because the native Workspace `.app` update transaction is not complete, trust
root rotation currently depends on distributing a new signed/notarized app
through the release/onboarding channel. Do not revoke the only key trusted by
installed clients until a recovery distribution path is available.

## Revocation

- Revoke a compromised key ID or publisher immediately in Cloud trust state;
  clients refresh revocation state before release checks/admission.
- Revoke an individual Workspace app release through the host-release revoke
  endpoint. Profile release, publisher, or signing-key revocations use the
  shared `/api/release-trust` mechanism and are checked before Profile
  admission. Historical Worker-release revoke routes are unavailable in v8.
- Release revocation prevents future install/update admission. It does not
  terminate an already-running process; follow the incident response plan for
  active work and publish a replacement immutable release when safe.
- Keep last-known-good, verified releases available for rollback only while
  their signing key and release remain trusted.

## Verification evidence

The release workflows read published metadata and package bytes back from
Cloud, compare digests, and verify the signature/admission before reporting
success. A workflow dispatch is not production evidence until its run succeeds
against the intended Cloud environment. See [Workspace release operations](../deployment/WORKSPACE_RELEASES.md).

## Historical Worker Runtime v2 trust refinement

The following records the predecessor package model only; it is not the v8
trust or release contract.

ADR-017 makes first-party Worker artifacts native platform executables. Trust verification therefore binds the Worker Type, Worker version, platform/architecture, protocol range, Worker-state schema compatibility, permissions, executable path, package digest and archive hash in addition to normal publisher/key metadata.

Workspace may keep multiple trusted Worker versions installed for rollback. A previous version is eligible only while both its release and signing key remain trusted and its protocol/state schema remain compatible. Rollback does not bypass revocation.

Native Worker executable code signing on macOS/Windows complements Conclave Ed25519 package trust; it does not replace the Conclave manifest/package verification.


## Architecture v8 Profile trust

Tool Profiles are configuration but are treated as executable behavior policy. Every official Profile release is immutable and signed. Workspace verifies Profile definition/release identity, payload digest, schema version, logical Worker binding, Engine compatibility, and signing key before the generic Engine may consume it.

A database lifecycle transition such as Testing → Stable does not make unsigned or altered bytes trusted. The signed payload remains immutable; lifecycle state, promotion audit, and revocation are separate metadata.

Profiles must support fast rollback without bypassing revocation. Last-known-good is eligible only when its release and signing key remain trusted and its Engine/provider compatibility still holds.

## Architecture v8 Engine trust

The generic CLI Worker Engine is a native executable trust class. Initially it may be delivered as a known-good component of a Workspace release. If independently distributed later, Engine artifacts require their own immutable version, platform/architecture identity, digest/signature, revocation, and rollback path. Engine trust never substitutes for Profile trust; both layers must pass.

## Trust-class target

Operationally distinguish:

~~~text
Workspace app signing
CLI Worker Engine signing
Tool Profile signing
~~~

These may use separate keys or carefully scoped publisher/key classes, but a compromised Profile-signing credential must not authorize a Workspace application release.

# Tool Profile Release v1 signing envelope

Tool Profiles are executable policy. Workspace admits an official Profile only
after recomputing the SHA-256 digest of the canonical Profile JSON and verifying
its Ed25519 signature against a bundled publisher/key ID trust root. The signing
message is UTF-8:

~~~text
conclave-tool-profile-release-v1\n<canonical envelope JSON>
~~~

The canonical envelope JSON has these fields: `domain`, `publisher`,
`signingKeyId`, `payloadDigest`, `profileDefinitionId`, `releaseVersion`,
`logicalWorkerTypeId`, `engineFamily`, `schemaVersion`,
`engineCompatibility`, `providerToolName`, and `providerCompatibility`. The
digest is over canonical JSON for the entire validated Profile v1 payload, so
all execution behavior is covered. The envelope repeats release identity and
compatibility claims so Workspace can compare them with the response/database
metadata before launch. `providerCompatibility` is the Profile's
`providerTool.supportedVersions` array.

Lifecycle state, channel, promotion pointers, audit fields, display name, and
timestamps are unsigned registry metadata. They cannot override signed
identity or broaden signed behavior. Workspace accepts only testing, beta, or
stable channel responses, checks the selected logical Worker and metadata
against the signed Profile, and rejects revoked payload digests, release IDs,
publishers, and signing key IDs. Key rotation adds a new key ID/public key to
the Workspace trust roots; revoking an old key ID immediately prevents new
admission of releases signed by that key. A Profile release is identified for
revocation as `<profileDefinitionId>@<releaseVersion>`.

The release signer must construct the envelope from the validated immutable
payload and the publisher/key identity used to sign it. Re-labeling a signature
with another key ID or publisher invalidates the signature. Database lifecycle
updates do not require re-signing because they do not change the envelope.
