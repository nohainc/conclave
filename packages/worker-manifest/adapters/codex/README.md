# First-party Codex adapter

This adapter speaks the V7 newline-delimited JSON protocol and delegates each
assignment to the locally installed Codex CLI. It uses `codex exec --json
--ephemeral` with the Host-resolved Workstream CWD, the locally allowed model,
and Codex's `workspace-write` sandbox with approvals disabled for headless
execution. It verifies local sign-in through `codex login status`; no provider
token is copied into the adapter environment or Cloud.

The adapter requires Node.js and the Codex CLI on the Workspace command path.
The package manifest template intentionally leaves digest and signature for the
release publisher to fill after packaging. macOS and Linux packages are
supported by this launcher; Windows packaging still needs a native launcher.

Run isolated protocol tests without a live Codex account or model request:

```sh
node --test packages/worker-manifest/adapters/codex/test/codex-adapter.node.mjs
```
