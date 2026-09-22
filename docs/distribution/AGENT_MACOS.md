# Conclave AX Agent on macOS

The first distributable Agent target is a signed macOS app bundle containing the Flutter Agent App. The Dart Agent Engine remains a separate background process and is installed beside the app, so UI shutdown cannot stop active assignments.

## Local package flow

1. Build the Agent App with `flutter build macos --release`.
2. Build the Engine with `dart compile exe apps/agent_engine/bin/conclave_agent_engine.dart`.
3. Place the Engine in the app's support directory and register the launch-at-login helper.
4. Sign the app and helper with the release identity.
5. Notarize the signed archive before distribution.

## Install and remove a local build

After `scripts/build-agent-macos.sh` completes, install the generated bundle
and Engine with:

```sh
scripts/install-agent-macos.sh \
  --app-bundle apps/agent_app/build/macos/Build/Products/Release/conclave_agent_app.app \
  --engine apps/agent_app/build/macos/Build/Products/Release/conclave_agent_engine
```

The installer places the App in `~/Applications`, installs the Engine under
`~/Library/Application Support/Conclave AX`, and registers a per-user
`launchd` service that restarts it after login or an unexpected exit. It does
not store enrollment tokens or other credentials. Remove the local install
with `scripts/uninstall-agent-macos.sh --confirm`.

This development flow does not sign or notarize binaries. Release CI must sign
the App, Engine, and launch helper before distributing them.

Release packaging must fail closed when signing is unavailable:

```sh
CONCLAVE_REQUIRE_SIGNATURE=1 \
CONCLAVE_CODESIGN_IDENTITY="Developer ID Application: Example" \
scripts/package-agent-macos.sh \
  --app-bundle apps/agent_app/build/macos/Build/Products/Release/conclave_agent_app.app \
  --engine apps/agent_app/build/macos/Build/Products/Release/conclave_agent_engine \
  --output dist/conclave-agent-macos.zip
```

The archive includes `release.json` with `signed: true` and the Engine SHA-256
digest. Notarization remains a release-CI step after signing.

The release manifest must include the Agent version, platform, architecture, protocol version, SHA-256 digest, and signature. Updates are staged and health-checked by the Engine before activation.

Signing and notarization identities are intentionally supplied by CI secrets; they are never stored in this repository.
