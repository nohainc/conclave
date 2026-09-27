# Workspace Desktop Authentication and Dual-Transport Implementation

**Status:** Proposed implementation plan  
**Baseline:** `main@353c60e5b861a4b20b223611516076c200912d8b`  
**Architecture decision:** [ADR-013](../decisions/ADR-013-desktop-auth-and-dual-transport.md)

## Goal

Move Workspace ownership/recovery into the desktop app and remove WebSocket as
a single point of failure while preserving v7 security boundaries.

Target:

~~~text
Conclave Workspace
  human auth -> management/recovery API
  runtime auth -> machine execution API
  WebSocket -> preferred transport
  HTTPS long-poll -> fallback transport

Conclave AX
  read-only Workspace/Worker visibility
  Project/Workstream collaboration and authorization
~~~

---

# Phase 0 — Freeze shared contracts

**Status:** Implemented — shared TypeScript contracts are frozen at
`conclave.desktop-auth-transport` 1.0. See
[Desktop Authentication and Runtime Transport Contracts](../protocol/DESKTOP_AUTH_TRANSPORT_CONTRACTS.md).

## Goal

Prevent desktop and Cloud implementations from diverging.

Define versioned contracts for:

- desktop human-auth intent;
- desktop human-session credential;
- installation registration/recovery;
- runtime credential issue/rotation;
- runtime transport abstraction;
- long-poll cursor/envelope;
- transport status projection.

Document separate credential types:

~~~text
DesktopHumanSessionCredential
WorkspaceRuntimeCredential
Provider/WorkerCredential
~~~

Never reuse one token across these boundaries.

## Exit

Cloud and desktop use one reviewed request/response contract before UI work
starts.

---

# Phase 1 — Desktop human authentication

**Status:** Implemented. Cloud now issues one-time desktop auth intents and
independently revocable/rotatable desktop management sessions. The Workspace
opens the intent in the system browser, AX reuses its existing Better Auth
login and asks the user to confirm the desktop code, then Workspace validates
the issued session and stores it in OS secure storage. See the shared
[contract](../protocol/DESKTOP_AUTH_TRANSPORT_CONTRACTS.md).

## Cloud

Add a browser-assisted desktop authentication flow.

Recommended sequence:

~~~text
desktop POST /api/desktop-auth/intents
  -> intentId + userCode + verificationUrl

desktop opens verificationUrl in system browser

browser
  -> Better Auth login/session
  -> user approves Conclave Workspace
  -> intent becomes approved

desktop GET/POST claim intent
  -> one-time exchange
  -> desktop human session credential
~~~

Do not expose the browser's HttpOnly Better Auth cookie to Dart.

Desktop session requirements:

- scoped audience/purpose;
- User ID binding;
- created/last-used/expires/revoked timestamps;
- rotate/revoke support;
- independently revocable from web sessions;
- hashed/opaque server-side storage where appropriate;
- secure-store-only client persistence.

Consider short access + long refresh credentials if needed; do not invent a
second password database.

## Desktop

Add signed-out Workspace state:

~~~text
Conclave Workspace

Sign in to continue

[Sign in with Conclave AX]
~~~

Open the system browser rather than embedding provider login in a WebView.

After successful claim show account identity:

~~~text
Vitalii Noha
vitalii@example...
~~~

Store desktop human credentials in Keychain/OS secure store.

## Tests

- email/password;
- GitHub/Google browser auth where configured;
- intent expiry;
- intent reuse;
- CSRF/state binding;
- wrong User cannot claim another approved intent;
- logout/revoke;
- credential never appears in local JSON/logs.

## Exit

Desktop can call an authenticated human endpoint even when no runtime or
WebSocket exists.

---

# Phase 2 — Desktop-owned Workspace registration and recovery

## Goal

Replace normal AX pairing with authenticated desktop registration.

## Persistent installation identity

Keep the existing random installation ID as the stable local identity.

Cloud registration endpoint conceptually accepts:

~~~text
installationId
proposedWorkspaceName
hostname
platform
architecture
appVersion
runtimeCapabilities
~~~

