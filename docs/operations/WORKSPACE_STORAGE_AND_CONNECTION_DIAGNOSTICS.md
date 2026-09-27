# Workspace storage and connection diagnostics

Conclave Workspace prepares local storage before contacting Cloud. Work Root,
runtime state, the log directory, and their permissions are checked locally;
the app does not request a separate macOS “internet permission.” macOS App
Sandbox remains disabled because Workspace launches local Worker adapters and
developer tools. Do not enable it without a separate subprocess/filesystem
design; if sandboxing is introduced, outgoing network access also needs the
Apple network-client entitlement.

## macOS storage layout

The default layout is:

```text
~/Library/Application Support/Conclave/Workspace/
    State/       runtime identity, Workspace registration, Worker metadata,
                 and assignment journal
    Work/        Workstream working directories
    Adapters/    admitted adapter packages
    Updates/     staged Workspace updates
~/Library/Logs/Conclave Workspace/
    host.log
```

Runtime and Worker credentials remain in macOS Keychain. They are not stored
in this directory, copied into connection URL parameters, or included in
diagnostics. Runtime authentication is sent in the WebSocket authorization
header. `--data-dir` and
`CONCLAVE_HOST_DATA_DIR` remain supported and keep their state, adapter, update,
and log directories colocated with the explicit override.

At first launch after the layout change, Workspace copies missing legacy state
from `~/.conclave-host`, moves legacy adapter/update/log directories when the
new destination is empty, and renames the old default Work Root when the new
Work Root does not exist. It never overwrites destination files or deletes the
legacy source. A migration marker makes subsequent launches idempotent. If an
older Workspace process still holds the legacy runtime lock, close it and
reopen the updated app to retry migration.

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
