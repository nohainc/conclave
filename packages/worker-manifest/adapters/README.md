# First-party V7 adapters

The Codex and Claude Code adapters delegate to their local CLIs and use their local account
session. OpenAI API, Gemini API, and Anthropic API adapters use separate
provider implementations over the shared V7 JSONL runtime. Their API keys are
read from the Host-injected `CONCLAVE_PROVIDER_API_KEY` process environment and
remain in the Workspace secure credential store.

The Ollama adapter talks to the configured local Ollama service, checks its
version and installed model list, and does not receive provider credentials.
Claude Code requires a supported CLI and Node.js version, validates the local
session, and launches headless execution in the Workstream working directory.

API adapters provide text generation only. They do not receive Workstream file
or shell permissions. Their manifests request provider-specific network
permissions. Optional custom endpoints must use HTTPS; HTTP is permitted only
for loopback development endpoints. Provider error bodies and credentials are
never copied to Worker results or logs. API-key validation uses each provider's
model-list endpoint before text generation; it does not generate billable
content.

Package an API adapter from the repository root, for example:

```sh
CONCLAVE_WORKER_TRUST_PUBLISHER=conclave \
CONCLAVE_RELEASE_SIGNING_SEED="$V7_ADAPTER_RELEASE_SEED" \
CONCLAVE_RELEASE_SIGNING_KEY_ID="$V7_ADAPTER_RELEASE_KEY_ID" \
  pnpm host:package-adapter \
  --source ../../packages/worker-manifest/adapters/openai-api \
  --output ../../dist/openai-api-1.0.0.tgz
```

The packager includes the shared runtime from `adapters/shared`, signs the
complete package digest and manifest using the release Ed25519 key, and emits
a release manifest next to the archive. Keep the signing seed in release
infrastructure only. Publishing still requires the configured release path.
The Codex and Antigravity CLI packages include the same shared CLI process
runtime from that directory in their signed archives. It also provides a
package-scoped local session store for providers that opt into durable session
reuse; provider session identifiers stay in that local package store.

Workspace gives each configured Worker Package a private state directory at
`Workspace/Workers/<worker-id>/state`, passed as `CONCLAVE_WORKER_STATE_DIR`.
Packages may keep local session mappings and non-secret tool metadata there.
The path is generic runtime metadata, not a provider-specific environment
setting. Workspace does not read or interpret files written inside it. The
shared CLI runtime stores package-local session mappings beneath this directory.

Execution is process-per-assignment: a resident Workspace starts one fresh
Worker Package process, which starts one fresh provider CLI process. Durable
session IDs let the next assignment resume provider context across those fresh
processes. Long-running Worker or provider daemons are deferred until the
first-party Codex and Gemini Workers are proven stable.

Run isolated adapter tests without provider credentials or billable requests:

```sh
pnpm worker-adapters:test
```

The shared Local Worker Protocol contract suite launches the same fake-CLI
scenarios against both the ChatGPT/Codex and Gemini/Antigravity packages. It
covers initialization, passive and live probes, execution frames, progress and
results, safe error mapping, deadlines, package cancellation and process-tree
cleanup, durable session resumption across fresh package processes, malformed
provider output, and manifest-scoped environment forwarding.
