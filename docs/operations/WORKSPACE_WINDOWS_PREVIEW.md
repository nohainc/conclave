# Workspace Windows build preview

The Windows runner and build pipeline are a UI/build preview. They do not yet
provide an operational Workspace execution host. Windows support is incomplete.

## Build on Windows x64

Install Flutter, Node.js, Git for Windows (including Bash), and Visual Studio
with Desktop development with C++ and the Windows SDK. Run `flutter doctor -v`.
Supply `CONCLAVE_RELEASE_TRUST_KEYS_JSON` with the same public Ed25519 release
trust roots used by other Workspace builds; no signing private keys are needed.
From the repository root in PowerShell:

```powershell
./scripts/build-workspace-windows.ps1
```

The script reuses `build-workspace-service.sh` and its canonical Engine build,
compiles the Windows Flutter runner, checks bundle contents and creates
`dist/conclave-workspace/conclave-workspace-windows-x64-release-preview.zip`.
The ZIP includes the full Flutter data/DLL directory and standalone service,
with matching Engine copies in the UI assets and beside the service.
Keep the extracted directory together. The target machine also needs the
Microsoft Visual C++ x64 redistributable. The preview is unsigned and has no
installer, service registration or automatic update integration.

The **Build Windows Workspace preview** GitHub Actions workflow runs manually
or on `codex/windows-workspace-preview-*` branches. It uses the repository
Actions variable `CONCLAVE_RELEASE_TRUST_KEYS_JSON` when configured, otherwise
the same compile-only public trust root as nightly CI. The fallback cannot
verify production releases; this workflow is exclusively for preview builds. Its artifact is a preview,
not a published Workspace release. The workflow checks that the packaged UI stays running for eight seconds.
This startup smoke check does not verify rendering, lifecycle or security.

## Remaining runtime gates

Follow ADR-021 before enabling Windows execution:

- `WorkspaceServiceManager` per-user interactive logon task adapter.
- Owning-user-only named pipe with remote-client rejection and existing IPC auth.
- DPAPI CurrentUser credential storage and protected application-state paths.
- `%LOCALAPPDATA%\Conclave\Workspace` paths without altering existing macOS data.
- Engine Job Object cleanup and safe PATHEXT / command-shim invocation.
- Windows device checks for duplicate-owner locking, reboot/logon, stop/start,
  Cloud disconnect, credential persistence, and provider CLI execution.

The existing Windows IPC startup explicitly fails closed. The management UI
reports unsupported service management. Do not use this preview for real
assignments or claim that compiling the service enables Windows operation.
No existing installation, Cloud Workspace identity, credentials, or Work Root
is migrated by adding this runner.
