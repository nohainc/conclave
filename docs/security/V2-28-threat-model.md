# V2-28 — Security hardening and threat model

## Assets

- Repository contents, credentials, model context, artifacts, and audit history.
- Tenant identity, project membership, run controls, and Agent sessions.
- Plugin and Agent release integrity.

## Trust boundaries

1. Browser/Studio to Cloudflare Access and Worker.
2. Worker to D1, R2, Workflows, and Durable Objects.
3. Cloud to outbound Agent connection.
4. Agent to signed, sandboxed plugin child process.
5. Plugin/web connector to external websites or subscription sessions.

## Threats and controls

| Threat | Required control |
| --- | --- |
| Cross-tenant reads or controls | Resolve identity → workspace → project before every query and control action; integration-test both directions. |
| Stolen or replayed Agent credential | Hash tokens in D1, rotate/re-enroll, revoke old tokens, bind sessions to Agent identity, and reject expired/revoked sessions. |
| Malicious plugin package | Verify digest and signature before install; reject revoked versions; require an explicit permission allowlist. |
| Plugin escape or denial of service | Run out of process, restrict permissions, cap stdout/stderr, enforce timeouts, terminate child processes, and isolate work directories. |
| Unauthorized runtime operation | Require organization/project/run/task/repository/approval correlation, operation allowlists, expiry, acknowledgement, and replay protection. |
| Credential leakage | OS Keychain/secret store, encrypted server envelopes, redacted logs, no browser-embedded secrets. |
| Abuse and cost exhaustion | Per-user/workspace/Agent rate limits, budgets, concurrency limits, and auditable denials. |
| Destructive or unverifiable output | Runtime evidence, independent verification, completion criteria gates, and immutable event history. |
| Data loss | Scheduled D1 export plus R2 artifact manifest export, encrypted backups, restore drills, and retention-aware deletion. |
| Dependency compromise | Lockfile review, `pnpm audit` in CI, Dependabot/Renovate, and release artifact provenance. |

## External-user gate

External access is not considered ready until production secrets are configured, Cloudflare Access protects the Custom Domain, plugin and Agent signing keys are rotated from development values, CI dependency scanning is green, rate limits are enabled, backup/restore has been exercised, and the tenant-isolation/security integration suite passes.

## Workspace desktop lifecycle boundaries

The Workspace desktop has three distinct credential classes:

| Credential | Authority | Must not authorize |
| --- | --- | --- |
| Desktop human session | Human account and Workspace management APIs | Runtime operations or Worker/provider access |
| Workspace runtime credential | One enrolled installation's Gateway/runtime APIs | Human account or ownership-management APIs |
| Local Worker/provider credential | The owning local Worker/adapter | Cloud, desktop management, or another Worker |

All three remain out of application logs. Human and runtime credentials use OS
secure storage; provider credentials remain in the local secret store. Lifecycle
preferences contain no secrets. Runtime event IDs make retries idempotent, and
long-poll cursors are opaque and bound server-side to the authenticated runtime
session so a cursor alone cannot read another Workspace's events.

Cloud registration, recovery, ownership inspection, disconnect, and release
must compare the authenticated human user with the authoritative installation
owner before mutating state. A different user receives a stable ownership
conflict and cannot rotate the runtime credential or replace the local owner
session. Disconnect revokes runtime participation but retains account binding;
only the explicit owner-authorized Release operation clears that binding.
Fallback transport uses the runtime credential and shares the Gateway's logical
outbound queue so WebSocket and long-poll cannot concurrently consume work.

The executable security and release checks are listed in the
[Workspace lifecycle production validation runbook](../operations/WORKSPACE_DESKTOP_LIFECYCLE_RELEASE_VALIDATION.md).

## Architecture v8 Tool Profile and schema evolution addendum

Tool Profiles are signed behavior policy interpreted by the local CLI Worker
Engine. The relevant trust flow is:

~~~text
official Profile author/signing key
-> immutable signed Profile Release
-> Workspace signature/digest/schema admission
-> constrained Engine interpreter
-> one discovered Provider CLI
~~~

The Profile signer is trusted to publish approved behavior, but signed data
must not grant the Engine additional execution authority. The Engine remains
the enforcement boundary for executable selection, shell prohibition,
environment allowlists, filesystem scope, deadlines, output bounds, selectors,
and process cleanup.

| Threat | Required control |
| --- | --- |
| Malicious or compromised Profile broadens execution | Strict versioned schema; closed placeholders/actions; structured argv; hard-coded Engine limits; signature/digest and logical Worker identity checks. |
| New schema is interpreted differently by old Workspace/Engine versions | Reject unknown schema versions and fields; bind schema version and behavior to the signed payload; require declared Engine compatibility. |
| v2 loosens validation or silently changes v1 meaning | Keep independent strict validators/interpreters per schema version; preserve v1 validation and fixtures; no permissive fallback or reinterpretation. |
| Complex selectors/rules exhaust CPU or memory | Fixed grammar, depth/count/byte bounds, output limits, and adversarial tests before release. |
| Convenience scripting enables arbitrary commands or data access | Do not support expressions, scripts, recursion, arbitrary helper processes, or unrestricted filesystem/network access. Add only reviewed finite primitives with explicit threat analysis. |

### Required Profile schema change review

Before adding Profile behavior absent from v1, document the concrete missing
primitive and establish whether it is generic across integrations. Update this
threat model before implementation. Add Profile schema v2 only when a bounded
generic primitive cannot be added compatibly and safely to v1. A v2 reader must
not weaken or reinterpret v1: each version has a strict parser, finite
interpreter, version-specific fixtures, and fail-closed handling for unknown
versions/fields. Profile signing, digest, lifecycle admission, and Engine
compatibility checks apply independently to every version.

No Profile v2 is defined or admitted by this addendum. The normative current
contract remains [Tool Profile v1](../specifications/TOOL_PROFILE_V1.md).
