# Conclave AX Agent on macOS

The first distributable Agent target is a signed macOS app bundle containing the Flutter Agent App. The Dart Agent Engine remains a separate background process and is installed beside the app, so UI shutdown cannot stop active assignments.

## Local package flow

1. Build the Agent App with `flutter build macos --release`.
2. Build the Engine with `dart compile exe apps/agent_engine/bin/conclave_agent_engine.dart`.
3. Place the Engine in the app's support directory and register the launch-at-login helper.
4. Sign the app and helper with the release identity.
5. Notarize the signed archive before distribution.

The release manifest must include the Agent version, platform, architecture, protocol version, SHA-256 digest, and signature. Updates are staged and health-checked by the Engine before activation.

Signing and notarization identities are intentionally supplied by CI secrets; they are never stored in this repository.
