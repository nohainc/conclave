# Workspace Runtime Service Phase 3

> **Historical implementation record.** The current architecture is defined
> in [WORKSPACE_ARCHITECTURE.md](WORKSPACE_ARCHITECTURE.md).

## Independent service and Cloud state

The Workspace Service owns the local runtime. Cloud connectivity is a separate
connection managed by that service through IPC commands from Workspace.app.

### Service state

The service state is made from independent facts:

```yaml
registered: true
processRunning: true
ipcReady: true
serviceHealthy: true
```

`serviceHealthy` means that the local process is running and its authenticated
IPC endpoint is ready. It does not require a Cloud connection.

### Cloud state

Cloud state is reported separately:

```yaml
desiredConnectionState: connected | disconnected
connectionStage: validating | connecting | authenticating | synchronizing |
  switchingToWebSocket | reconnecting | ready | offline
transport: websocket | http_long_poll | null
authenticated: true
synchronized: true
acceptingWork: true
```

The service can therefore be healthy while Cloud is disconnected or
reconnecting. Cloud failures must not be presented as local service failures.

The user's Cloud intent is persisted in the local lifecycle preferences under
`desiredCloudState`. Older `desiredRuntimeState` files are read during the
local migration window so existing installations preserve their intent.

## Lifecycle commands

`Start Service` registers the service when needed and starts the local process.
It does not issue `connection.connect` directly. Once started, the service
restores a persisted connected Cloud intent on its own.

`Connect` and `Disconnect` are authenticated IPC commands. Connect persists
`desiredCloudState: connected`; Disconnect persists
`desiredCloudState: disconnected`. Disconnect leaves the local service
running.

`Stop Service` drains active assignments, disconnects Cloud, closes IPC, and
stops the process. It does not unregister the service and does not rewrite the
user's Cloud intent. `Unregister` is a separate host-management operation.

## UI boundary

Workspace.app obtains host registration/process information from the macOS
service manager and obtains runtime/Cloud information from the service IPC
snapshot. It does not own the Cloud socket, worker supervision, or assignment
processing.
