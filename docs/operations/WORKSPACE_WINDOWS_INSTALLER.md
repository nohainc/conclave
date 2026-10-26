# Windows Workspace installer

The Windows build workflow produces an unsigned per-user Inno Setup installer
alongside the ZIP candidate. This is not a signed production release.

Run `scripts/build-workspace-windows.ps1`, then
`scripts/package-workspace-windows.ps1` on Windows with Inno Setup 6 installed.
The workflow pins compiler 6.7.3 from the official release with a SHA-256 check. Outputs are under
`dist/conclave-workspace/installer/` and uploaded as
`conclave-workspace-windows-x64-installer`. The application version comes from
`apps/workspace/pubspec.yaml`; prerelease versions require an explicit packaging
policy before they can be packaged.

The installer copies the complete canonical bundle, including both Engine
locations, to `%LOCALAPPDATA%\Programs\Conclave\Workspace` and adds a Start
menu shortcut and Windows uninstall entry. It requires no administrator rights.
A stable AppId enables in-place upgrades. Silent installation supports
`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`.

Before upgrading, run `conclave-workspace service stop`. Installation and
uninstall refuse to proceed while any Workspace service process is running; inspection failure also blocks installation. No
provider processes are forcibly terminated. An installation in a different
folder also blocks the operation conservatively.

Runtime registration remains owned by WorkspaceServiceManager, not the
installer. Before uninstalling, run `conclave-workspace service uninstall`. `service stop` alone preserves registration. The installer does not
remove scheduled tasks, Cloud identity, DPAPI credentials, runtime state,
sessions, provider logins, or Work Root files. Reinstall to the same location to
recover a retained registration. No schema, protocol, or state migration occurs.

The disposable Windows runner tests silent installation, installed executable
hashes and installed-service lifecycle, repeat installation, UI startup, rejection while running, and uninstall.
Real assignment upgrade recovery, reboot/logon, signing, and interactive desktop
qualification remain release checks. CI uses the existing compile-only trust
root; this installer does not establish production release trust.
