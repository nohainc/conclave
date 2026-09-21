# Worker Transport and Ensemble Implementation Phases

This plan extends the existing Integration & Production-Readiness Milestone. It should be implemented without creating role-specific orchestration branches.

## W1 — Worker / Connection separation

Refactor worker configuration so Worker capability/role identity is separate from connection/transport configuration.

Add transport, execution location, authentication mode, billing mode, provider/model family, independence group, concurrency, and availability metadata.

Do not migrate credentials into Worker records.

**Exit:** the same underlying model/agent can be configured as multiple Workers with different roles/transports without Core provider logic.

## W2 — Unified Worker execution adapter

Introduce one provider-independent execution contract used by API models, local agents, remote agents, and later manual workers.

Normalize result provenance, errors, usage, cancellation, timeout, and session metadata.

Keep existing model adapters behind this abstraction rather than duplicating orchestration.

**Exit:** Core/Forge calls one Worker execution interface regardless of transport.

## W3 — Local Runtime worker channel

Complete the authenticated outbound Local Runtime channel required by Integration phase I5.

Add:
- worker registration/heartbeat;
- capability/adapter discovery;
- execution request/acknowledgement;
- cancellation;
- reconnect/resume;
- request expiry;
- organization/project/run/task correlation;
- audit events.

**Exit:** Cloud can discover and execute one registered local Worker without inbound ports.

## W4 — Codex local-agent adapter

Add a Local Runtime adapter for an installed Codex agent/CLI using the user's supported local authentication/session.

Requirements:
- non-interactive execution;
- isolated session option;
- structured Conclave result conversion;
- repository/runtime permissions remain enforced by Local Runtime;
- timeout/cancellation;
- availability/usage reporting without exposing credentials.

**Exit:** a Forge research or implementation Task can be performed by a local Codex Worker with no Conclave-side OpenAI API key.

## W5 — Claude Code local-agent adapter

Implement the same contract for Claude Code/local agent access.

No Forge-specific branching is allowed.

**Exit:** a Task can switch between Codex, Claude Code, or an API Worker by configuration only.

## W6 — Execution Policy and candidate Attempts

Extend Task policy with:
- mode: single / parallel / synthesize / compare_and_select / competitive_implementation;
- candidate bounds;
- diversity/independence requirements;
- context isolation;
- budget/time limits;
- fallback rules.

Parallel Workers produce immutable candidate Attempts and Artifacts.

**Exit:** one research Task can execute against N Workers while preserving N independent candidates and one task identity.

## W7 — Generic synthesis/evaluation Task

Implement a generic synthesis/evaluation step using ordinary Task/Attempt/Decision primitives.

It must compare candidate evidence under an explicit rubric and preserve disagreements/rejected alternatives.

Core admits only the selected/combined result.

**Exit:** two or more research/design candidates can be synthesized into one downstream result without special Forge code.

## W8 — Parallel read-only roles

Enable the ensemble policy first for safe read-only work:
- research;
- architecture/design;
- planning proposals;
- review;
- evidence interpretation.

Implement finding aggregation without majority-vote dismissal of blockers.

**Exit:** Forge can configure one, two, or more Researchers/Reviewers using the same role policy mechanism.

## W9 — Quality presets and cost-aware routing

Add Economy, Balanced, High Assurance, Exploration, and Custom presets.

Implement:
- prefer subscription workers;
- provider/model diversity preferences;
- API spend limits;
- candidate limits;
- fallback order;
- run-level anti-explosion constraints.

Persist the resolved policy snapshot for audit/replay.

**Exit:** changing a quality preset changes worker count/diversity without workflow code changes.

## W10 — Interactive web/cloud Worker connector

Implement the first-class `web_app` Connection described in [WEB_APP_WORKERS.md](WEB_APP_WORKERS.md).

Add:
- authenticated remote connector/app/MCP surface;
- WorkerSession registration and leases;
- task claiming;
- bounded context retrieval;
- durable worker mailbox;
- structured candidate/result submission;
- follow-up message retrieval;
- optional external conversation reference;
- capability discovery including whether provider push/background continuation is supported.

Do not require Conclave to know or control the provider's internal chat id.

**Exit:** a subscription-backed web AI can claim a read-only Conclave Task from its native chat, submit a valid candidate result, receive a follow-up through the Conclave mailbox, and continue the same logical WorkerSession without direct provider API billing.

## W11 — Web-worker ensemble acceptance

Enable web/cloud Workers in generic Execution Policies and quality presets.

Acceptance:
- at least two isolated web workers independently execute one Research/Architecture Task;
- candidates remain separate Attempts;
- a Synthesizer receives both candidates;
- Conclave records provider/surface diversity and subscription billing mode;
- quota/unavailability can reroute to a configured API/local fallback.

**Exit:** Exploration mode can use multiple web subscription workers for design/research without special Forge logic.

## W12 — Isolated parallel implementation

Support competitive implementation only after read-only ensembles are stable.

Create an isolated workspace per candidate using Git worktrees/snapshots/branches. Never permit concurrent candidate writes to the same checkout.

Run tests/checks independently per candidate. Then:
- compare_and_select one candidate; or
- invoke a separate Integrator in another isolated workspace.

**Exit:** two Implementers can propose real competing repository changes without interfering with each other.

## W13 — Studio configuration and observability

Expose:
- Worker connections/transports;
- local worker online/offline status;
- billing mode;
- role execution policy;
- quality preset;
- candidate executions;
- synthesis decision;
- cost/usage per candidate;
- independence/diversity level.

Do not expose credentials or local session tokens.

**Exit:** a user can understand why Conclave selected one or several Workers and what each candidate contributed.

## W14 — Manual and remote transports

Add:
- remote Conclave-compatible agent transport;
- manual worker flow for unsupported online AI applications.

Manual flow exports a structured task and imports/validates the response. Do not automate consumer AI websites.

**Exit:** unsupported providers can participate without weakening Core contracts.

## W15 — Ensemble end-to-end acceptance

Run acceptance scenarios:

1. Economy: one Researcher, one Implementer, one Reviewer.
2. Design exploration: three independent Researchers/Architects -> Synthesizer -> one implementation.
3. High assurance: provider-diverse research + two independent Reviews.
4. Competitive implementation: two isolated implementations -> tests -> evaluator -> selected result.
5. Local subscriptions preferred, API fallback when local Worker unavailable.

**Exit:** all scenarios use the same Task/Attempt/Worker architecture and satisfy persistence, budget, independence, and completion invariants.

## Dependency order with existing integration milestone

Recommended order from the current repository state:

```text
I1 Persistence completeness
I2 Tenant-safe read model
I3 Run identity / durable lifecycle foundations
W1 Worker / Connection separation
W2 Unified Worker execution adapter
W3 Local Runtime worker channel
W4 Codex adapter
W5 Claude Code adapter
W6 Execution Policy
W7 Synthesis/evaluation
W8 Parallel read-only roles
W9 Quality presets/cost routing
W10 Interactive web/cloud Worker connector
W11 Web-worker ensemble acceptance
I4 Real Forge execution service using these abstractions
W12 Isolated parallel implementation
I6 Production authentication
I7 Studio functional completion
W13 Studio worker/ensemble UI
I8 CI evidence
I9 End-to-end acceptance
W14 Manual/remote transports
W15 Ensemble acceptance
I10 Production hardening
```

I5 is effectively completed through W3 plus the existing Local Runtime security work; preserve its exit criteria.
