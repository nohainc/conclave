# First-party V7 adapters

The Codex adapter delegates to the local Codex CLI and uses its local account
session. OpenAI API, Gemini API, and Anthropic API adapters use separate
provider implementations over the shared V7 JSONL runtime. Their API keys are
read from the Host-injected `CONCLAVE_PROVIDER_API_KEY` process environment and
remain in the Workspace secure credential store.

API adapters provide text generation only. They do not receive Workstream file
or shell permissions. Their manifests request provider-specific network
permissions. Optional custom endpoints must use HTTPS; HTTP is permitted only
for loopback development endpoints. Provider error bodies and credentials are
never copied to Worker results or logs. API-key validation uses each provider's
model-list endpoint before text generation; it does not generate billable
content.

Package an API adapter from the repository root, for example:

```sh
CONCLAVE_WORKER_TRUST_SECRET="$V7_ADAPTER_PUBLISHER_KEY" \
  pnpm host:package-adapter \
  --source ../../packages/worker-manifest/adapters/openai-api \
  --output ../../dist/openai-api-1.0.0.tgz
```

The packager includes the shared runtime from `adapters/shared`, signs the
complete package digest and manifest, and emits a release manifest next to the
archive. Publishing still requires an authenticated owner session.

Run isolated adapter tests without provider credentials or billable requests:

```sh
pnpm worker-adapters:test
```
