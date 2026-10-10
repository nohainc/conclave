# Workspace Runtime Service — Phase 3: macOS service packaging

**Status:** Native registration bridge and bundle packaging implemented; full
UI ownership handoff and signed-device acceptance remain open.

## Bundle contract

The macOS distribution contains:

```text
Conclave Workspace.app/Contents/
├── Helpers/
│   ├── conclave-workspace-service
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
valid evidence that macOS will accept background registration.

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

The manager UI still starts an in-process runtime, as recorded in the
[Phase 1 audit](WORKSPACE_RUNTIME_SERVICE_PHASE_1.md). Therefore the embedded
agent must not yet be presented as a fully supported replacement runtime in
the management UI: activating both owners can contend for the per-installation
lock, and the current UI does not display IPC snapshots or route management
commands through the service. Phase 2's UI ownership handoff is required before
the first-run “Enable Background Service” flow is complete.

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