under the desktop human session.

## Cloud rules

### New installation

~~~text
authenticated User
+ unknown installationId
-> create Workspace
-> create runtime identity
-> issue runtime credential
~~~

### Existing installation owned by same User

~~~text
authenticated same User
-> return/recover existing Workspace
-> optionally rotate missing/revoked runtime credential
~~~

### Installation owned by different User

~~~text
-> reject ownership conflict
~~~

Never silently transfer.

## Desktop

On first authenticated run:

1. load installation ID;
2. detect friendly computer name;
3. let user confirm/edit Workspace name;
4. register;
5. securely persist runtime credential;
6. start runtime transport.

Recovery UX:

~~~text
Cloud runtime credential missing/revoked
-> human API still works
-> desktop verifies ownership
-> Recover connection
-> rotate runtime credential
-> reconnect
~~~

Remove normal "Repair pairing".

## Migration

Already-paired desktops:

- keep existing runtime credentials;
- user may continue execution without immediate human sign-in during migration;
- prompt for human sign-in for management/recovery;
- after human sign-in, link/verify existing Workspace ownership by installation
  identity and owner;
- no forced re-pair.

## Exit

A new machine can become a Workspace using only the desktop app plus browser
authentication.

---

# Phase 3 — Simplify desktop Workspace account UX

## Workspace tab

Add an Account section:

~~~text
Account
Signed in as <Conclave account>

[Sign in] [Sign out]
[Recover Workspace connection] [Disconnect Workspace]
[Reset local Workspace]
~~~

Define explicit actions:

### Sign out of management session

Revokes/removes the human desktop session only. It does not disconnect the
Workspace or terminate running assignments.

### Disconnect Workspace

Explicit operation that:

- stops accepting new work;
- drains/cancels according to chosen policy;
- revokes runtime credential;
- marks the installation disconnected;
- preserves local Workers/credentials unless user chooses destructive reset.

### Reset local Workspace

Separate destructive advanced action.

When the runtime credential is missing or revoked, recovery uses the desktop
human bearer credential over HTTPS to re-register the persistent installation
and obtain a fresh runtime credential. It does not depend on WebSocket
availability.

Do not conflate these actions.

## Remove

- pairing code entry from normal post-migration UX;
- Repair pairing;
- instructions telling user to revoke/re-pair from AX.

## Exit

All normal ownership/recovery actions are understandable from the desktop app.

---

# Phase 4 — Make AX Workspaces operationally read-only

## Goal

AX observes execution capacity but does not manage local machine lifecycle.

The AX Workspaces page now presents Workspace and Worker state as operational
information. It does not generate pairing codes, connect machines, rename or
update local Workspaces, unpair/reset local installations, or change remote
Worker scheduling. Project access remains managed through Project-facing
controls. Existing server APIs are retained while remaining callers are
audited.

Remove from normal Workspaces UI:

- Connect Workspace pairing-code creation;
- Connect Machine;
- repair/re-pair;
- revoke/unpair local Workspace;
- rename local Workspace if desktop is the intended owner;
- Worker scheduling enable/disable/drain controls for this phase;
- local Worker remediation actions beyond informational guidance.

Keep:

- Workspace name;
- connected/offline state;
- active transport type;
- machine facts;
- version;
- last seen;
- Worker list/readiness;
- active work summary;
- Project access summary.

Project collaboration/authorization remains in AX:

- Project membership;
- Workspace Grants;
- Workstream policy;
- Runs/Tasks/approvals.

Move grant mutation to Project-oriented UX if necessary so the Workspaces page
itself can remain read-only.

## Backend compatibility

Do not immediately delete scheduling/unpair endpoints merely because UI stops
using them.

Mark them internal/deprecated, audit remaining callers, then remove separately
if no runtime/admin path requires them.

## Exit

A user never needs AX to repair or register their local Workspace.

---

# Phase 5 — Introduce a transport abstraction in Conclave Workspace

## Goal

Make logical runtime behavior independent of WebSocket.

Define an interface conceptually:

