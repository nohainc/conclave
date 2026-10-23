[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')][string]$Mode = 'release'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') {
    throw 'Build Workspace for Windows on a Windows host with Flutter and Visual Studio C++ desktop tools.'
}
if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw 'This preview build currently requires a Windows x64 host.'
}
$Root = Split-Path $PSScriptRoot -Parent
$Workspace = Join-Path $Root 'apps/workspace'
foreach ($Tool in @('flutter', 'dart', 'node', 'git')) {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        throw "$Tool is required (bash must be Git for Windows Bash, not WSL)."
    }
}
# Resolve Git's Bash explicitly: PATH may point bash at WSL, which would
# compile a Linux Engine and service instead of Windows executables.
$GitRoot = Split-Path (Split-Path (Get-Command git).Source -Parent) -Parent
$GitBash = Join-Path $GitRoot 'bin/bash.exe'
if (-not (Test-Path $GitBash)) { throw 'Git for Windows bin/bash.exe is required.' }
function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}
Push-Location $Root
try {
    # Reuse the canonical Engine and standalone service build, not a second
    # Windows implementation. These scripts select .exe on Git Bash hosts.
    $Trust = & node scripts/resolve-build-release-trust.mjs
    if ($LASTEXITCODE -ne 0) { throw 'Public application-release trust is required.' }
    Invoke-Checked $GitBash @('scripts/build-workspace-service.sh')
    $DefineFile = Join-Path ([System.IO.Path]::GetTempPath()) ("conclave-windows-" + [guid]::NewGuid() + '.json')
    Push-Location $Workspace
    try {
        $Version = ((Get-Content pubspec.yaml | Select-String '^version:').Line -replace '^version:\s*', '').Trim()
        # A define file preserves JSON quotes through Windows .bat launchers.
        $Defines = @{
            CONCLAVE_WORKSPACE_ENVIRONMENT = 'production'
            CONCLAVE_WORKSPACE_VERSION = $Version
            CONCLAVE_RELEASE_TRUST_KEYS_JSON = [string]$Trust
        } | ConvertTo-Json
        [System.IO.File]::WriteAllText($DefineFile, $Defines, [System.Text.UTF8Encoding]::new($false))
        Invoke-Checked 'flutter' @('build', 'windows', "--$Mode",
            "--dart-define-from-file=$DefineFile")
    } finally {
        Pop-Location
        Remove-Item $DefineFile -ErrorAction SilentlyContinue
    }
    $Configuration = if ($Mode -eq 'release') { 'Release' } else { 'Debug' }
    $Build = Join-Path $Workspace "build/windows/x64/runner/$Configuration"
    $Output = Join-Path $Root "dist/conclave-workspace/windows/$Mode"
    New-Item -ItemType Directory -Force $Output | Out-Null
    # Only replace files inside this build's output folder; never touch user state.
    Get-ChildItem $Output | Remove-Item -Recurse -Force
    Copy-Item "$Build/*" $Output -Recurse -Force
    $ServiceBuild = Join-Path $Root 'dist/conclave-workspace/service'
    Copy-Item (Join-Path $ServiceBuild 'conclave-service.exe') $Output
    # The standalone service discovers assets relative to its own executable;
    # the Flutter UI uses its data/flutter_assets copy of the same Engine.
    Copy-Item (Join-Path $ServiceBuild 'assets') $Output -Recurse -Force
    $DartPayload = if ($Mode -eq 'release') { 'data/app.so' } else { 'data/flutter_assets/kernel_blob.bin' }
    foreach ($File in @('conclave_workspace.exe', 'flutter_windows.dll', $DartPayload,
                        'data/flutter_assets/assets/engines/conclave_cli_worker_engine.exe',
                        'assets/engines/conclave_cli_worker_engine.exe', 'conclave-service.exe')) {
        if (-not (Test-Path (Join-Path $Output $File))) { throw "Bundle is missing $File" }
    }
    $BundledEngine = Join-Path $Output 'data/flutter_assets/assets/engines/conclave_cli_worker_engine.exe'
    $CanonicalEngine = Join-Path $Workspace 'assets/engines/conclave_cli_worker_engine.exe'
    $ServiceEngine = Join-Path $Output 'assets/engines/conclave_cli_worker_engine.exe'
    if ((Get-FileHash $BundledEngine).Hash -ne (Get-FileHash $CanonicalEngine).Hash -or
        (Get-FileHash $ServiceEngine).Hash -ne (Get-FileHash $CanonicalEngine).Hash) {
        throw 'Bundled Engine does not match the canonical build.'
    }
    Copy-Item (Join-Path $Root 'docs/operations/WORKSPACE_WINDOWS_PREVIEW.md') (Join-Path $Output 'README.md')
    $Archive = Join-Path $Root "dist/conclave-workspace/conclave-workspace-windows-x64-$Mode-preview.zip"
    Compress-Archive -Path "$Output/*" -DestinationPath $Archive -Force
    Write-Host "Built unsigned Windows UI preview: $Archive"
    Write-Warning 'Unsigned runtime candidate. Real provider execution, logon/reboot and release signing require qualification on the target Windows device.'
} finally { Pop-Location }
