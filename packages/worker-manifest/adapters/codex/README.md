# First-party Codex adapter

This adapter speaks the V7 newline-delimited JSON protocol and delegates each
assignment to the locally installed Codex CLI. It uses `codex exec --json
--ephemeral` with the Host-resolved Workstream CWD, the locally allowed model,
and Codex's `workspace-write` sandbox with approvals disabled for headless
execution. It verifies local sign-in through `codex login status`; no provider
token is copied into the adapter environment or Cloud. The adapter filters the
CLI child environment to basic runtime values (PATH, home, temp, locale, and
optional TLS certificate paths), so arbitrary Workspace variables and provider
API keys are not forwarded. Codex continues to use its own local sign-in state.

Each assignment starts a fresh Codex process in the Workstream directory. JSON
events are translated to safe generic progress and a text result; tool output,
stderr, and raw provider diagnostics are not sent over the adapter protocol.
Failures use the provider-independent taxonomy: `worker_not_ready`,
`cli_not_found`, `authentication_required`, `unsupported_cli_version`,
`model_not_supported`, `permission_denied`, `quota_exhausted`,
`provider_unavailable`, `timeout`, `cancelled`, `internal_adapter_error`, and
`execution_failed`.
Workspace owns the assignment deadline and terminates the entire process tree
when it expires or is cancelled.

The adapter requires Node.js and the Codex CLI on the Workspace command path.
The package manifest template intentionally leaves digest and signature for the
release publisher to fill after packaging. macOS and Linux packages are
supported by this launcher; Windows packaging still needs a native launcher.

Run isolated protocol tests without a live Codex account or model request:

```sh
node --test packages/worker-manifest/adapters/codex/test/codex-adapter.node.mjs
```

An opt-in test sends one tiny request through the locally signed-in Codex CLI
and may consume provider usage. Run it explicitly with
`CONCLAVE_TEST_REAL_CODEX=1`; set `CONCLAVE_TEST_CODEX_PATH` when Codex is not
available on PATH:

```sh
CONCLAVE_TEST_REAL_CODEX=1 node --test packages/worker-manifest/adapters/codex/test/codex-adapter.node.mjs
```
