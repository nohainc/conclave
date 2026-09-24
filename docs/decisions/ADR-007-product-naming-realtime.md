# ADR-007: Final product naming and realtime connection topology

**Status:** Accepted for post-authentication Architecture v4 work — historical
**Date:** 2026-09-23

## Decision

The user-facing product is **Conclave AX**, not "Conclave AX Studio".

Canonical product names:
- Conclave AX — main Flutter Web application;
- Conclave Cloud — backend/control plane;
- Conclave Host — one desktop installation per machine;
- Worker — installable AI/tool integration;
- Account — UI name for the internal Credential Profile concept.

## Connection topology

```text
Conclave AX
  -> HTTPS commands
  -> authenticated Cloud realtime WebSocket

Conclave Cloud
  -> authenticated Host WebSocket
  -> Conclave Host

Conclave Host
  -> local structured protocol
  -> Worker processes
```

Workers do not connect directly to Conclave Cloud.

## Observability and diagnostics

Cloud assigns or preserves a bounded request ID for each HTTP request and
emits structured JSON logs. Assignment and realtime facts retain Workspace,
Run, Task, Attempt, Assignment, Host, Worker, Account, request, and event
correlation where available. Conclave AX can export Run diagnostics containing
safe identifiers, statuses, and ordered event metadata; Conclave Host can
export a bounded diagnostics bundle containing redacted logs and assignment
status. Diagnostic exports never include raw credentials, session tokens,
authorization headers, or provider secrets.

## Host WebSocket lifecycle

PA-8 uses one physical authenticated WebSocket per Host installation. The
initial binding authorizes the machine credential, after which Cloud resolves
all active Host-to-Workspace bindings and returns them in the session
handshake. Assignments remain Workspace-scoped and are checked against the
persisted Host/Workspace/Worker correlation; the Host does not reconnect when
authorized work arrives from another Workspace.

Each replacement socket receives a new session ID. Close/error handlers verify
both socket and session identity before marking the Host offline, so a stale
socket cannot tear down a newer connection. Heartbeats update the authoritative
D1 presence record, while reconnect sync uses Host-scoped assignment IDs and
the local journal to replay terminal results safely. Durable Object memory is
transient connection state only; D1 remains authoritative for enrollment,
bindings, assignments, and session history.

## Rationale

### Why Conclave AX instead of Studio
The web application is the primary product. "Studio" no longer distinguishes a separate desktop/admin experience and adds vocabulary without value.

### Why App <-> Cloud WebSocket
Users need immediate Run, Host, Worker and Account status without whole-app polling.

### Why Worker does not connect directly to Cloud
Direct Worker connections would duplicate:
- Cloud authentication;
- reconnect logic;
- Workspace authorization;
- protocol negotiation;
- heartbeats;
- Cloud credentials;
- security responsibility.

Host already provides the correct machine trust boundary and can forward Worker events with negligible latency.

### Why HTTPS commands + WebSocket events
HTTP remains simple/idempotent for mutations. WebSocket provides efficient asynchronous event delivery.

## Security principals

Human:
- Better Auth session.

Machine:
- Host machine credential.

AI account:
- Credential Profile / Account.

Worker:
- not a Conclave Cloud principal.

These identities must not be conflated.

## Multi-Workspace Host sharing

A Host is a machine security principal, not an extension of the user who
performed enrollment. Enrollment authorizes only the initial machine exchange;
the Host stores its machine credential and never stores a human session. A
Host may have active bindings to multiple Workspaces. Cloud re-evaluates the
requester's current Workspace membership for `host.view`, `host.use`,
`host.manage`, `host.bind_workspace`, `host.revoke`, and
`worker.manage_on_host` on every request. Removing a member therefore removes
their access immediately without revoking the Host itself.

## Realtime event contract

PA-4 defines the canonical event vocabulary in
`packages/protocol/schema/conclave-message.schema.json` under
`x-realtime-events`. Events are facts, never commands. Durable domain events
are retained for history and recovery; ephemeral events are bounded delivery
signals and are not assumed to be replayable.

Every event carries an event ID, event type and version, timestamp, Workspace
scope, monotonically increasing sequence, and typed payload. Project, Chat,
Run, Task, Attempt, Assignment, and Host references are optional envelope
context. Payloads reject unknown fields, raw credentials, and large artifact
bodies; streaming deltas are explicitly bounded and may be coalesced.

Clients may preserve an unknown event type when its event version is a
compatible minor version. They must never use event payloads as authorization;
authorization is independently checked against the authenticated request and
active Workspace membership.

The PA-5 gateway uses one user-scoped Durable Object per browser identity. The
WebSocket upgrade revalidates the Better Auth session, and every subscription
is checked against active Workspace membership plus Project, Chat, and Run
ownership. Mutations continue over HTTPS; the socket carries delivery facts,
subscription acknowledgements, heartbeats, and reconnect-gap notices.

## Event publication pipeline

PA-6 adds `EventPublisher` as the Cloud boundary for publishing domain facts.
Cloud application services provide authorized domain identifiers and typed
payloads; they do not know about WebSockets, Flutter, or browser clients.
Durable facts are stored in `realtime_events` with a per-Workspace sequence and
idempotency key before best-effort fanout. Ephemeral facts skip persistence and
are delivered only when a realtime gateway is available. Fanout failures are
isolated from the already-committed domain transaction, while durable events
remain available for cursor-based gap recovery.

The publisher fans out through the existing user-scoped Durable Objects after
resolving active Workspace members. This keeps authorization in Cloud and
avoids a global broadcast object. The legacy run event repository remains the
history API for workflow internals; new Cloud-facing realtime facts use the
PA-6 publisher and `realtime_events` contract.

## Worker progress relay

PA-7 keeps Workers local to Conclave Host. The Host validates Worker JSON-RPC
notifications, rejects malformed or oversized frames, redacts configured
secret values, and supplies the Assignment correlation from its trusted
execution context. A Worker-provided assignment ID is accepted only when it
matches that context. Ephemeral progress, status, output deltas, tool events,
usage, artifacts, and logs are rate-limited before crossing the Host WebSocket;
terminal result and error events are never dropped by that limiter.

Cloud receives only Host-authenticated Assignment envelopes and republishes
authorized progress through `EventPublisher`. Workers do not receive Cloud
credentials and cannot select another Workspace, Run, Task, Host, or
Assignment identity.