~~~text
WorkspaceTransport
  connect()
  send(message)
  stream/messages
  close()
  mode
  diagnostics
~~~

Implement:

~~~text
WebSocketWorkspaceTransport
HttpLongPollWorkspaceTransport
~~~

Move protocol/session logic above both transports:

- hello/hello.ack;
- sync;
- inventory;
- heartbeat;
- assignment;
- cancellation;
- progress/result.

Do not duplicate business logic in each transport.

Connection coordinator:

~~~text
try WebSocket
  -> Ready => preferred

bounded failure/retry
  -> start HTTPS fallback

periodically probe WebSocket
  -> if healthy, controlled handover back to WebSocket
~~~

Only one transport may be authoritative for inbound assignment delivery at a
time.

## Exit

Runtime protocol tests run against either transport implementation.

---

# Phase 6 — Cloud HTTP fallback session

## Goal

Provide an authenticated runtime path that works through ordinary HTTPS.

Use the Workspace runtime credential.

Recommended logical APIs:

~~~text
POST /api/workspace-runtime/session
POST /api/workspace-runtime/events
GET  /api/workspace-runtime/poll?sessionId=...&cursor=...
POST /api/workspace-runtime/close
~~~

Exact routing may forward into the same Workspace Gateway Durable Object.

### Session creation

Validates runtime credential and returns:

~~~text
sessionId
serverTime
pollTimeoutMs
heartbeatIntervalMs
cursor
~~~

### Upstream events

Workspace posts one or multiple versioned protocol envelopes:

- hello;
- sync request;
- inventory;
- heartbeat;
- assignment progress/result;
- acknowledgements.

Must be idempotent by message ID.

### Long poll

Cloud holds request for a bounded duration, e.g. 20–30 seconds.

Returns immediately when events exist:

~~~text
cursor
events[]
~~~

On timeout:

~~~text
cursor
events: []
~~~

Client immediately opens next poll.

### Downstream queue

The same logical Gateway session receives:

- assignment dispatch;
- cancel;
- checkout/control commands.

Require acknowledgement and retry semantics.

## Durable Object state

The Gateway DO remains the live coordinator.

Track:

~~~text
runtime ID
Workspace ID
active transport
session ID
last activity
pending outbound events
cursor
ack state
~~~

Do not rely on D1 polling for realtime command delivery.

## Exit

A Workspace can become Ready and execute a deterministic assignment with
WebSocket completely disabled.

---

# Phase 7 — Transport handover and liveness

## Goal

Avoid duplicate assignment delivery or false online state.

Define state machine:

~~~text
offline
connecting_websocket
websocket_ready
fallback_connecting
fallback_ready
switching_to_websocket
reconnecting
~~~

### WebSocket -> fallback

Trigger after bounded failures such as:

- upgrade failure;
- proxy rejection;
- repeated handshake timeout;
- repeated protocol hello failure.

Do not fallback for:

- invalid/revoked runtime credential;
- ownership conflict;
- protocol version unsupported.

Those require authentication/remediation.

### Fallback -> WebSocket

Periodically probe WSS at low frequency.

When successful:

1. create WebSocket;
2. hello/sync;
3. reconcile cursor/assignment state;
4. mark WebSocket authoritative;
5. close fallback session or convert it to standby.

Never run two independent assignment consumers.

### Liveness

Scheduler asks Gateway for logical runtime liveness, not WebSocket-specific
state.

Gateway reports:

~~~text
online
runtimeId
transport = websocket | http_long_poll
lastActivityAt
~~~

Long-poll is online only if recent polls/heartbeats satisfy TTL.

## Exit

Transport can switch without duplicate or lost assignment execution.

---

# Phase 8 — Runtime API fallback coverage

## Goal

Ensure all essential Workspace operations survive WSS failure.

The Workspace now has a transport-neutral message interface, a WebSocket
adapter, and an HTTP long-poll adapter that forwards the same versioned runtime
messages. Cloud's session, event, poll, and close routes forward into the same
Workspace Gateway Durable Object. Both transports share hello/sync, runtime
facts, inventory snapshots and tombstones, heartbeat, assignment delivery and
acknowledgement, progress, result/failure, cancellation, and checkout/control
message handling.

