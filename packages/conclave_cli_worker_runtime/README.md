# Conclave CLI Worker Runtime

Provider-neutral Dart support for Worker executables. The package starts with
generic executable lookup, environment construction, bounded command output,
session-state storage, structured diagnostics/logging, cleanup primitives, and
the Local Worker Protocol 3.0 console loop.

Provider command lines, authentication interpretation, and output parsing
belong in individual Worker packages.
