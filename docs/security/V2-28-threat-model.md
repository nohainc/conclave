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
