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

The Local Runtime uses the same outbound persistent session for worker discovery and execution:

```text
Local Runtime connects outbound
  -> announces local Worker descriptors
  -> Cloud records the connected runtime/worker availability
  -> Core selects a Worker/Connection binding
  -> Cloud sends a correlated WorkerExecutionRequest
  -> Local Runtime dispatches to the registered local agent
  -> Local Runtime returns WorkerExecutionResult
```

The channel is scoped to the organization and project, while every request still carries its own run, task, attempt, worker, and connection IDs. Worker requests are replay-safe by request ID, return classified failures instead of being silently dropped, and are retried only by Core policy. A local worker is not considered available until its descriptor has been announced on the authenticated connection.

The Local Runtime reports:
- adapter identity/version;
- worker availability;
- supported capabilities;
- active session state without exposing credentials;
- quota/rate-limit signals where available;
- execution evidence;
- usage/cost metadata when available.

### 6.1 Codex local-agent adapter

The first subscription-backed adapter launches the locally installed Codex CLI
with `codex exec --json --full-auto`. The subscription login/session is owned by
the local Codex installation; it is never sent through the Cloud connection or
stored by Conclave.

The adapter resolves `request.repositoryId` against a pre-registered,
realpath-checked repository map. It does not accept a working directory from
the model prompt. Process output is byte-limited, cancellation and timeouts
terminate the process group, and stderr/exit status are retained as classified
worker failures.

Codex is prompted to return one Conclave protocol envelope. JSONL status events
are ignored unless they contain the final `{ messageType, payload }` envelope.
An execution is successful only when that envelope is present; plain text,
partial output, or an unregistered repository cannot enter Core state.

Because the local subscription does not expose token accounting to Conclave,
the adapter reports unknown usage (`null`) until a future Codex execution
interface provides authoritative usage metadata.

### 6.2 Claude Code local-agent adapter

Claude Code uses the same `LocalWorkerExecutor` interface. The default command
is `claude -p --output-format json`; the adapter unwraps the structured CLI
result, extracts the Conclave `{ messageType, payload }` envelope, and applies
the same repository, timeout, cancellation, and output limits as Codex. Claude
Code subscription credentials remain local, and Forge contains no Claude-
specific execution logic.

## 7. Execution policy

Core owns how many Workers participate in an execution. Adapters only execute
one correlated `WorkerExecutionRequest` and do not know whether the request is
part of Forge, research, review, or another workflow.

Supported policies are:

- `single`: exactly one selected Worker;
- `parallel`: independent candidate Workers run concurrently, optionally in
  bounded batches with `maxParallel`;
- `synthesize`: candidates run independently, then a distinct synthesizer
  receives an ordinary `TaskRequest` containing their structured outputs and
  returns a validated `DecisionResult`;
- `compare_and_select`: candidates run independently, then a distinct selector
  receives an ordinary evaluation `TaskRequest` and returns a validated
  `DecisionResult`.

Synthesis and comparison require at least two candidates and an independent
Worker. Core rejects policies that reuse a candidate as the synthesizer or
selector. Candidate and decision requests receive distinct request IDs and the
selected Worker/Connection IDs, so every execution remains auditable.

## 8. Read-only multi-worker roles

Before implementation or other write-capable work, Core can run an independent
read-only panel with these roles:

- `researcher` — repository and evidence discovery;
- `architect` — architecture proposals;
- `planner` — implementation/task proposals;
- `reviewer` — independent review of the current evidence or proposal.

Each role requires its declared capability and `repository_read` permission.
Workers carrying write, shell, build, or runtime-write permissions are rejected
from the panel. Workers must also have distinct independence keys, so a panel
cannot claim independent perspectives from two bindings of the same underlying
worker.

The panel returns role-labelled, correlated `WorkerExecutionResult` values.
Their outputs can then be passed to the generic synthesis/evaluation Task from
the previous section; no Forge-specific worker selection is involved.

## 9. Quality presets and cost routing

Core exposes named quality policies so callers choose an outcome profile rather
than a provider:

- `economy`: one eligible, lowest-cost Worker;
- `balanced`: two independent candidates in parallel;
- `high_assurance`: two independent candidates followed by synthesis/evaluation;
- `exploration`: three independent candidates followed by synthesis/evaluation;
- `custom`: explicitly supplied mode, candidate count, concurrency, independence,
  and cost ceiling.

Routing filters by capability, role, permission, availability, execution
environment, and the preset cost ceiling. It orders eligible bindings by
estimated attempt cost, skips duplicate independence keys when required, and
fails closed when the requested number of eligible Workers cannot be found.
The selected Connection cost snapshot can be recorded with the Attempt and
ModelCall for later usage accounting.

## 10. Parallel implementation workspaces

Parallel implementation is enabled only after the read-only panel has produced
its research, architecture, planning, or review evidence. Each implementation
Worker receives a distinct Local Runtime repository ID backed by a detached Git
worktree. Core rejects duplicate workspace IDs, duplicate Worker identities,
and shared independence keys before starting execution.

The Local Runtime creates worktrees only beneath its configured workspace root,
accepts only safe repository/workspace ID segments, and removes only worktrees
that it created and tracks. Results remain correlated to the Worker and
workspace repository ID so proposals can be reviewed, compared, merged, or
discarded without mutating the primary checkout.

## 11. Session isolation

A Worker execution may request:
- a new isolated session;
- reuse of an existing task session;
- a persistent project session where explicitly allowed.

Independent research/review must use isolated session/context unless policy explicitly allows reuse.

Separate chats/sessions using the same underlying model can provide context independence but do not count as provider independence.

## 12. Fallback routing

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

## 13. Initial implementation priority

The first production transports should be:

1. existing provider API adapter(s);
2. Local Runtime transport;
3. Codex local-agent adapter;
4. Claude Code local-agent adapter;
5. interactive web/cloud worker connector;
6. remote agent transport;
7. manual transport.

Additional provider APIs should not take priority over completing the local-agent path.