Fallback must support:

- hello;
- sync/reconcile;
- Worker inventory;
- Worker tombstones;
- runtime facts;
- heartbeat;
- assignment dispatch;
- assignment acknowledgement;
- progress;
- result/failure;
- cancel;
- checkout/control commands required by current v7 runtime.

Nonessential high-frequency diagnostics may remain WebSocket-optimized if a
safe degraded behavior is documented.

## Exit

WebSocket outage does not make the Workspace unusable.

---

# Phase 9 — Connection-mode UI/UX

## Desktop

Primary Workspace status:

~~~text
Connected · WebSocket
~~~

Fallback:

~~~text
Connected · HTTPS fallback
WebSocket is unavailable. Work can continue.
~~~

Reconnecting:

~~~text
Reconnecting…
Using HTTPS fallback
~~~

Authentication problem:

~~~text
Connection requires attention
[Recover connection]
~~~

Diagnostics:

~~~text
Human account       Signed in
Runtime credential  Ready

Preferred transport WebSocket
WebSocket            Failed — HTTP ...
Fallback             Connected
Last successful WSS  ...
Last poll            ...
Last runtime event   ...
~~~

Keep **Retry WebSocket** as a diagnostic action if useful, not as the only
recovery path.

## AX

Read-only display:

~~~text
MacBook Pro
Connected
HTTPS fallback
3 Workers
~~~

or:

~~~text
Connected
WebSocket
~~~

Avoid alarm styling for fallback when execution remains healthy; use a degraded
informational badge.

## Exit

Implemented in the desktop snapshot and read-only AX Workspace projection.
Desktop diagnostics retain the last WSS failure separately from current HTTPS
fallback health, including while fallback is healthy.

Users can immediately tell whether the Workspace is offline, authenticated but
degraded, or fully realtime.

---

# Phase 10 — Scheduling and Project integration

**Status:** Implemented. Scheduler selection checks the Workspace Gateway's
logical runtime `online` state and identity without gating on the active
transport. Assignment dispatch targets the Gateway logical outbound path;
the Gateway sends over WebSocket or queues the event for HTTPS long-poll.

## Goal

Ensure collaborative work continues regardless of transport.

Scheduler eligibility becomes:

~~~text
Gateway logical session online
AND runtime identity matches
AND Worker locally ready
AND Project Workspace Grant active
AND policy allows Worker
AND Cloud/local capacity available
~~~

It must not require:

~~~text
transport == websocket
~~~

Assignment dispatcher sends into the Gateway's logical outbound queue. The
Gateway delivers through the active transport.

Project members continue to use Work/Discuss normally; they never need local
Workspace credentials.

## Exit

The same Work Request succeeds through either WSS or HTTP fallback.

---

# Phase 11 — Security hardening

**Status:** Implemented and covered by focused Cloud security tests. Runtime
Gateway APIs accept only runtime credentials; desktop human APIs accept only
desktop human sessions; installation ownership rejects another User; HTTP
poll cursors are fenced to the current runtime session; replayed event IDs stay
deduplicated across session recreation; diagnostic logging redacts credential
fields.

Test separately:

## Desktop human session

- stolen desktop human credential cannot execute assignments as a runtime;
- runtime credential cannot call human account APIs;
- sign-out/revocation;
- account switching conflict;
- secure-store persistence;
- no credentials in logs.

## Runtime HTTP fallback

- bearer validation on every session/renewal boundary;
- session bound to runtime + Workspace;
- cursor cannot read another runtime's events;
- replayed upstream message is idempotent;
- guessed session ID is insufficient;
- poll endpoint rate limits/bounds;
- oversized event batches rejected;
- long-poll cancellation cleans up safely.

## Ownership

- User B cannot claim User A's installation;
- local reset alone cannot steal Cloud ownership;
- explicit transfer policy required for future account transfer.

## Exit

Human and machine authentication remain independently enforceable.

