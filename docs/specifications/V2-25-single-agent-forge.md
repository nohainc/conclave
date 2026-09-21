# V2-25 — Single-Agent Forge acceptance path

The first real Forge acceptance path uses one connected Agent and three configured local workers on that Agent: a research/lead worker, an implementation worker, and an independent review worker. They may use different local plugins, but the cloud must not call OpenAI, Anthropic, or another model API directly for this mode.

## Lifecycle

```text
Chat message
  → Goal and completion criteria
  → Forge Run
  → local research worker
  → local planning worker
  → local Codex implementation worker
  → local review worker
  → local test command through the Runtime
  → Core verification and completion
  → persisted result in Chat
```

The cloud assembles bounded context from persisted artifacts and sends structured worker requests through the Local Runtime/Agent channel. Repository changes and test output return as runtime evidence and artifacts; no manual copying occurs between workers.

## Core acceptance rules

- `executionMode` defaults to `single_agent`.
- The selected lead, implementation, and review workers must all use `local_agent` connections.
- All three workers must resolve to the same connected Agent.
- A provider API worker is allowed only through an explicit `cloud_api` execution mode, never as a fallback for single-agent Forge.
- The review worker remains a distinct worker resource even though it shares the same Agent host.
- Completion requires the existing criteria gate, independent review, real runtime test evidence, and a persisted completion artifact.
