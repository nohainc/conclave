# Conclave AX Agent

The macOS Agent consists of the Flutter host-management app and the local
Dart Agent Engine. The app owns local setup and status; Cloud orchestration
stays in Studio.

## Build and package macOS

From the repository root:

```sh
scripts/build-agent-macos.sh
scripts/package-agent-macos.sh \
  --app-bundle apps/agent_app/build/macos/Build/Products/Release/conclave_agent_app.app \
  --engine apps/agent_app/build/macos/Build/Products/Release/conclave_agent_engine \
  --output dist/conclave-agent-macos.zip \
  --version 0.1.0
```

For a release build, provide `--signing-identity` (or
`CONCLAVE_CODESIGN_IDENTITY`) and notarize the resulting signed app through
the release pipeline. Local unsigned packages are intended for development.

The resulting archive contains a self-contained installer under `scripts/`.
After extracting it, run `Conclave AX Agent/scripts/install-agent-macos.sh`
without path arguments. Re-running the installer performs an upgrade, and the
bundled uninstaller preserves local data unless `--purge` is supplied.
