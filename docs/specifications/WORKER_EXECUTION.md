# Worker Execution and Connection Model

**Status:** Proposed architecture  
**Scope:** Conclave AX Core, Cloud, Local Runtime, Forge, SDK

## 1. Principle

A Conclave AX **Worker** describes who/what can perform work. A **Connection** describes how Conclave reaches that Worker.

These concepts must remain separate.

A worker may be:
- an online model accessed through a provider API;
- an interactive web/cloud AI using a Conclave app/connector;
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
- trust level and independence group;
- availability/health;
- permissions;
- connection bindings.

Worker identity contains no provider, transport, authentication, billing, model endpoint, or execution-environment fields. It describes the participant and its orchestration abilities. Multiple Workers may use the same underlying model, and one Worker may have multiple eligible Connections.

Example:

```text
Worker: codex-implementer
kind: agent
roles: Implementer, Researcher
capabilities: repository_read, repository_write, shell, tests
connections: local-codex
independenceGroup: openai-codex-local
```

### 2.1 Worker–Connection binding

The `worker_connections` relation associates a Worker with one or more Connections and may mark one as the default. It is a routing relationship, not part of Worker identity. Core resolves a `WorkerRequirement` to a `WorkerBinding` containing the selected Worker and Connection.

The binding is selected using capability, role, permission, connection availability, execution environment, and connection cost policy. The selected connection is persisted on the Attempt/ModelCall snapshot so a later retry or audit does not silently change transport.

## 3. Connection resource

A Connection describes the transport, authentication, billing, and execution boundary. It is independently configurable, replaceable, health-checked, and tenant-scoped.

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

### web_app
A subscription-backed AI running in its normal web/cloud chat surface and connected to Conclave through an official app/plugin/connector/MCP or other supported tool integration.

The web AI keeps its native conversation, while Conclave keeps the authoritative WorkerSession, Task, Attempt, mailbox, Artifacts, and result state. Baseline continuation is pull-based through Conclave tools; true server push is used only when the provider officially supports it.

See [WEB_APP_WORKERS.md](WEB_APP_WORKERS.md).

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

Authentication belongs only to Connection configuration. Secrets never appear in ordinary Worker, Task, Event, Artifact, or protocol payloads. A Worker cannot grant or select credentials by itself.

Billing modes:

- `api_metered`;
- `subscription`;
- `local_compute`;
- `external`;
- `manual`.

Subscription-backed execution is not treated as literally free. Conclave records it as a different Connection cost source with quota/availability constraints rather than API token cost. Billing metadata is copied into the Attempt/Usage snapshot, not read from Worker identity.

## 5. Unified execution contract

Every automated Worker transport implements the same high-level contract:

```text
WorkerExecutionRequest
  -> adapter/transport
  -> Worker execution
  -> structured WorkerExecutionResult
```

Every transport implements the same `WorkerExecutor.execute` contract. The request carries `goalId`, `runId`, `taskId`, `attemptId`, `workerId`, `connectionId`, the validated protocol message, assembled context, and cancellation/deadline information. The result carries status (`succeeded`, `failed`, `waiting`, or `cancelled`), structured output or raw output, usage, execution/provider IDs, evidence references, and a classified retryable error when applicable.

API model adapters, local-agent adapters, remote-agent adapters, tool/CI workers, and human bridges must implement this contract. Their transport-specific authentication, streaming, session, and billing behavior stays behind the selected Connection adapter. Core never calls a provider-specific method or interprets provider-specific response shapes.

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

The selected Connection ID is persisted with the ModelCall/Attempt snapshot. Retries may select a different binding only through Core policy; an adapter may not silently switch connections.

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
5. interactive web/cloud worker connector;
6. remote agent transport;
7. manual transport.

Additional provider APIs should not take priority over completing the local-agent path.
