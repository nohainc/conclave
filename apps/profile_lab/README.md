# Conclave Profile Lab

Conclave Profile Lab is an internal macOS desktop application for creating and maintaining Logical Workers and their Tool Profiles. Operators use it to edit Drafts, run the generic CLI Worker Engine against locally installed provider CLIs, qualify a Draft with Cloud, and manage the signed release lifecycle.

This README is for developers and authorized operators. The normative product and API contracts are in the [Profile Lab specification](../../docs/specifications/PROFILE_LAB.md), [Tool Profile lifecycle specification](../../docs/specifications/TOOL_PROFILE_LIFECYCLE.md), [Tool Profile v1 contract](../../docs/specifications/TOOL_PROFILE_V1.md), [Architecture v8](../../docs/architecture/ARCHITECTURE_V8.md), and [ADR-019](../../docs/decisions/ADR-019-conclave-profile-lab.md).

## Product boundaries

- **Profile Lab** authors local Drafts, runs sandbox tests, and provides the administrative interface for Cloud qualification and release management.
- **The CLI Worker Engine** executes Profile-defined behavior using provider CLI programs installed on the operator's Mac. Provider behavior belongs in Worker and Tool Profile data, not provider-specific app branches.
- **Conclave Cloud** owns the Worker catalog, release records, qualification and acceptance evidence, channel pointers, authorization, audit records, and release signing. Profile Lab uses Cloud APIs and has no direct database access.
- **Conclave Workspace** runs admitted, signed releases and owns local Work Roots and execution sessions. Profile Lab is not a Workspace: it does not accept Work assignments or own Work Roots.
- Provider CLI login and credentials stay with the locally installed provider CLI. Profile Lab does not collect or store provider API keys.

## Local development

Profile Lab targets macOS. Install Flutter with macOS desktop support and the Xcode command-line tools. From the repository root, install the repository dependencies and fetch the app's Dart dependencies:

```sh
pnpm install
cd apps/profile_lab
flutter pub get
cd ../..
```

Build the actual CLI Worker Engine binary before launching the app; the app's fixture acceptance tests also use this binary:

```sh
bash scripts/build-cli-worker-engine.sh
```

For local Cloud development, start the repository's local Cloud environment (the root `pnpm start:local` flow starts Cloud and the AX web app), then run Profile Lab from the repository root:

```sh
cd apps/profile_lab
flutter run -d macos --dart-define=CONCLAVE_CLOUD_URL=http://localhost:8787
```

You can also change the origin in **Cloud connection** settings while the app is running. The setting is a Cloud origin only: credentials, URL paths, query strings, and fragments are rejected. HTTP is permitted only for loopback in development builds. Release builds require HTTPS.

## Cloud configuration and authentication

The build default is `https://app.conclaveax.com`. For a development build, set `CONCLAVE_CLOUD_URL` with a Dart define; operators can save a local origin override or reset it to the build default in Cloud connection settings. The override is non-secret app configuration. Changing the Cloud origin clears the current sign-in because sessions are bound to their origin.

Sign-in opens a browser approval flow for **Conclave Profile Lab**, using the dedicated `conclave.profile-lab.management` audience. It is separate from Conclave Workspace authentication. The resulting session is stored in the macOS login Keychain under the Profile Lab service and is scoped to the selected Cloud origin. Cloud must authorize the account for the operation: catalog and Draft administration use `profiles:admin`; release management uses `profiles:release:manage`. Stable channel changes, rollback, and revocation require a recent passkey step-up.

For local Cloud development, configure an authorized test account in the local Cloud environment. Do not copy a Workspace session or put a bearer token in app configuration or source control.

## Build and verification

Run the canonical Profile Lab macOS verification pipeline from the repository root:

```sh
pnpm profile-lab:test
```

It builds the CLI Worker Engine, checks Dart formatting, runs Flutter analysis, and runs unit and integration tests. The script requires macOS and Flutter.

Build the macOS app from the repository root:

```sh
pnpm profile-lab:build
```

The build script defaults to a release build. For a local debug build or a specific version, use the script directly:

```sh
bash scripts/build-profile-lab-macos.sh --debug
bash scripts/build-profile-lab-macos.sh --version 1.2.3
```

The app archive is written under `dist/conclave-profile-lab/macos/`. An unsigned build is a development artifact. Set `CONCLAVE_MACOS_SIGN_IDENTITY` (or pass `--sign`) for Apple Developer ID signing; set `CONCLAVE_MACOS_NOTARY_PROFILE` to notarize a signed archive. Apple app signing is separate from Tool Profile release signing.

