[CmdletBinding()]
param(
    [string]$Compiler = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    # Authenticode-sign the installer and uninstaller (see sign-workspace-windows.ps1).
    [switch]$Sign
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = Split-Path $PSScriptRoot -Parent
$Bundle = Join-Path $Root 'dist/conclave-workspace/windows/release'
$Output = Join-Path $Root 'dist/conclave-workspace/installer'
if (-not (Test-Path $Compiler)) { throw 'Inno Setup 6 ISCC.exe is required.' }
foreach ($File in @('conclave_workspace.exe', 'workspace.exe', 'flutter_windows.dll',
    'data/app.so', 'assets/engines/conclave_cli_worker_engine.exe',
    'data/flutter_assets/assets/engines/conclave_cli_worker_engine.exe')) {
    if (-not (Test-Path (Join-Path $Bundle $File))) { throw "Missing release bundle file: $File" }
}
$VersionLine = (Select-String -Path (Join-Path $Root 'apps/workspace/pubspec.yaml') -Pattern '^version:').Line
$Version = ($VersionLine -replace '^version:\s*', '').Trim().Split('+')[0]
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Unsupported installer version: $Version" }
New-Item -ItemType Directory -Force $Output | Out-Null
$CompilerArguments = @("/DBundleDir=$Bundle", "/DAppVersion=$Version", "/DOutputDir=$Output")
$SignScript = Join-Path $PSScriptRoot 'sign-workspace-windows.ps1'
if ($Sign) {
    # A signed installer must only ship signed binaries.
    & $SignScript -Bundle $Bundle -VerifyOnly
    # Inno Setup substitutes $q with a quote and $f with the quoted file path.
    $CompilerArguments += @('/DSignInstaller',
        "/Sconclave=powershell.exe -NoProfile -ExecutionPolicy Bypass -File `$q$SignScript`$q `$f")
}
& $Compiler @CompilerArguments (Join-Path $Root 'packaging/windows/workspace.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed: $LASTEXITCODE" }
$Installer = Join-Path $Output "Conclave-Workspace-$Version-windows-x64-Setup.exe"
if (-not (Test-Path $Installer)) { throw 'Installer was not produced.' }
if ($Sign) { & $SignScript $Installer -VerifyOnly }
Get-FileHash $Installer -Algorithm SHA256 | Format-List
