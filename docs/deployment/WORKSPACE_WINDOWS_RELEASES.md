# Windows Workspace releases

The manually dispatched [Windows release workflow](../../.github/workflows/release-windows.yml)
builds the Windows x64 bundle, Authenticode-signs every executable and DLL,
builds a signed Inno Setup installer (Setup.exe and its embedded uninstaller),
tests install/upgrade/uninstall on the signed installer and, when `publish` is
set, attaches the installer, ZIP and `SHA256SUMS` to an immutable GitHub
Release tagged `workspace-windows-v<version>`.

Signing is done by [`scripts/sign-workspace-windows.ps1`](../../scripts/sign-workspace-windows.ps1).
Every signature uses SHA-256 and an RFC 3161 timestamp, and is verified with
`signtool verify /pa` and `Get-AuthenticodeSignature` before packaging and again
on the installer. The bundled Engine is signed once and copied to its second
bundle location so both copies stay byte-identical.

## One-time setup

1. **Get a code-signing identity.** Pick one:
   - **Azure Trusted Signing (recommended).** Create a Trusted Signing account
     and complete public identity validation for the publishing organization,
     then create a *Public Trust* certificate profile. Create an Entra ID app
     registration with a client secret and grant it the
     *Trusted Signing Certificate Profile Signer* role on the account.
     Signatures build SmartScreen reputation immediately and no key leaves Azure.
   - **Certificate file (OV).** Buy an OV code-signing certificate that the CA
     will issue as an exportable PFX. EV and most new OV certificates are only
     issued on hardware tokens/HSMs and cannot be used with this backend; use
     Azure Trusted Signing instead.
2. **Create the `workspace-windows-release` GitHub environment.** Restrict
   deployment to `main` and require a reviewer.
3. **Configure the environment.**

   | Kind | Name | Value |
   | --- | --- | --- |
   | variable | `CONCLAVE_WINDOWS_SIGNING` | `azure` or `pfx` |
   | variable | `CONCLAVE_RELEASE_TRUST_KEYS_JSON` | production public trust roots (repository variable, as for macOS) |
   | variable (azure) | `CONCLAVE_WINDOWS_TRUSTED_SIGNING_ENDPOINT` | regional endpoint, e.g. `https://eus.codesigning.azure.net` |
   | variable (azure) | `CONCLAVE_WINDOWS_TRUSTED_SIGNING_ACCOUNT` | Trusted Signing account name |
   | variable (azure) | `CONCLAVE_WINDOWS_TRUSTED_SIGNING_PROFILE` | certificate profile name |
   | variable (azure, optional) | `CONCLAVE_WINDOWS_TRUSTED_SIGNING_CLIENT_VERSION` | `Microsoft.Trusted.Signing.Client` NuGet version (default `1.0.53`) |
   | secret (azure) | `CONCLAVE_WINDOWS_AZURE_TENANT_ID` | Entra tenant ID |
   | secret (azure) | `CONCLAVE_WINDOWS_AZURE_CLIENT_ID` | app registration client ID |
   | secret (azure) | `CONCLAVE_WINDOWS_AZURE_CLIENT_SECRET` | app registration secret |
   | secret (pfx) | `CONCLAVE_WINDOWS_CERTIFICATE_PFX` | base64 of the `.pfx` (`base64 -i cert.pfx`) |
   | secret (pfx) | `CONCLAVE_WINDOWS_CERTIFICATE_PASSWORD` | PFX password |
   | variable (pfx, optional) | `CONCLAVE_WINDOWS_TIMESTAMP_URL` | RFC 3161 server (default DigiCert) |

## Publishing a release

1. Set `version:` in `apps/workspace/pubspec.yaml` to the release version
   (`X.Y.Z`; prerelease versions are not packaged) and push to `main`.
2. Wait for CI on that commit to succeed.
3. Dry run: dispatch **Release Windows Workspace** from `main` with the version
   and `publish` unchecked. Download the `conclave-workspace-windows-x64-release`
   artifact and qualify it on a real Windows 10/11 x64 device (see below).
4. Publish: dispatch again with `publish` checked. The workflow requires the
   CI gate, rebuilds and re-signs, and creates the GitHub Release. Existing tags
   are never overwritten; bump the version to ship a fix.

## Device qualification before announcing

- Right-click Setup.exe → Properties → Digital Signatures shows the Conclave
  publisher with a timestamp; `Get-AuthenticodeSignature` reports `Valid` for
  Setup.exe, `conclave_workspace.exe`, `workspace.exe` and the Engine.
- The installer UAC/SmartScreen prompt names the publisher (no "Unknown
  publisher").
- Sign-in, registration, service install/start, a real provider assignment,
  logon/reboot recovery, upgrade over the previous version and uninstall
  (`conclave-workspace service uninstall` first) all work; see
  [the installer notes](../operations/WORKSPACE_WINDOWS_INSTALLER.md).
- Run `sha256sum -c SHA256SUMS` against the downloaded release assets.

## Notes

- The Cloud `/api/workspace-releases` catalog is keyed by version alone and
  currently carries the macOS archive, so Windows releases are distributed via
  GitHub Releases and not through the in-app updater. Adding per-platform
  packages to the catalog is a separate Cloud schema change.
- SmartScreen reputation with an OV certificate accrues per certificate over
  downloads; expect warnings for early releases. Azure Trusted Signing avoids
  most of this.
- When a certificate is renewed or rotated, earlier timestamped releases stay
  valid. Revoke compromised certificates with the CA/Azure and re-release.
