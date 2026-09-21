# Worker Execution and Connection Model

**Status:** Proposed architecture  
**Scope:** Conclave AX Core, Cloud, Local Runtime, Forge, SDK

## 1. Principle

A Conclave AX **Worker** describes who/what can perform work. A **Connection** describes how Conclave reaches that Worker.

These concepts must remain separate.

A worker may be:
- an online model accessed through a provider API;
- a locally installed AI agent such as Codex or Claude Code;
- a remote/self-hosted agent;
- a local model;
- a CI/tool worker;
- a human/manual worker.

Core must not assume that intelligence is billed through an API.

## 2. Worker resource

A Worker resource describes stable orchestration attributes:

- worker id and display name;
- kind: `model`, `agent`, `tool`, `ci`, `human`;
- supported Roles;
- Capabilities;
- connection id;
- trust level and independence group;
- provider/model family where known;
- execution location;
- concurrency limits;
- availability/health;
- cost/billing metadata;
- permissions;
- version.

Worker identity is distinct from a model name. Multiple Workers may use the same underlying model with different roles, connections, permissions, contexts, or billing modes.

Example:

```text
Worker: codex-implementer
kind: agent
roles: Implementer, Researcher
capabilities: repository_read, repository_write, shell, tests
connection: local-codex
executionLocation: local
billingMode: subscription
independenceGroup: openai-codex-local
```

## 3. Connection resource

A Connection describes the transport and authentication boundary.

Required transport types:

### provider_api
Direct cloud API call.

Examples:
- OpenAI API
- Anthropic API
- Gemini API

Typical billing: metered API usage.

### local_agent
An officially supported local CLI/agent/SDK invoked through Conclave AX Local Runtime.

Examples:
- Codex CLI
- Claude Code
- future agent CLIs

Typical billing: subscription allowance or provider API depending on how the local agent is authenticated.

### remote_agent
A remote/self-hosted agent service that implements a Conclave-compatible adapter.

### local_model
A locally hosted model endpoint/runtime.

### manual
A human-assisted bridge for a model/application without supported automation. Conclave renders the task and validates the imported result, but does not automate consumer web UI.

Browser automation against consumer AI websites is not a supported primary transport.

## 4. Authentication and billing

Connection authentication modes may include:

- `api_key`;
- `subscription_session`;
- `oauth`;
- `service_identity`;
- `local_session`;
- `none`;
- `manual`.

Secrets never appear in ordinary Worker, Task, Event, Artifact, or protocol payloads.

Billing modes:

- `api_metered`;
- `subscription`;
- `local_compute`;
- `external`;
- `manual`.

Subscription-backed execution is not treated as literally free. Conclave records it as a different cost source with quota/availability constraints rather than API token cost.

## 5. Unified execution contract

Every automated Worker transport implements the same high-level contract:

```text
WorkerExecutionRequest
  -> adapter/transport
  -> Worker execution
  -> structured WorkerExecutionResult
```

The transport is responsible for:
- session creation/reuse;
- converting Conclave protocol/context into the provider/agent format;
- executing the worker;
- collecting structured result, logs, usage, timing, and errors;
- enforcing cancellation/timeouts;
- returning evidence/provenance.

Core remains responsible for:
- selecting the Worker;
- validating the result;
- accepting/rejecting state transitions;
- retry/rerouting;
- persistence and audit.

## 6. Local subscription-backed agents

Local Runtime is the trusted bridge for subscription-backed agents.

```text
Conclave AX Cloud
       |
       | authenticated outbound session
       v
Conclave AX Local Runtime
       |
       +-- Codex adapter -> installed Codex CLI -> local subscription/session
       +-- Claude adapter -> Claude Code -> local subscription/session
       +-- future adapters
       |
       +-- repository / Git / shell / tests
```

Cloud must not copy or request browser/session credentials from the user's machine.

The Local Runtime reports:
- adapter identity/version;
- worker availability;
- supported capabilities;
- active session state without exposing credentials;
- quota/rate-limit signals where available;
- execution evidence;
- usage/cost metadata when available.

## 7. Session isolation

A Worker execution may request:
- a new isolated session;
- reuse of an existing task session;
- a persistent project session where explicitly allowed.

Independent research/review must use isolated session/context unless policy explicitly allows reuse.

Separate chats/sessions using the same underlying model can provide context independence but do not count as provider independence.

## 8. Fallback routing

A Worker policy may define ordered fallbacks.

Example:

```text
Implementation:
1. local Codex subscription
2. local Claude Code subscription
3. OpenAI API worker
```

Fallback occurs only for defined failure classes such as:
- worker unavailable;
- local runtime offline;
- quota/rate limit reached;
- execution timeout;
- capability mismatch.

A content/verification failure is not silently converted into a provider fallback unless policy allows a retry or alternate worker.

## 9. Initial implementation priority

The first production transports should be:

1. existing provider API adapter(s);
2. Local Runtime transport;
3. Codex local-agent adapter;
4. Claude Code local-agent adapter;
5. remote agent transport;
6. manual transport.

Additional provider APIs should not take priority over completing the local-agent path.
