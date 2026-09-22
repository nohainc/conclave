# Agent Engine platform boundary

The Dart Agent Engine keeps operating-system behavior behind a small runtime
boundary. Protocol handling, repository safety, plugin management, and Cloud
coordination must not branch on the host OS.

`PlatformRuntime` currently owns:

- the user home directory used for the default Agent data directory;
- private file and directory permissions (`chmod` on POSIX, profile ACLs on
  Windows);
- shutdown signal subscriptions;
- isolated process startup and process-tree termination.

`PosixRuntime` uses `setsid` plus process-group signalling when available.
`WindowsRuntime` uses the native process handle and `taskkill /T`, with a
direct-handle fallback. Both implementations retain bounded timeouts and a
safe fallback when an operating-system helper is unavailable.

Credential command selection is a separate `SecureCredentialBackend`: macOS
uses Keychain, Linux uses Secret Service, and unsupported platforms fail
closed. Credentials are never written to the Agent configuration files.

The three-OS CI matrix remains the compatibility gate. New platform-specific
behavior belongs in these adapters only when the behavior is genuinely
different; ordinary protocol and worker code stays platform-neutral.
