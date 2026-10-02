# Workspace storage and connection diagnostics

Conclave Workspace prepares local storage before contacting Cloud. Work Root,
runtime state, the log directory, and their permissions are checked locally;
the app does not request a separate macOS “internet permission.” macOS App
Sandbox remains disabled because Workspace launches the generic CLI Worker Engine and
developer tools. Do not enable it without a separate subprocess/filesystem
design; if sandboxing is introduced, outgoing network access also needs the
Apple network-client entitlement.

## macOS storage layout

The default layout is:

```text
~/Library/Application Support/Conclave/Workspace/
    State/       runtime identity, Workspace registration, local Worker
                 registry, and assignment journal
    Profiles/    verified Tool Profiles and cached logical Worker catalog
    Engines/     generic CLI Worker Engine
    Workers/     per-Worker state, sessions, and diagnostics
    Work/        Workstream working directories (Work Root)
    Updates/     staged Workspace updates
~/Library/Logs/Conclave Workspace/
    host.log
```

The local Worker registry contains Worker IDs, catalog type IDs, activation,
local permissions, concurrency, readiness, and bounded CLI diagnostics. Cloud
or its verified local catalog cache defines available logical Workers and
their Profiles. On a local registry schema change, Workspace resets only the
local Worker registry; setup recreates slots from the catalog.

Runtime credentials remain in macOS Keychain. Provider sign-in remains owned by
the installed provider CLI and is not copied into Workspace state. Credentials
are not stored in this directory, copied into connection URL parameters, or
included in diagnostics. Runtime authentication is sent in the WebSocket
authorization header. `--data-dir` and `CONCLAVE_HOST_DATA_DIR` remain
supported and keep state, updates, and logs colocated with the explicit
override.

The desktop human session is stored in secure storage separately from the
runtime credential. Versioned lifecycle preferences store only desired runtime state,
login-item and lock settings, and non-authoritative owner display metadata;
they never contain bearer credentials.

At first launch after the macOS layout change, Workspace copies missing
registration and runtime state from `~/.conclave-host`, excluding the local
Worker registry, old Worker packages, adapter packages, and work directories.
It moves update and log directories when the new destination is empty, and
moves the former default Work Root only when the new location is absent.
Workspace never deletes Work Root. A
migration marker makes subsequent launches idempotent. If an older Workspace
process still holds the legacy runtime lock, close it and reopen the updated
app to retry migration.

## Connection stages

The runtime records these stages for the UI and diagnostics:

1. `validating`: local runtime credential and WebSocket endpoint are checked.
2. `connecting`: DNS/TLS and the HTTP WebSocket upgrade are attempted.
3. `authenticating`: upgrade succeeded and `workspace.hello` is awaiting its
   matching `workspace.hello.ack`.
4. `synchronizing`: Cloud acknowledged the runtime; sync result and Worker
   inventory are being reconciled.
5. `ready`: hello identity matched and synchronization/inventory completed.
6. `reconnecting` / `offline`: the link was lost or an attempt failed.

The hello acknowledgement and Cloud synchronization have bounded timeouts.
Diagnostics include the Cloud origin, safe WebSocket endpoint, runtime ID,
whether a local runtime credential is available, current stage, HTTP upgrade
status, whether `workspace.hello` was sent/acknowledged, last attempt, and last
ready time. Credential values and arbitrary URL
query parameters are excluded. The Advanced & Diagnostics panel can copy this
connection-only report and immediately retry the socket without recreating
Workers or interrupting their local processes.

HTTP 400 means the WebSocket request was rejected before a successful 101
upgrade. If the client URI is valid and the current Workspace build still
receives 400, check that Cloud is running the release which forwards the
original upgrade `Request` into the Durable Object (`c1b8708` or a later
commit). A repository commit does not deploy the production Cloud Worker.

When fallback is active, the UI reports **Connected · HTTPS fallback** and
explains that WebSocket is unavailable while work can continue. Diagnostics
retain both the latest WSS failure and current fallback health. Fallback does
not indicate human-session expiry; management reauthentication does not mean
the runtime transport is offline. For ownership conflicts, sign in as the
current Workspace owner; do not reset or replace local identity. Disconnect
preserves owner binding, while Release is the explicit ownership transition.
See the [lifecycle troubleshooting and production validation runbook](WORKSPACE_DESKTOP_LIFECYCLE_RELEASE_VALIDATION.md).

## Cloud Gateway checkpoints

The Cloud Worker and `WorkspaceGateway` emit structured `GW-01` through
`GW-12` records for upgrade receipt, runtime authentication, forwarding,
Durable Object acceptance, `workspace.hello`, and synchronization. Search the
Worker logs by the `correlation.requestId` value. On production requests this
is Cloudflare's `CF-Ray` ID, which is already on the original upgrade request
and is preserved when it is forwarded unchanged. The Durable Object stores
that ID in the WebSocket attachment so hello and sync records retain it after
the handshake. These records include runtime and Workspace IDs, but never
credential values, authorization headers, cookies, or provider secrets.

## Engine and Tool Profile diagnostics

For v8 Workers, Workspace keeps bounded per-Worker JSONL diagnostic records.
They identify Workspace and Engine versions, the logical Worker, Tool Profile
definition/release and resolution source, provider tool/version, probe stage,
run ID, stable error code, duration, and failure layer (`engine`, `profile`, or
`provider_tool`). Assignment/request IDs are included when available. The
Advanced Diagnostics panel shows the Engine version and resolved official
integration release alongside the provider CLI version.

Diagnostics are designed for attribution, not reproduction of user input.
They omit Profile payloads, signing material, provider/runtime credentials,
prompts, raw provider output, and arbitrary environment values. An unavailable
Profile resolution is reported as such; diagnostics do not silently present an
incompatible release as active.

### Profile release channels

Cloud defaults every Workspace to the `stable` Tool Profile channel. During
internal validation, a platform administrator can opt a Workspace into
`testing` or `beta` with the authenticated Cloud operation
`PATCH /api/workspaces/{workspaceId}/tool-profile-channel`, passing one
`channel` field. Return the Workspace to normal production delivery with
`channel: "stable"`. Workspace catalog requests authenticate with the runtime
credential and cannot select a channel themselves; Cloud resolves the
Workspace's assigned channel and returns only that channel's current release.
Use the normal Worker Test action for explicit real-provider acceptance; routine
channel sync runs only a passive readiness probe and does not spend model quota.
