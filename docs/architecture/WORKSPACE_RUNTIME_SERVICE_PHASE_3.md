# Workspace Runtime Service — Phase 3: macOS service packaging

**Status:** Native registration bridge, bundle packaging, and IPC management
implemented; signed-device acceptance remains open.

## Bundle contract

The macOS distribution contains:

```text
Conclave Workspace.app/Contents/
├── Helpers/
│   ├── conclave-service
│   └── assets/engines/conclave_cli_worker_engine
└── Library/LaunchAgents/
    └── com.conclaveax.workspace.service.plist
```

The agent uses `BundleProgram` so Service Management resolves the executable
inside the containing app bundle. The package build compiles the Dart service,
copies its generic Worker Engine alongside it, embeds the launchd property list,
and signs both executables before the enclosing app when a Developer ID
identity is configured. The release archive is structurally checked before it
is created. The ad-hoc/unsigned development build can be inspected, but is not
valid evidence that macOS will accept background registration. macOS launch
constraints reject an ad-hoc helper before its entry point runs. Release builds
therefore require a valid Apple signing identity; unsigned debug builds are for
UI inspection only. The native registration boundary checks the helper against
the Apple signing anchor and reports an actionable signing error before
registration rather than allowing an inevitable IPC timeout.

The LaunchAgent also declares a `SpawnConstraint` for the helper's signing
identifier. Release builds add the helper's signing team identifier before the
containing app is sealed. This keeps the macOS launch constraint tied to the
actual signed helper and avoids a registration that reports success while
launchd rejects the process before its Dart entry point runs (notably on macOS
26 and later).

The native bridge exposes registration, unregistration, status, and opening
Login Items settings through the existing desktop method channel. It uses
`SMAppService.agent(plistName:)` on macOS 13 and later. Status values separate
unsupported OS, missing bundle files, not registered, registered, approval
required, and unknown. The native registration state does not claim that the
service process is running; the manager must verify process health through IPC.

The LaunchAgent supplies a bounded system/Homebrew `PATH`. Worker Engine
execution continues to use signed Tool Profile environment declarations and
allow-listed passthrough values; it does not forward the service's entire
environment to a provider CLI. The service must not depend on interactive shell
profiles.

## Ownership dependency

The Flutter manager is an authenticated local IPC client. Start Service registers
the embedded agent and verifies process health over IPC; Stop Service requests
a bounded assignment drain before unregistering through the native host bridge.
The generic Worker Engine is materialized as `conclave-agent`; the bundled
service is `conclave-service`. The LaunchAgent label is stable across updates.
Native registration alone is not proof that the process started. User approval,
TCC, Keychain access, and signed release behavior require the validation below.

## Required macOS release validation

Run this only with the signed/notarized candidate on a macOS test account. The
Linux CI/static checks cannot validate launchd, TCC, Keychain ACLs, or notarized
execution.

1. Inspect the app bundle and verify both helper executables, the LaunchAgent
   plist, Developer ID signatures, and notarization ticket.
2. Register the embedded agent from the native bridge and record the reported
   `SMAppService.Status`; separately verify the process connects over IPC.
3. Approve/disable the item in System Settings → General → Login Items and
   verify the app reports `requiresApproval` rather than claiming it is running.
4. Log out and back in. Confirm only the service starts, the GUI remains closed,
   Cloud reconnects, and a deterministic Worker assignment succeeds once.
5. Close and reopen the management app; verify it attaches to the existing
   service rather than creating a second runtime.
6. Repeat with Documents access and a custom Work Root selected by the UI.
   Verify the service can access the permitted paths. Record any TCC prompt and
   the signing identity associated with it; do not infer access from the GUI's
   permission alone.
7. Verify Keychain reads from the LaunchAgent, provider CLI discovery when
   launched without Terminal, and that secrets outside a signed Profile's
   passthrough allowlist do not reach provider processes.
8. Upgrade while an assignment is active. Verify the bounded drain completes
   or times out according to policy before the app bundle is replaced, then
   verify the registered service resolves the new embedded executable and
   recovers runtime state.

Do not mark the native acceptance criteria complete until these device tests
are recorded in
[Workspace desktop lifecycle release validation](../operations/WORKSPACE_DESKTOP_LIFECYCLE_RELEASE_VALIDATION.md).

## Stopped registration recovery

An enabled `SMAppService` registration can still refer to a previous
`BundleProgram` after updating the executable name. On explicit Start, the UI
first attempts IPC attachment, then asks the host to ensure registration.
The native bridge checks the launchd job locally. If it is stopped, it
unregisters/re-registers through Service Management to import the current bundle
plist. A running job is preserved; an uninspectable job reports an actionable
error. No manual plist installation, Cloud schema change, or installation
identity reset is involved. Verify this recovery using the signed-device gates
above after a bundle update.

The native status bridge exposes `launchdState`, nullable `lastExitCode`, and
nullable `lastExitReason` as additive diagnostic fields, independently of
registration and authenticated IPC health. A codesigning exit reason is
reported immediately so a broken certificate chain is not presented as a
generic IPC timeout. Only these selected values are returned from launchd
inspection; raw job output and its environment are never returned to Flutter.

The native parser uses the job's first state record; resource and jetsam
coalition states cannot override it. A compiled Swift regression fixture covers
both Running and Stopped jobs with nested Active coalitions and verifies that
environment attributes are excluded. Automated Unix-socket startup tests do
not replace signed-device login/reboot and LaunchAgent lifecycle acceptance.
