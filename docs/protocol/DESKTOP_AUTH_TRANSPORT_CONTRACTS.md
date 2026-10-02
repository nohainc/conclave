# Desktop Authentication and Runtime Transport Contracts

**Contract:** `conclave.desktop-auth-transport` **1.0**
**Canonical validators/types:** `packages/workspace-runtime-protocol/src/desktop-auth-transport.ts`

This contract freezes the shared Cloud/desktop shapes for ADR-013 Phase 0.
It defines payloads and state projection only; it does not implement endpoints,
credential storage, or transport behavior. Request and response schemas are
strict so unknown fields (including accidental credential forwarding) fail
validation. Runtime messages inside transport envelopes remain the existing
`conclave.workspace-runtime-protocol` messages.

## Credential boundaries

| Type | Purpose | Accepted by | Storage |
| --- | --- | --- | --- |
| `DesktopHumanSessionCredential` | Human account and Workspace management | Desktop-authenticated management APIs | OS secure storage |
| `WorkspaceRuntimeCredential` | Registered machine execution and runtime transport | Workspace runtime APIs and Gateway | OS secure storage |
| Provider CLI authentication state | Authenticate the locally installed provider CLI | That provider CLI only | The provider CLI's own local configuration or OS credential store |

The human and runtime credentials are separate branded types and schemas. A
provider CLI's authentication state is outside Conclave's credential model: it
has no Cloud or Workspace Runtime Protocol schema and must never appear in a
Cloud request, inventory projection, desktop human-auth response, or runtime
event. No credential is a substitute for another.

## Desktop human authentication

1. `POST /api/desktop-auth/intents` accepts `DesktopAuthIntentCreateRequest`
   and returns `DesktopAuthIntentCreateResponse`, including a separate
   short-lived poll token. The current intent contract is `1.1` and does not
   use a comparison code. This intent version is distinct from the shared
   transport contract version `1.0`.
2. The desktop opens `verificationUrl` in the system browser. The existing
   AX Better Auth login handles email/password, configured social providers,
   and passkeys where supported. After sign-in, the user explicitly approves
   the desktop request in the browser. New desktop releases do not ask the
   user to read, remember, or enter a code.
3. The desktop polls the intent status using the poll token and claims an
   approved intent exactly once using `DesktopAuthIntentClaimRequest`.
4. The claim returns `DesktopHumanSessionIssue`. The credential is opaque,
   audience-bound to `conclave.desktop.management`, and independently
   revocable from browser sessions and runtime credentials. The authenticated
   `GET /api/desktop-auth/session` endpoint checks the desktop audience; session
   rotation and revocation use the desktop session bearer and session ID.

The Cloud intent expires after ten minutes and permits a single successful
claim. Poll tokens are stored only as hashes. Current intents bind approval to
the authenticated browser session, explicit user approval, and the unguessable
intent URL. Intent expiry, approval and one-time claim enforcement are Cloud
behavior.
This exchange never exposes the browser's HttpOnly cookie to the desktop.

At startup, the desktop asynchronously validates the stored human session after
starting the runtime. A still-valid session within five days of expiry may be
rotated through `POST /api/desktop-auth/sessions/{sessionId}/rotate`; the same
session ID and user are retained while the bearer credential and expiry change.
The replacement is persisted to secure storage before management access is
restored. A failed/revoked validation does not stop or rebuild the runtime:
disconnected installations show **Sign in required**, while a connected or
desired-connected installation requires same-owner reauthentication. Browser
reauthentication stores the newly approved session and then best-effort revokes
the previous desktop session.

## Registration and recovery

`WorkspaceRegistrationRequest` is sent to `POST /api/workspace-runtime/register`
with the desktop human session bearer credential. The persistent `install_<UUID>`
`installationId` is the ownership key; computer name and hostname are descriptive
facts. The request includes platform, architecture, app version, and a bounded
capability object containing only OS/runtime support and concurrency. It excludes
provider credentials, local paths, cookies, and filesystem data.

Cloud creates a Workspace for a previously unseen installation. For an existing
installation owned by the same authenticated user, it recovers that Workspace
and issues a fresh runtime credential. An installation bound to another user
returns `409 installation_already_owned`; changing the account requires the
existing explicit disconnect/release workflow. Hostname and display-name changes
never transfer ownership. Runtime credentials remain separate from the human
credential and are stored by desktop in the OS secure credential store.
Registration responses include the authenticated `ownerUserId`; the current
desktop checks it against the signed-in session before storing the returned
runtime credential and fails closed if Cloud omits it.

