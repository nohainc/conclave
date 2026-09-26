# Conclave Workspace

Conclave Workspace is the machine-side execution and security runtime.

It maintains the Cloud connection, owns the local Work Root, creates/resolves
Workstream working directories, manages locally configured Workers and their
credentials, installs/verifies Worker Type adapter packages, launches adapter
child processes, enforces local permissions, supervises execution, and reports
safe readiness/status back to Conclave Cloud.

Its GUI is intentionally minimal and local-first:
- pairing/connection;
- Workers;
- provider authentication;
- local permissions;
- current local work;
- diagnostics/logs;
- updates;
- pause/quit.

Projects, Workstreams, Discuss, Work orchestration, Project membership and
remote scheduling policy belong in Conclave AX.

Users install only Conclave Workspace. Worker adapters are managed internally;
they are not separately installed desktop applications.

## Packaging a V7 adapter release

Use the release publisher's signing key from a protected environment. The
packager validates the V7 manifest, computes the file-tree digest, signs the
digest and canonical manifest, and emits a gzip-tar archive plus the exact
manifest for the Cloud catalog request. The key is read only from the process
environment and is not written into either output.

```sh
cd apps/host
CONCLAVE_WORKER_TRUST_SECRET="$V7_ADAPTER_PUBLISHER_KEY" \
  dart run bin/package_v7_adapter.dart \
  --source ../../packages/worker-manifest/adapters/codex \
  --output ../../dist/codex-1.0.0.tgz
```

The archive must remain under Cloud's 20 MiB release-upload limit. Publish its
manifest and base64 archive to `POST /api/v7/adapters/publish` using an
authenticated owner session. Cloud stores the immutable catalog entry and
archive; Workspace verifies the release locally before use.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.


## Desktop development and macOS build

Conclave Workspace is the native desktop product. The Flutter GUI and the
headless entrypoint share the same runtime composition in
`lib/workspace_runtime.dart`.

Build a macOS release package from repository root:

~~~text
bash scripts/build-workspace-macos.sh
~~~

Optional release environment:
- `CONCLAVE_MACOS_SIGN_IDENTITY` — Developer ID Application identity;
- `CONCLAVE_MACOS_NOTARY_PROFILE` — `notarytool` keychain profile;
- `CONCLAVE_WORKSPACE_VERSION` — override build version.

The output ZIP is written under `dist/conclave-workspace/macos`.

## Pairing

In Conclave AX web:
1. create/open a Workspace;
2. choose **Connect machine**;
3. copy the one-time code.

In Conclave Workspace desktop:
1. choose **Start pairing**;
2. paste the code;
3. keep the production Cloud URL unless using local/staging;
4. pair.

The one-time code is exchanged for a Workspace Runtime ID and bearer token.
The token is stored only in the platform secure credential store.

To verify a real Cloud connection with a disposable Workspace:

~~~text
CONCLAVE_ENROLLMENT_TOKEN='conclave_enroll_...' \
  bash scripts/test-workspace-cloud-connection.sh
~~~

## Worker naming

- **Codex** Worker Type invokes Codex CLI; authentication may be a ChatGPT account.
- **Antigravity** Worker Type invokes the `agy` CLI; authentication may be a Google account.
- **OpenAI API**, **Gemini API**, and **Anthropic API** are direct API Worker Types.

Worker Type names describe the integration Conclave invokes, not the model or
subscription brand.
