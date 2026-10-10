# Workspace Runtime Service Phase 4

## Runtime ownership

The standalone Workspace Service is the only owner of local execution state:

- Workspace identity and Cloud transport;
- Worker catalog, local Worker inventory, and readiness;
- CLI Worker Engine child processes;
- assignment admission, cancellation, and journal recovery;
- Worker sessions, runtime logs, and Work Root access.

Workspace.app is a management client. Worker inventory, readiness checks, and
Worker tests are authenticated IPC requests. The app does not start a Worker
Engine or provider CLI itself.

## Worker lifecycle

Worker Engine processes are created for probes and assignments on demand. The
service records each child process in its private runtime registry and reaps
records that still identify an orphaned Engine after a service restart. A
Worker Engine exit is reported through the assignment/readiness state and does
not leave an unmanaged child process running.

The service keeps readiness checks event-driven: startup performs one passive
check, catalog/profile changes request another check, and a user-triggered
Worker test performs a live check. There is no UI polling loop and no idle
Engine process for a configured Worker.

## Recovery contract

The service process can be healthy while Cloud is disconnected or reconnecting.
Cloud reconnect uses bounded exponential backoff and a wake/retry path. The
assignment journal records durable transitions and marks an interrupted
assignment as `outcome_unknown` after a crash; the service reconciles that
record with Cloud before reporting a final result and never blindly reruns it.

On startup the service acquires the installation lock, reaps only Engine PIDs
whose executable and private state directory match the current installation,
recovers the assignment journal, starts the local runtime, and then restores
the persisted Cloud intent. Closing Workspace.app only closes its IPC client.

The recovery matrix is covered by focused tests for stopped/running service
states, disconnected/reconnecting Cloud, Worker process cleanup, assignment
journal recovery, service restart, and IPC reattachment. macOS sleep/wake and
reboot/login are exercised through the same reconnect and launch-agent paths;
the process is not expected to execute while the machine is asleep.

## macOS development builds

An Apple-signed build is required for SMAppService LaunchAgent execution. The
normal macOS build validates the app, service helper, Worker Engine, team
identifier, and LaunchAgent constraints together. A debug build can be signed
with:

```text
./scripts/build-workspace-macos.sh --debug --sign "Apple Development: ..."
```

An ad-hoc debug build remains useful for UI-only work, but it reports that the
background service is unavailable and disables service launch actions instead
of presenting a control that launchd will reject with a code-signing error.

The standalone service is compiled with the same public
`CONCLAVE_RELEASE_TRUST_KEYS_JSON` roots as the Flutter application. Profile
verification therefore has one trust policy in the UI and service; the service
does not fall back to an empty trust configuration when it downloads a signed
Tool Profile.