Before replacing a desktop human session for an already registered local
Workspace, the desktop calls `POST /api/workspace-runtime/ownership` with that
session, the persistent installation ID, and any locally known Workspace and
runtime IDs. Cloud compares the authenticated user with the authoritative
Workspace owner and returns `409 installation_already_owned` on mismatch. It
does not issue or rotate a runtime credential. Ownership checks require the
current installation binding; a Workspace/runtime ID pair alone cannot adopt
an identity without that binding. A failed check does not alter Cloud
ownership or the desktop's stored human session. The local owner cache is
refreshed from this Cloud response and remains non-authoritative. Cloud rejects
local IDs bound to a different installation or to multiple Workspace records,
even when those records share an owner.

`POST /api/workspace-runtime/release` is a separate advanced operation. It
requires a desktop human session created within the last five minutes, the
same authoritative owner, the exact installation/Workspace/runtime binding,
and no active assignments. Cloud first fences the Workspace from scheduling,
then revokes runtime identities, disconnects the Gateway, revokes Project
grants, clears installation bindings, and records an audit event. It does not
delete local Worker records, provider CLI sign-in state, or Work Root files. A
different account can register the stable installation ID only after this
explicit release succeeds.

Reset local Workspace has published fixed semantics: it removes local
registration/runtime identity, local Worker registry entries, and the desktop
human session. It preserves
the stable installation ID and owner binding, Work Root metadata/content,
launch-at-login, management preferences, and other local files. Disconnect
also preserves its non-secret registration and cached owner metadata so the
owner can choose Release later; `desiredRuntimeState = disconnected` prevents
that retained record from starting the runtime. It preserves the human session.
Connect presents an
explicit launch-at-login option on macOS 13 and later; it uses the native
`SMAppService.mainApp` login item registration.

## Runtime transport abstraction

Both `websocket` and `http_long_poll` carry the existing logical
`WorkspaceRuntimeMessage`. The `WorkspaceTransport` interface provides an async
message stream, `send`, and `close`. `WorkspaceCloudConnection` owns protocol
handshake, synchronization, inventory, heartbeat, assignment, cancellation,
progress, and result handling above the selected transport. It also reports the
active mode. WebSocket is the preferred mode. One transport is authoritative
for inbound assignment delivery at a time; transport changes do not change the
Workspace or runtime identity.

Fallback session calls use the Workspace runtime credential:

| Operation | Contract |
| --- | --- |
| Create/reconcile session | `RuntimeSessionCreateRequest` → `RuntimeSessionCreateResponse` |
| Send upstream events | `RuntimeEventsPostRequest` → `RuntimeEventsPostResponse` |
| Long-poll downstream events | `RuntimePollRequest` → `RuntimePollResponse` |
| Close session | `RuntimeSessionCloseRequest` → `RuntimeSessionCloseResponse` |

Every event has a stable `eventId` for idempotent retries. The cursor is an
opaque server-issued string scoped to the runtime session; clients store and
return it unchanged and must not infer ordering or encode authorization into
it. Polls have finite `waitMs` bounded by the schema, and an empty timed-out
response returns the latest cursor. A poll response remains queued until the
client presents its returned cursor on the next poll, so a lost HTTP response
can be retried. Cloud validates the credential and binds the session and
cursor to the authenticated runtime; a session ID or cursor alone grants no
access. Replaying an event ID is idempotent, including after a long-poll
session is recreated. Event IDs must be unpredictable and must not contain
credential material.

## Transport status

`RuntimeTransportStatus` is the read-only projection for desktop diagnostics
and AX observation. `activeTransport` is null unless a transport is active;
`authentication_required` cannot report an active runtime channel.
`fallback_ready` explicitly identifies HTTPS long-poll as active while
WebSocket remains preferred. Failure text is diagnostic, not executable
content, and implementations must redact credentials from it.

The read-only AX Workspace projection may expose `activeTransport` and a
display-ready `connectionMode` (`Connected · WebSocket` or
`Connected · HTTPS fallback`). Desktop diagnostics track the latest WSS
failure independently from HTTPS fallback health so recovery does not erase
the reason WebSocket became unavailable.

