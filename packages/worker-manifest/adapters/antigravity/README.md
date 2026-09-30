# First-party Antigravity adapter

This Worker Package implements V7 Local Worker Protocol. For each assignment
it starts a fresh `agy` process in the Workstream CWD and uses the CLI's
`stream-json` input and output formats. It sends one user event on stdin,
translates `init`, `step_update`, and terminal `result` events, and closes stdin
after the assignment so the CLI exits after its result.
Process management uses the shared `lib/cli_tool_runner.mjs` packaged with this
adapter, including bounded output, timeout, cancellation, and process-tree
cleanup. Antigravity-specific arguments and stream event interpretation stay
here.

The package keeps the CLI's configured permission policy in force. It enables
the CLI's sandbox flag and never passes
`--dangerously-skip-permissions`. Tool events become generic progress; raw
tool output, provider diagnostics, and stderr are not sent over the Local
Worker Protocol. The CLI child receives only variables in the signed package
environment policy, not the Workspace's full parent environment. The CLI
continues to use its cached operating-system keyring credentials and its own
settings; the package does not read or recreate provider authentication state.

For API-key mode, Antigravity requires `modelProvider: "gemini"` in
`~/.gemini/antigravity-cli/settings.json` and `GEMINI_API_KEY` in the CLI
environment; forwarding the key alone does not enable this mode. The package
does not change the user's CLI settings. `GOOGLE_GEMINI_BASE_URL` is forwarded
for the CLI's documented custom Gemini endpoint. ADC is enabled only when
`AGY_ADC_AUTH=true`; standard ADC lookup and the CLI-supported
`GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_CLOUD_LOCATION`, and
`GOOGLE_CLOUD_QUOTA_PROJECT` settings remain with the CLI. Unsupported aliases
such as `GOOGLE_API_KEY` are not forwarded as auth configuration.

The package resolves `agy` from its package-scoped cached path, PATH, and known
install locations, then reports its version and resolved executable path
through `probe.result`. Workspace displays this package-reported metadata only
in local Advanced Diagnostics. Sensitive values are redacted from Worker
output.

Execution is stateless by default. With Local Worker Protocol 2.5,
`sessionPolicy: "durable_session"` plus an opaque `sessionKey` opts into
conversation continuity. The package stores Antigravity's conversation ID in
its private local session store, resumes it with the CLI's `--conversation`
option, and verifies the resumed ID from the `init`/`result` events. The ID
never leaves the package; Cloud and Workspace only route the Conclave policy
and key. Callers should reuse a key only for the logical Conclave conversation
they intend to continue.

Execution errors use the provider-independent taxonomy:
`worker_not_ready`, `cli_not_found`, `authentication_required`,
`unsupported_cli_version`, `model_not_supported`, `permission_denied`,
`quota_exhausted`, `provider_unavailable`, `timeout`, `cancelled`,
`internal_adapter_error`, and `execution_failed`. Local permission setup issues
use `permission_configuration_required` only in readiness diagnostics.
Workspace owns the assignment deadline and process-tree cancellation; the
shared CLI runner also applies a bounded execution deadline and cleans up the
process tree on cancellation or failure.

Run fake CLI tests without a live Antigravity account or model request:

```sh
node --test packages/worker-manifest/adapters/antigravity/test/antigravity-adapter.node.mjs
```

An opt-in test sends one tiny request through the locally authenticated `agy`
CLI and may consume provider usage. Run it explicitly with
`CONCLAVE_TEST_REAL_AGY=1`; add the `agy` install directory to PATH if needed:

```sh
CONCLAVE_TEST_REAL_AGY=1 node --test packages/worker-manifest/adapters/antigravity/test/antigravity-adapter.node.mjs
```
