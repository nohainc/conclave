# Conclave Profile Lab

Conclave Profile Lab is an internal macOS desktop application for creating and maintaining Logical Workers and their Tool Profiles. Operators open a Worker, edit one local JSON candidate, run the generic CLI Worker Engine against locally installed provider CLIs, validate the exact candidate with Cloud, and publish it as the Worker’s next current Profile revision.

This README is for developers and authorized operators. The normative product and API contracts are in the [Worker Profile V9 specification](../../docs/specifications/WORKER_PROFILE_V9.md), [Profile Lab specification](../../docs/specifications/PROFILE_LAB.md), [Tool Profile v1 contract](../../docs/specifications/TOOL_PROFILE_V1.md), and [ADR-019](../../docs/decisions/ADR-019-conclave-profile-lab.md). The V8 lifecycle documents remain historical and are superseded by V9.

## Product boundaries

- **Profile Lab** authors one local candidate per Worker, runs the complete local test ladder, and requests Cloud validation/publication for that exact candidate digest.
- **The CLI Worker Engine** executes Profile-defined behavior using provider CLI programs installed on the operator's Mac. Provider behavior belongs in Worker and Tool Profile data, not provider-specific app branches.
- **Conclave Cloud** owns the Worker catalog, one current Profile, bounded history, digest/signature metadata, authorization, audit records, and atomic publication. Profile Lab uses Cloud APIs and has no direct database access.
- **Conclave Workspace** runs admitted, signed Profile snapshots and owns local Work Roots and execution sessions. Profile Lab is not a Workspace: it does not accept Work assignments or own Work Roots.
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

Sign-in opens a browser approval flow for **Conclave Profile Lab**, using the dedicated `conclave.profile-lab.management` audience. It is separate from Conclave Workspace authentication. The resulting session is stored in the macOS login Keychain under the Profile Lab service and is scoped to the selected Cloud origin. Cloud must authorize the account for the operation: Worker/Profile administration uses `profiles:admin`; publication requires `profiles:release:manage`. Cloud remains the signing authority; Profile Lab never holds signing keys.

For local Cloud development, configure an authorized test account in the local Cloud environment. Do not copy a Workspace session or put a bearer token in app configuration or source control.

## Build and verification

Unsigned builds reuse `.development/hosted-profile-trust.json` unless explicit
`CONCLAVE_RELEASE_TRUST_KEYS_JSON` public roots are supplied. Missing, empty,
or invalid trust fails the build. Developer ID signed builds require explicit
roots and never automatically adopt development keys.

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

## Candidate authoring, testing, and publication

1. Open a Worker. Profile Lab loads its one current published Profile, or starts the initial candidate from the Worker template.
2. Edit the JSON candidate locally. JSON schema validation, required fields, strict unknown-field handling, and size limits run immediately. Any edit invalidates prior test and Cloud-validation eligibility.
3. Run the local test ladder: schema validation, declarative Event Mapping Replay against sanitized Codex/agy fixtures, Engine compatibility, CLI discovery, CLI version support, authentication/readiness, deterministic execution and stdin transport, model discovery/selection, session continuation, error interpretation, cancellation/timeout enforcement, and authorized local-access checks where the Profile declares them. Repeated tool identifiers must produce matching start/completion activities, and unknown provider events are ignored.
4. Save the ladder evidence against the exact canonical candidate digest. Evidence contains only bounded identity, version, timestamp, and scenario results; it is not remote attestation of the local Mac or provider process.
5. Ask Cloud to validate the candidate, then publish it with the expected current revision. Cloud revalidates the JSON and evidence and atomically signs the next current Profile revision. Tests never change the current production Profile.

There are no Profile Lab testing, beta, or stable Profile channels in V9. Prior snapshots are inspected or restored through Cloud history, not promoted between channels.

## Signing assumptions

Cloud is the release signing authority. Its production signer and matching trust configuration must pass Cloud preflight; publication fails closed when signer readiness or qualifying evidence is missing. Private release signing keys belong only in the managed Cloud signer configuration and must never be added to Profile Lab, Workspace, build arguments, or repository files.

`CONCLAVE_RELEASE_TRUST_KEYS_JSON` is a build-time **public** Ed25519 trust-root map used to verify signed Profiles (and trusted model runners). Its shape is `{ "publisher": { "key-id": "base64-raw-public-key" } }`. The build script defaults it to `{}`; with no valid trusted root, signatures cannot be verified and trusted model runners are unavailable. Supply the managed public trust roots used by Workspace. This setting is not a signing key and cannot sign releases.