## Contract versioning

Desktop auth intents use version `1.1`; runtime registration, transport
requests, and event envelopes use the independently versioned
`conclave.desktop-auth-transport` contract `1.0`. Changes to the frozen
transport shapes require a separately versioned contract.

## Desktop lifecycle semantics

ADR-014 adds lifecycle semantics around these unchanged credential/transport
contracts.

The lifecycle model is a product of independent dimensions, not a single
derived status:

| Dimension | Values |
| --- | --- |
| `HumanAuthState` | `signed_out`, `signed_in`, `reauth_required` |
| `WorkspaceParticipationState` | `disconnected`, `connecting`, `connected`, `disconnecting` |
| `ManagementLockState` | `unlocked`, `locked` |
| `DesiredRuntimeState` | `connected`, `disconnected` |
| `RuntimeTransportProjection` | `websocket`, `http_long_poll`, `reconnecting`, `offline`, `authentication_required` |

`WorkspaceLifecycleState` carries the first four dimensions. Transport is
represented separately by `RuntimeTransportProjection` (and the richer
`RuntimeTransportStatus` diagnostics contract). No state is inferred from
another: signed-in does not imply connected; connected does not imply a valid
human session; locked does not imply disconnected; and HTTPS fallback does
not imply management reauthentication. Implementations must not add a
combined `isConnected` or `isUnlocked` value that hides these dimensions.

`WorkspaceLifecyclePreferences` is a strict, non-secret local persistence
shape: desired runtime state, launch-at-login preference, management-lock
preference, optional auto-lock timeout, and optional cached owner user ID/display
name. Owner metadata is display-only and non-authoritative. Human sessions,
runtime credentials, and Worker/provider credentials are excluded and remain
in secure storage.

Other lifecycle invariants: another user cannot replace the owner of a
connected installation; disconnect preserves account ownership; and explicit
sign-out while connected requires an explicit disconnect-and-sign-out
transition instead of silently changing accounts. These rules constrain
commands/transitions, not construction of the independent state dimensions.

Human authentication and runtime participation are independent:

~~~text
DesktopHumanSessionCredential present
!= WorkspaceRuntimeCredential active
~~~

A successful desktop-auth claim establishes management identity only. The
client invokes Workspace registration/recovery when the user explicitly chooses
**Connect Workspace**. Existing connected installations may start/reconnect the
runtime after reboot using a valid Workspace runtime credential without first
refreshing the human desktop session.

Clients should persist non-secret desired lifecycle state separately from these
wire credentials, including at minimum whether runtime participation is intended
(`connected` or `disconnected`). Runtime credentials remain in secure storage.

If a management session expires while runtime transport remains authorized, the
runtime continues and management transitions to reauthentication-required. The
same owner must reauthenticate. A different User cannot use a desktop human
session to assume ownership of an already-owned installation.

Disconnect and ownership release are intentionally different operations:
Disconnect stops/revokes runtime participation while retaining installation
ownership; Release ownership is a separate management operation required before
another account may claim the installation.

The concrete management operation boundaries are:

| User action | Required authority | Cloud/local effect |
| --- | --- | --- |
| Sign in | Browser-approved desktop human session | Establishes human management identity; does not register or start runtime |
| Connect Workspace | Valid human session for the installation owner | Register/recover and issue runtime credential; persist desired runtime `connected`; start runtime |
| Disconnect Workspace | Owning human session and local confirmation/reauthentication | Drain/revoke runtime participation; retain installation owner binding and local Workers/secrets |
| Release ownership | Owning human session, fresh local authentication, disconnected runtime and no active assignments | Audit and clear Cloud owner binding; preserve local data |
| Sign out | Human session revoke/removal | Allowed directly while disconnected; while connected requires an explicit Disconnect and sign out transition |
| Reset local Workspace | Fresh local authentication and explicit destructive confirmation | Removes only the data enumerated in ADR-014; distinct from Cloud Release |

On macOS, launch-at-login is a user preference implemented through
`SMAppService.mainApp`. It is not enabled merely by installing the app. On
startup, the runtime follows persisted `DesiredRuntimeState` and secure runtime
credential independently of human-session validation; opening the window then
routes to unlocked, locked, or reauthentication-required management UI.
