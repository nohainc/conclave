# Run only on a disposable Windows CI runner. Uses an isolated application folder.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = Split-Path $PSScriptRoot -Parent
$Installer = @(Get-ChildItem (Join-Path $Root 'dist/conclave-workspace/installer/*Setup.exe'))
if ($Installer.Count -ne 1) { throw 'Expected exactly one installer.' }
$Target = Join-Path $env:LOCALAPPDATA 'Programs/Conclave/Workspace-Installer-Test'
function Run-Setup {
    $Process = Start-Process $Installer[0].FullName -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$Target`"") -Wait -PassThru
    if ($Process.ExitCode -ne 0) { throw "Setup failed: $($Process.ExitCode)" }
}
Run-Setup
$Engine = 'assets/engines/conclave_cli_worker_engine.exe'
foreach ($File in @('conclave_workspace.exe', 'conclave-service.exe', $Engine)) {
    if ((Get-FileHash (Join-Path $Target $File)).Hash -ne
        (Get-FileHash (Join-Path $Root "dist/conclave-workspace/windows/release/$File")).Hash) {
        throw "Installed file mismatch: $File"
    }
}
# Repeat installation to exercise the stable AppId upgrade path.
Run-Setup
$App = Start-Process (Join-Path $Target 'conclave_workspace.exe') -WorkingDirectory $Target -PassThru
try {
    Start-Sleep -Seconds 8
    $App.Refresh()
    if ($App.HasExited) { throw 'Installed UI exited early.' }
    $Blocked = Start-Process $Installer[0].FullName -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$Target`"") -Wait -PassThru
    if ($Blocked.ExitCode -eq 0) { throw 'Installer should refuse an active Workspace.' }
} finally {
    if (-not $App.HasExited) { Stop-Process -Id $App.Id -Force; $App.WaitForExit() }
}
$Uninstall = Start-Process (Join-Path $Target 'unins000.exe') -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Wait -PassThru
if ($Uninstall.ExitCode -ne 0) { throw "Uninstall failed: $($Uninstall.ExitCode)" }
if (Test-Path (Join-Path $Target 'conclave_workspace.exe')) { throw 'Uninstall left the app executable.' }
