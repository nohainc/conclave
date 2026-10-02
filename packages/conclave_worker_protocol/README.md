# Conclave Worker Protocol

Canonical Dart models and validators for the Local Worker Protocol 4.0 wire
contract shared by Workspace and the standalone CLI Worker Engine.

Frames use one JSON object per line. The package validates initialize, probe,
execute, progress, result, and error frames, including bounded fields and strict
field allowlists. Provider credentials, provider session IDs, arbitrary
executable paths, and arbitrary working directories are not part of the
protocol. Provider tool paths may appear in probe results for local diagnostics
and must be excluded from Cloud inventory. This package has no Flutter
dependency.

Execute requests may carry the bounded `executionPolicy` values `restricted`
and `provider_default`. The field defaults to `restricted` for older senders;
`full_access` is not representable in the protocol.

This is the sole Dart package for the Local Worker Protocol in the current
runtime. Older JSON-RPC Worker protocol models have been removed.
