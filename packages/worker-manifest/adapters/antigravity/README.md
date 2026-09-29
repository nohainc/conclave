# First-party Antigravity adapter

This adapter implements the same V7 Local Adapter Protocol as the Codex
adapter. For each assignment it starts a fresh `agy` process in the Host's
Workstream CWD and uses Antigravity's `stream-json` input and output formats.
It sends one user event on stdin, translates `init`, `step_update`, and `result`
events, and closes stdin after the assignment so the CLI exits after its
terminal result.

The adapter keeps Antigravity's configured permission policy in force. It
enables the CLI's sandbox flag and never passes
`--dangerously-skip-permissions`. Tool events become generic progress; raw
tool output, provider diagnostics, and stderr are not sent over the adapter
protocol. The CLI child receives only basic runtime variables (PATH, home,
temporary directory, locale, and optional TLS certificate paths), not arbitrary
Workspace variables or injected provider credentials.

Execution errors use the provider-independent taxonomy:
`worker_not_ready`, `cli_not_found`, `authentication_required`,
`unsupported_cli_version`, `model_not_supported`, `permission_denied`,
`quota_exhausted`, `provider_unavailable`, `timeout`, `cancelled`,
`internal_adapter_error`, and `execution_failed`. Local permission setup issues
use `permission_configuration_required` only in readiness diagnostics.
Workspace owns the assignment deadline and process-tree cancellation.

Run fake CLI tests without a live Antigravity account or model request:

```sh
node --test packages/worker-manifest/adapters/antigravity/test/antigravity-adapter.node.mjs
```

An opt-in test sends one tiny request through the locally authenticated `agy`
CLI and may consume provider usage. Run it explicitly with
`CONCLAVE_TEST_REAL_AGY=1`; set `CONCLAVE_TEST_AGY_PATH` when `agy` is not on
PATH:

```sh
CONCLAVE_TEST_REAL_AGY=1 node --test packages/worker-manifest/adapters/antigravity/test/antigravity-adapter.node.mjs
```