---

# Phase 12 — Acceptance and deployment gates

**Status:** Implemented. CI and the production deployment workflow run the
V7 runtime acceptance for WebSocket and forced HTTPS fallback, followed by
fallback-to-WebSocket handover with an exactly-once assignment assertion. The
deployed production WebSocket Gateway smoke test remains required after
deployment.

Add automated acceptance for:

### Desktop auth

~~~text
sign in
-> register/recover Workspace
-> obtain runtime credential
~~~

### WSS path

~~~text
runtime
-> WebSocket
-> hello/sync
-> assignment
-> result
~~~

### Forced fallback

Run Cloud/test environment where WebSocket upgrade is deliberately rejected:

~~~text
WSS fails
-> long-poll Ready
-> inventory sync
-> scheduler dispatch
-> assignment delivered
-> result returned
~~~

### Handover

~~~text
fallback running
-> WSS becomes available
-> reconcile
-> switch to WSS
-> no duplicate execution
~~~

### Production smoke

Keep current production WSS smoke.

Add a production HTTPS fallback smoke using a disposable runtime.

Deployment should fail if either canonical transport contract is broken.

## Exit

Both transports are independently proven in production-facing acceptance.

---

# Phase 13 — Remove pairing-first legacy UX

Desktop authenticated registration/recovery is implemented. The current
desktop and AX clients no longer expose pairing-first onboarding. Cloud
pairing compatibility remains enabled because no released-version migration
window is documented as complete.

Completed client cleanup:

- AX pairing-intent creation UI;
- desktop pairing-code dialog as the normal path;
- Repair pairing;
- legacy unpaired placeholder onboarding;
- old copy saying "create pairing code in AX".

Keep the Cloud migration/recovery compatibility path for older desktop
installations through a defined release window. Before removing it, publish
the minimum supported desktop version, confirm a released version with
authenticated registration/recovery, and use release/usage telemetry to
confirm supported older clients have migrated.

Audit and later remove:

- `workspace_pairing_intents` if no supported release needs it;
- one-time pairing endpoints;
- old tests/docs.

Do not drop migration tables or remove pairing endpoints until supported old
clients are past the compatibility window. This cleanup remains pending.

## Exit

The normal onboarding is:

~~~text
Install Conclave Workspace
-> Sign in
-> confirm computer/Workspace name
-> connected
-> add Workers
~~~

---

# Recommended PR sequence

1. **ADR/contracts only**
2. **Cloud desktop-auth intent/session APIs**
3. **Desktop sign-in UX + secure human session**
4. **Authenticated Workspace register/recover**
5. **Desktop ownership/recovery UX; remove Repair pairing**
6. **AX Workspaces read-only migration**
7. **Transport abstraction**
8. **Cloud long-poll Gateway endpoints** — implemented: runtime-credential-authenticated session, event, poll, and close routes forward to the existing per-Workspace Gateway Durable Object. Inbound events reuse the same runtime protocol handler as WebSocket; outbound protocol messages are enveloped and queued for cursor-based long-poll delivery. A single active poll per session is enforced.
9. **Desktop HTTP fallback**
10. **Transport handover/liveness** — implemented in the Workspace coordinator: bounded WSS attempts precede HTTPS fallback, a low-frequency WSS probe closes fallback before connecting, and assignment delivery remains gated until hello, sync reconciliation, and inventory sync complete. Cloud reports the active transport and treats HTTP sessions without recent poll/event activity as offline.
11. **Scheduler/dispatcher transport-neutral integration**
12. **Security/failure acceptance**
13. **Production fallback smoke**
14. **Legacy pairing cleanup**

## Critical sequencing rules

- Do not delete existing runtime credentials while adding human desktop auth.
- Do not use Better Auth human credentials for runtime execution.
- Do not remove WebSocket; it remains preferred.
- Do not remove pairing compatibility until at least one released desktop
  version supports authenticated registration/recovery.
- Do not expose local Worker/provider secrets through the new human API.
- Do not let WSS and long-poll consume assignments concurrently.