## Draft, evidence, and release lifecycle

1. Create or edit a local Draft. New Worker catalog entries begin in the `testing` stage; Draft is a Profile release state, not a Worker catalog stage.
2. Run Profile Lab's test ladder. It performs preflight checks and actual assignments through the generic CLI Worker Engine in an isolated sandbox. Applicable scenarios must execute and pass; scenarios unsupported by the Profile are reported as `not_applicable`, not passed.
3. Save the Draft to Cloud and submit its scenario evidence as local qualification for that exact payload digest. Cloud validates and stores qualification immutably. Editing the payload changes its digest, so earlier evidence no longer qualifies it.
4. Publish using the stored qualification ID. Cloud validates the qualification and signs an immutable release into Testing. A publication request does not supply UI-generated signing material or invent test outcomes.
5. Submit separate acceptance evidence for a published release before Stable promotion. Promotion references the Cloud evidence ID; Cloud reloads and checks the stored record against the release. Beta and Stable promotion, Workspace channel assignment, rollback, and revocation are Cloud-controlled lifecycle operations.

Cloud evidence is an authenticated, digest-bound assertion submitted by Profile Lab; it is not remote attestation of the local Mac or provider process. Keep test results tied to the actual Engine execution and use the fixture acceptance path for deterministic generic process tests.

## Signing assumptions

Cloud is the release signing authority. Its production signer and matching trust configuration must pass Cloud preflight; publication fails closed when signer readiness or qualifying evidence is missing. Private release signing keys belong only in the managed Cloud signer configuration and must never be added to Profile Lab, Workspace, build arguments, or repository files.

`CONCLAVE_RELEASE_TRUST_KEYS_JSON` is a build-time **public** Ed25519 trust-root map used to verify signed Profiles (and trusted model runners). Its shape is `{ "publisher": { "key-id": "base64-raw-public-key" } }`. The build script defaults it to `{}`; with no valid trusted root, signatures cannot be verified and trusted model runners are unavailable. Supply the managed public trust roots used by Workspace. This setting is not a signing key and cannot sign releases.

## Security rules

- Keep Cloud origins HTTPS outside local development. The app accepts HTTP only for loopback in non-release builds and rejects origins containing credentials or a path.
- Keep Profile Lab sessions in macOS Keychain. Do not log credentials, access tokens, provider secrets, or unredacted provider output.
- Keep provider credentials in the provider's own local CLI login. Never put credentials in a Tool Profile, Draft metadata, evidence, or source control.
- Treat sandbox input and process output as untrusted. Use the supervised Engine path, bounded execution, secret redaction, and cleanup; do not bypass it with direct provider execution in application code.
- Keep authorization and release transitions server-side. The UI may request an operation, but Cloud must enforce permissions, step-up, evidence qualification, signer readiness, and release state.
- Never embed a Cloud private key, signing seed, or other secret in the app bundle. Public verification roots may be bundled.

## Implementation references

- [Profile Lab specification](../../docs/specifications/PROFILE_LAB.md)
- [Tool Profile lifecycle](../../docs/specifications/TOOL_PROFILE_LIFECYCLE.md)
- [Tool Profile evidence contract](../../docs/specifications/TOOL_PROFILE_EVIDENCE_CONTRACT.md)
- [Tool Profile v1](../../docs/specifications/TOOL_PROFILE_V1.md)
- [Architecture v8](../../docs/architecture/ARCHITECTURE_V8.md)
- [ADR-019: Conclave Profile Lab](../../docs/decisions/ADR-019-conclave-profile-lab.md)

## Unsigned development

Run `bash scripts/run-profile-lab-development.sh` from the repository root for
hot-reload development against loopback Cloud (default `http://localhost:8787`).
Browser sign-in remains required; the verified `vitalii@nohainc.com` account is
the configured Lab owner. Cloud currently allows draft authoring and local tests
with publication disabled. Start `bash scripts/run-workspace-development.sh` to
consume saved local drafts in a separate non-release Workspace. Release
Workspaces still require signed Profiles.

The macOS build script defaults to skipping Developer ID signing and notarization;
use `--unsigned` explicitly when packaging development builds. See the
[development contract](../../docs/specifications/PROFILE_LAB.md#development-access-and-unsigned-execution).
