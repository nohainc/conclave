# ADR-007: Final product naming and realtime connection topology

**Status:** Accepted for post-authentication Architecture v4 work  
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
