# CLI process primitives and v2 migration runtime

The package shares provider-neutral CLI process primitives: executable lookup,
environment construction, bounded command output, structured diagnostics,
cleanup, deadlines, and session-state storage.

`WorkerRuntime` and its Protocol 3.0 identity model are migration-only v2
implementation code. The v8 executable is [the generic CLI Worker Engine](../../engines/cli_worker/README.md);
new Engine behavior must not be added to the v2 loop.
