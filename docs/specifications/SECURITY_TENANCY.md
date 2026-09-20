# Security, tenancy, and usage

Phase 13 defines the security boundary for a multi-user Conclave deployment. The Core remains provider-independent; identity, authorization, accounting, and retention are enforced around Core requests and persisted as auditable state.

## Tenant boundary

Every organization-scoped record carries an organization identifier. Projects belong to one organization, and project membership is explicit. Organization owners and administrators may manage organization resources; project roles grant only the permissions assigned to that project. A suspended organization or user cannot create, control, or inspect runs.

The shared security package is the policy source for roles and permissions. Worker identity must come from a configured identity provider (Cloudflare Access or an equivalent verified JWT boundary). Development-only identity headers are not a production authentication mechanism.

## Credentials

BYOK credentials are encrypted with AES-GCM before persistence. D1 stores only the envelope (key id, IV, ciphertext, timestamps, and provider). The key-encryption key is a Worker secret or external KMS-managed key and is never stored in D1, R2, logs, events, or model prompts. Decryption is allowed only for an authorized server-side provider call.

## Accounting and controls

Rate limits are scoped by organization and bucket. Budgets can be applied at organization, project, and run scope and are checked before usage is committed. Usage records include token counts, execution time, provider/model metadata, and estimated cost in integer micro-units to avoid floating-point accounting errors. Idempotency keys and ordered events make retries auditable.

## Audit and retention

Authorization decisions, credential changes, run controls, budget decisions, and administrative changes produce audit records with actor, resource, outcome, and non-sensitive metadata. Retention policies determine when audit, artifact, and usage data may be deleted. Secret values, access tokens, and full unredacted prompts are explicitly excluded from audit metadata.

## Threat model

| Threat | Control | Residual risk |
| --- | --- | --- |
| Cross-organization read/write | Organization and project membership checks before authorization | A misconfigured identity-provider claim mapping must be detected operationally |
| Credential disclosure | AES-GCM envelope encryption; KEK outside D1; no plaintext logging | Compromise of the Worker/KMS boundary |
| Replay or duplicate mutation | Idempotency keys and event correlation | Expired idempotency records cannot prevent very old replays |
| Run abuse or runaway spend | Organization/project/run rate limits, budgets, timeouts, cancellation | Accounting depends on provider-reported usage being truthful |
| Privilege escalation | Central role-permission map and deny-by-default authorization | Application code must not bypass the shared guard |
| Sensitive data retention | Explicit retention periods and redacted audit metadata | Backups and provider-side retention are separate controls |
| Malicious repository content | Local runtime approvals, operation allowlists, and isolated execution | A permitted command can still have project-level impact |

## Production readiness conditions

Before exposing a deployment to multiple external organizations, configure a verified identity provider, implement the D1-backed membership lookup at the Worker boundary, set non-zero retention policies, rotate the KEK, enable encrypted transport and access logging, and exercise cross-tenant authorization tests against the deployed Worker.
