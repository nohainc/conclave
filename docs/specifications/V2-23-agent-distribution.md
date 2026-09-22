# V2-23 — Real Agent distribution

> **Historical V2 specification.** The current normative host/distribution
> architecture is [Architecture v3](../architecture/ARCHITECTURE_V3.md) and
> [ADR-003](../decisions/ADR-003-flutter-dart-agent.md).

## Decision

macOS is distributed as a signed and notarized Apple installer package (`.pkg`). The package installs a versioned agent payload and a small stable launcher. A per-user `launchd` LaunchAgent starts the service, so the agent can use the signed-in user's Keychain and repository permissions without opening an inbound port.

The JavaScript runtime is deliberately an input to the package build (`CONCLAVE_AGENT_EXECUTABLE`), not an architectural dependency. Node single-executable applications remain an option, but the current Node documentation describes that feature as active development; choosing it now would couple distribution to an unstable runtime packaging contract.

## macOS lifecycle

1. Installer places the release payload and launcher.
2. `conclave-agent enroll --token ...` stores the returned agent credential in the macOS Keychain under service `com.conclaveax.agent`; the JSON configuration stores identity and paths only.
3. `conclave-agent install` writes `~/Library/LaunchAgents/com.conclaveax.agent.plist` and bootstraps it for the current user.
4. The service writes structured logs under the configured agent log directory and keeps the existing signed, digest-checked, rollback-capable updater.
5. `conclave-agent uninstall` stops and removes the LaunchAgent but preserves data by default. A separate purge operation may remove local state after explicit confirmation.

## Security boundaries

- No credential is embedded in Flutter Web, the plist, or the installer metadata.
- Enrollment tokens are command-line inputs only and are never persisted by the installer.
- Logs redact bearer tokens, API keys, and secret-shaped fields.
- The service is user-scoped; system-wide installation is deferred until a system daemon is required.
- Release CI must use Developer ID signing, Hardened Runtime where applicable, notarization, and stapling before publishing a package.

## Future platforms

The service and credential interfaces are platform-neutral. Windows will add a per-user service/task plus Credential Manager; Linux will add a user systemd unit plus a desktop-secret-store integration. Neither platform should alter Forge or worker execution contracts.
