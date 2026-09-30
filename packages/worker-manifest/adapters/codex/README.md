# First-party Codex adapter

This adapter speaks the V7 newline-delimited JSON protocol and delegates each
assignment to the locally installed Codex CLI. Stateless assignments use
`codex exec --json --ephemeral`; durable assignments use a reusable Codex
thread. Both use the Host-resolved Workstream CWD, the locally allowed model,
and Codex's `workspace-write` sandbox with approvals disabled for headless
execution. It verifies local sign-in through `codex login status`; no provider
token is copied into Cloud. The adapter filters the CLI child environment using
the signed package environment policy. Codex continues to use its local
sign-in state; only its declared configuration overrides are forwarded.

Each assignment starts a fresh Codex process in the Workstream directory. The
process may resume a package-local thread only when the caller supplies a
`sessionKey`. JSON events are translated to safe generic progress and a text
result; tool output, stderr, and raw provider diagnostics are not sent over the
adapter protocol.
Process management uses the shared `lib/cli_tool_runner.mjs` packaged with this
adapter, including bounded output, timeout, cancellation, and process-tree
cleanup. Codex-specific command arguments, event interpretation, and error
classification stay here.

Stateless execution remains the default and uses Codex's ephemeral mode. A
protocol 2.5 caller opts into continuity with `sessionPolicy: "durable_session"`
and an opaque `sessionKey`. The package stores the associated Codex thread ID in
its private local session store, resumes it on later assignments, and verifies
that Codex returned the requested thread ID. Callers should reuse a key only
for the logical Conclave conversation they intend to continue. Provider thread
IDs never leave the package; Cloud and Workspace only route the generic policy
and key.
Failures use the provider-independent taxonomy: `worker_not_ready`,
`cli_not_found`, `authentication_required`, `unsupported_cli_version`,
`model_not_supported`, `permission_denied`, `quota_exhausted`,
`provider_unavailable`, `timeout`, `cancelled`, `internal_adapter_error`, and
`execution_failed`.
Workspace owns the assignment deadline and terminates the entire process tree
when it expires or is cancelled; the shared CLI runner also applies a bounded
execution deadline and cleans up the process tree on cancellation or failure.

The adapter requires Node.js and resolves `codex` from its package-scoped
cached path, PATH, and known user install directories. Its readiness probe
reports the detected version and resolved executable path through
`probe.result`; Workspace displays this package-reported metadata only in local
Advanced Diagnostics.
The package manifest template intentionally leaves digest and signature for the
release publisher to fill after packaging. macOS and Linux packages are
supported by this launcher; Windows packaging still needs a native launcher.

Run isolated protocol tests without a live Codex account or model request:

```sh
node --test packages/worker-manifest/adapters/codex/test/codex-adapter.node.mjs
```

An opt-in test sends one tiny request through the locally signed-in Codex CLI
and may consume provider usage. Run it explicitly with
`CONCLAVE_TEST_REAL_CODEX=1`; add the Codex install directory to PATH if
needed:

```sh
CONCLAVE_TEST_REAL_CODEX=1 node --test packages/worker-manifest/adapters/codex/test/codex-adapter.node.mjs
```
