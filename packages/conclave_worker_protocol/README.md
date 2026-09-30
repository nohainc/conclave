# Conclave Worker Protocol

Canonical Dart models and validators for the Local Worker Protocol 3.0 wire
contract shared by Workspace and standalone Worker executables.

Frames use one JSON object per line. The package validates initialize, probe,
execute, progress, result, and error frames, including bounded fields and strict
field allowlists. Provider credentials, provider session IDs, arbitrary
executable paths, and arbitrary working directories are not part of the
protocol. Provider tool paths may appear in probe results for local diagnostics
and must be excluded from Cloud inventory. This package has no Flutter
dependency.

The older package at `packages/dart/worker_protocol` models a separate legacy
JSON-RPC contract and must not be used for Local Worker Protocol 3.0 frames.
