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