## Security rules

- Keep Cloud origins HTTPS outside local development. The app accepts HTTP only for loopback in non-release builds and rejects origins containing credentials or a path.
- Keep Profile Lab sessions in macOS Keychain. Do not log credentials, access tokens, provider secrets, or unredacted provider output.
- Keep provider credentials in the provider's own local CLI login. Never put credentials in a Tool Profile, Draft metadata, evidence, or source control.
- Treat sandbox input and process output as untrusted. Use the supervised Engine path, bounded execution, secret redaction, and cleanup; do not bypass it with direct provider execution in application code.
- Keep authorization and publication transitions server-side. The UI may request an operation, but Cloud must enforce permissions, evidence qualification, signer readiness, revision concurrency, and atomic Profile publication.
- Never embed a Cloud private key, signing seed, or other secret in the app bundle. Public verification roots may be bundled.

## Implementation references

- [Profile Lab specification](../../docs/specifications/PROFILE_LAB.md)
- [Tool Profile evidence contract](../../docs/specifications/TOOL_PROFILE_EVIDENCE_CONTRACT.md)
- [Tool Profile v1](../../docs/specifications/TOOL_PROFILE_V1.md)
- [Worker Profile V9](../../docs/specifications/WORKER_PROFILE_V9.md)
- [ADR-019: Conclave Profile Lab](../../docs/decisions/ADR-019-conclave-profile-lab.md)

## Unsigned development

Run `bash scripts/run-profile-lab-development.sh` from the repository root for
hot-reload development against loopback Cloud (default `http://localhost:8787`).
Browser sign-in remains required; the active `vitalii@nohainc.com` account is
the explicitly configured internal Lab owner. Development supports the full
Candidate → Test → Validate → Publish lifecycle. Start
`bash scripts/run-workspace-development.sh` to consume signed Cloud Profiles in
a separate non-release Workspace. Both launchers use public roots generated by
`node scripts/setup-development-profile-signing.mjs`; its private key stays in
ignored local Wrangler configuration.

For the currently provisioned hosted development environment, set
`CONCLAVE_DEVELOPMENT_CLOUD_URL=https://app.conclaveax.com` on both launchers.
They read the public `.development/hosted-profile-trust.json` file. Hosted signing
setup uses `node scripts/setup-development-profile-signing.mjs --hosted` and a
separate ignored secret file for Wrangler upload. Customer builds must use
independent production roots. Explicit `CONCLAVE_DEVELOPMENT_PROFILE_DIRECTORY`
still enables unsigned local candidate execution only against loopback Cloud.

The macOS build script defaults to skipping Developer ID signing and notarization;
use `--unsigned` explicitly when packaging development builds. See the
[development contract](../../docs/specifications/PROFILE_LAB.md#development-access-and-unsigned-execution).

## Operator workflow and acceptance

Use **Workers**, **Issues**, and **Activity**. Selecting a Worker opens its Profile candidate directly in the editor; there is no separate Overview or Draft & Test screen. The compact toolbar keeps the stable actions **Save**, **Validate**, **Run tests**, and **Publish**. Test results open in a collapsible bottom panel, history is available as a secondary view, and **Focus editor** hides auxiliary UI for large JSON files.

The normal workflow is **Edit → Save → Validate → Run tests → Publish**. The Test panel includes a deterministic Event Mapping Replay view; JSONL Profiles with declared mappings must pass it before publication evidence is accepted. Local recovery snapshots never publish automatically. Every validation and test result is bound to the exact candidate digest, so changing the JSON makes the candidate require validation and testing again. Cloud checks authorization, evidence freshness, expected revision, candidate digest, and trusted signing before atomically publishing the next current Profile revision. History can restore an older snapshot only as a new current revision.

V9 has no testing, beta, stable, draft-release, promotion, or channel-selection UI. Installed CLI compatibility, readiness, revision, and current Profile status are shown as operational Worker information. The editor preserves its buffer, cursor, scroll position, and unsaved state while the Worker sidebar, test panel, and inspector are resized or toggled.

Run `flutter test test/worker_first_run_acceptance_test.dart` for the complete ChatGPT/Gemini first-run flows and the no-template fallback. These widget tests use the real local store, controller, and bundled generic Engine with isolated temporary provider executables and controlled browser/Cloud boundaries. No vendor credentials or live-provider calls are required; live signing and Workspace admission must still satisfy the V9 contract. Existing local candidate/evidence data remains digest-bound.
