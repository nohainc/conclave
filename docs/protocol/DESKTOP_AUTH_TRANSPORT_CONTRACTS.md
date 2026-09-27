# Desktop Authentication and Runtime Transport Contracts

**Contract:** `conclave.desktop-auth-transport` **1.0**
**Canonical validators/types:** `packages/host-protocol/src/desktop-auth-transport.ts`

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
| `WorkspaceRuntimeCredential` | Enrolled machine execution and runtime transport | Workspace runtime APIs and Gateway | OS secure storage |
| `LocalWorkerProviderCredential` | Local Worker/provider authentication | The owning local Worker/adapter only | Workspace local secret store |

The first two are separate branded types and schemas. The third is a local-only
type and intentionally has no shared wire schema. It must never appear in a
Cloud request, inventory projection, desktop human-auth response, or runtime
event. No credential is a substitute for another.

## Desktop human authentication

1. `POST /api/desktop-auth/intents` accepts `DesktopAuthIntentCreateRequest`
   and returns `DesktopAuthIntentCreateResponse`, including a separate
   short-lived poll token and one-time comparison code.
2. The desktop opens `verificationUrl` in the system browser. The existing
   AX Better Auth login handles email/password, configured social providers,
   and passkeys where supported. The signed-in user enters the comparison
   code and explicitly approves the request.
3. The desktop polls the intent status using the poll token and claims an
   approved intent exactly once using `DesktopAuthIntentClaimRequest`.
4. The claim returns `DesktopHumanSessionIssue`. The credential is opaque,
   audience-bound to `conclave.desktop.management`, and independently
   revocable from browser sessions and runtime credentials. The authenticated
   `GET /api/desktop-auth/session` endpoint checks the desktop audience; session
   rotation and revocation use the desktop session bearer and session ID.

The Cloud intent expires after ten minutes, allows up to five code attempts,
and permits a single successful claim. Poll-token and user-code values are
stored only as hashes. Intent expiry, approval and one-time claim enforcement
are Cloud behavior.
This exchange never exposes the browser's HttpOnly cookie to the desktop.

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

## Runtime transport abstraction

Both `websocket` and `http_long_poll` carry the existing logical
`WorkspaceRuntimeMessage`. The `WorkspaceTransport` interface provides an async
message stream, `send`, and `close`. `HostCloudConnection` owns protocol
handshake, synchronization, inventory, heartbeat, assignment, cancellation,
progress, and result handling above the selected adapter. It also reports the
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

## Compatibility

Version `1.0` is frozen for the first implementation sequence. Breaking shape
or semantic changes require a new major contract version. Additive optional
fields may be introduced only in a compatible minor version and must be
supported by both Cloud and desktop before use.
