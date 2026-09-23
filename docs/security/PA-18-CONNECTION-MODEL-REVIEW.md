# PA-18: Final connection-model security review

**Status:** Complete
**Date:** 2026-09-23
**Scope:** Better Auth, Conclave AX realtime, Conclave Cloud, Conclave Host, Workers, and Accounts

## Trust boundaries reviewed

### Conclave AX -> Conclave Cloud

- Better Auth resolves the human session on the upgrade request.
- Realtime upgrades require a trusted `Origin`; same-origin and configured
  Better Auth trusted origins are accepted.
- Workspace, Project, Chat, and Run subscriptions are authorized against
  current D1 membership and ownership data.
- Connected sockets are revalidated on client messages and before fanout, so a
  suspended user or removed Workspace member cannot continue receiving events.
- Mutations remain HTTPS requests protected by same-origin cookie checks.

### Conclave Cloud -> Conclave Host

- Initial connection requires the hashed machine credential and an active
  Host/Workspace binding.
- Every incoming Host message rechecks Host revocation and the current
  Workspace binding. Revoked sockets are closed on their next frame or
  heartbeat rather than being trusted indefinitely.
- Assignment replies must match the persisted Workspace, Host, Worker, Run,
  Task, Attempt, and idempotency correlation.
- Protocol major-version mismatches are rejected; reconnects use a new session
  and stale socket close events cannot take down the replacement session.

### Conclave Host -> Worker

- Worker JSON-RPC messages are parsed and bounded before relay.
- Worker-supplied assignment IDs must match the trusted local Assignment
  context. Workspace, Host, Run, Task, and Attempt identity comes from Host
  state, not Worker output.
- Worker output is rate-limited and redacted before Cloud relay. Terminal
  results and errors remain deliverable.
- Worker processes remain subject to Host process, filesystem, repository, and
  credential-scoping controls.

### Accounts

- Accounts are private by default; use requires ownership or a current grant.
- Grant removal is checked by Cloud authorization, not UI state.
- Raw provider/API credentials remain in Host secure storage and are never
  placed in realtime events, diagnostics exports, or structured logs.
- Worker session namespaces include Worker and Credential Profile identity, so
  provider history is not shared across Accounts.

## Negative-test coverage

The security suite covers foreign Workspace subscriptions, nested scope
substitution, suspended/removed users, Host binding removal, Host revocation,
forged Worker assignment IDs, replay/idempotency, protocol major-version
rejection, credential grant enforcement, and redaction. The PA-18 additions
specifically cover realtime identity revalidation, revoked Host revalidation,
and trusted WebSocket Origin enforcement.

## Findings

Two authorization gaps were fixed during this review:

1. Existing browser sockets were not revalidated after a user suspension or
   Workspace membership removal. Realtime now rechecks identity and active
   subscriptions before accepting client messages and before fanout.
2. Existing Host sockets were not revalidated after Host revocation or binding
   removal. Host message handling now checks current D1 Host and binding state
   and closes unauthorized sockets.

No high-severity unresolved issue remains in the reviewed topology.

## Residual risks

- Revocation cannot interrupt a socket between frames; the next heartbeat,
  client message, or event fanout performs the recheck and closes it.
- Worker sandbox strength remains platform- and Worker-specific and must be
  revalidated for each first-party Worker release.
- Provider-side session behavior is outside Conclave's control; Host isolation
  prevents cross-Account reuse but cannot change provider policy.
