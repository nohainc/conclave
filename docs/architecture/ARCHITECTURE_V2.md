# Conclave AX Architecture v2 — Cloud Orchestration, Agent Execution

**Status:** Proposed normative architecture  
**Date:** 2026-09-21  
**Supersedes:** direct Cloud-to-provider execution and Local Runtime as a top-level product boundary

## 1. Product principle

Conclave AX coordinates work; AI systems perform the intellectual and implementation work.

The authoritative execution model is:

```text
Human User
   |
Conclave AX Studio
   |
Conclave AX Cloud
   |
   +-- orchestration / state / policy / audit
   |
Conclave Agent
   |
Worker Plugin
   |
Worker Instance
   |
AI model / AI agent / external system / tool
```

Cloud does not directly call OpenAI, Anthropic, Codex, Claude Code, Gemini, local models, browser AI products, Git, shell, CI, or other execution systems.

Every executable capability is exposed through a Worker hosted by a Conclave Agent.

This gives Conclave one execution path, one security boundary, and one audit model regardless of where intelligence actually comes from.

## 2. Simple vocabulary

### Cloud

Conclave AX Cloud is the authoritative control plane.

It owns:
- authentication and multi-user tenancy;
- Workspaces, Projects, Chats, Goals, Runs, Tasks, Attempts;
- orchestration and scheduling;
- execution policies;
- Worker selection;
- budgets and quotas;
- verification/completion state;
- Agent registry and presence;
- Worker configuration;
- Worker Plugin registry;
- message relay;
- artifacts and audit history;
- Studio API.

Cloud decides **what should happen next**, usually based on structured proposals from a Lead AI Worker plus deterministic policy checks.

Cloud does not perform model reasoning itself.

### Studio

Conclave AX Studio is the human UI.

Studio:
- authenticates a User;
- manages Workspaces and Projects;
- provides AI-style Chats;
- sends user requests;
- shows inline Run progress;
- manages Agents, Plugins, and Workers;
- exposes advanced Run details;
- sends pause/resume/cancel/approve commands.

Studio never owns authoritative Run state.

### Conclave Agent

A Conclave Agent is the installed execution host.

For v1, use one Agent service per host machine. A Workspace may register many Agents on many machines.

The Agent:
- enrolls/authenticates to Cloud as a machine identity;
- maintains an outbound secure connection;
- reports host capabilities and health;
- self-updates;
- synchronizes Worker configuration;
- downloads required Worker Plugins;
- verifies and updates Worker Plugins;
- hosts Worker processes;
- stores local Worker secrets safely;
- accepts assignments;
- executes/cancels Workers;
- streams progress;
- returns structured results and evidence.

The Agent does not own orchestration policy.

### Worker Plugin

A Worker Plugin is a versioned, signed package that knows how to integrate with one type of external capability.

Examples:
- OpenAI API plugin;
- Anthropic API plugin;
- Codex plugin;
- Claude Code plugin;
- Gemini plugin;
- Ollama plugin;
- ChatGPT web connector plugin;
- Git plugin;
- test runner plugin;
- GitHub CI plugin.

Worker Plugins live in the Cloud Plugin Registry and are downloaded by Agents only when required.

### Worker

A Worker is one configured, independently addressable instance of a Worker Plugin.

Examples:

```text
Worker: GPT Architect
plugin: openai
model/config: ...
roles: architect, researcher
host: agent-macbook
```

```text
Worker: Codex Main
plugin: codex
roles: implementer, researcher
host: agent-macbook
credential location: local
```

One plugin may create many Workers.

Workers are what Cloud schedules.

A Worker must never secretly select from a pool of unrelated AI models. Multi-model selection belongs to Cloud orchestration.

## 3. High-level topology

```text
                             CONCLAVE AX CLOUD

              +------------------------------------------+
              | Identity / Workspaces / Projects / Chat |
              | Goals / Runs / Tasks / Attempts          |
              | Scheduling / policies / verification    |
              | Agent registry and message relay        |
              | Worker Plugin Registry                  |
              | Worker registry                         |
              | D1 / R2 / audit / usage                 |
              +--------------------+---------------------+
                                   |
                   outbound authenticated channels
                                   |
              +--------------------+---------------------+
              |                    |                     |
              v                    v                     v

        Conclave Agent A     Conclave Agent B      Conclave Agent C
           MacBook               Server                 Mac Mini
              |                    |                     |
        +-----+-----+        +-----+-----+          +----+----+
        |           |        |           |          |         |
      Worker      Worker   Worker      Worker     Worker    Worker
       Codex      Claude   Docker      Ollama     Codex     Xcode
        |           |        |           |          |         |
      plugin      plugin   plugin      plugin      plugin     plugin

                                   ^
                                   |
                           CONCLAVE AX STUDIO
                           web / desktop client
```

## 4. Cloud-first authority

Cloud is the sole authoritative owner of:
- Goal/Run state;
- Task graph;
- assignment decisions;
- verification status;
- completion state;
- Worker/Agent configuration;
- Workspace membership and permissions.

Agents may cache assignments and results during temporary disconnection, but they may not independently create new orchestration branches.

If Cloud is unavailable:
- Agent may finish an already accepted atomic assignment when safe;
- Agent persists the result locally;
- Agent submits it after reconnect;
- Agent must not invent follow-up Tasks.

This avoids dual-authority state.

## 5. AI-driven planning without AI logic in Conclave code

Cloud orchestration must not hard-code software architecture knowledge.

Typical flow:

```text
User request
  -> Cloud creates Goal
  -> Cloud assigns Lead Worker
  -> Lead proposes plan/tasks/workers/policies
  -> Core validates proposal
  -> Cloud persists accepted plan
  -> Cloud dispatches Tasks
```

AI Workers do:
- research;
- planning;
- architecture;
- implementation;
- synthesis;
- review;
- verification interpretation;
- reporting.

Conclave Cloud does:
- schema validation;
- policy enforcement;
- permissions;
- budgets;
- scheduling;
- state transitions;
- evidence requirements;
- audit;
- retries/fallbacks;
- completion gate.

## 6. Multi-user hierarchy

```text
User
  -> Workspace
      -> Project
          -> Chat
              -> Message
              -> Goal
                  -> Run
                      -> Phase
                          -> Task
                              -> Attempt(s)
```

### Workspace

Workspace is the tenant, membership, Agent, Worker, security, quota, and billing boundary.

Personal and team use the same Workspace entity.

### Project

Project groups:
- Chats;
- repositories/resources;
- project instructions;
- default Workers;
- default quality/execution policy;
- budgets;
- plugin settings;
- artifacts/results.

### Chat

Chat is the primary human-facing conversation.

One Chat may create multiple Goals over time.

Chat text is not authoritative orchestration state.

### Goal / Run

Goal is the durable requested outcome.

Run is one execution attempt under a specific policy/Worker configuration snapshot.

## 7. Studio UX

Studio should look and behave like a modern AI application.

Primary layout:

```text
Workspace
  Projects
    Chats
      conversation
      inline run progress
      results
```

Advanced views:
- Run graph;
- Tasks;
- candidate Attempts;
- synthesis decisions;
- Agent/Worker selection;
- findings;
- verification;
- artifacts;
- usage/cost;
- audit timeline.

Internal Worker conversations should not flood the main Chat.

Conclave surfaces concise progress and final outcomes.

## 8. Authentication identities

There are separate identity classes:

### Human User
Authenticates to Studio/Cloud.

### Conclave Agent
Machine identity enrolled into a Workspace.

### Worker
Configured execution resource hosted by an Agent.

### Worker Plugin
Signed package identity/version, not a login principal.

### System
Cloud-owned automation actor.

These identities must never share credentials.

## 9. Human authentication

Web Studio uses secure browser sessions.

Desktop Studio uses OAuth/OIDC authorization-code + PKCE or equivalent secure delegated login.

No long-lived bearer secret is compiled into Flutter Web.

Initial Workspace roles:
- owner;
- admin;
- member;
- viewer.

Project-level restrictions may be added without creating a complex ACL language.

## 10. Agent enrollment

Suggested flow:

1. User signs into Studio.
2. User selects **Add Agent**.
3. Cloud creates a short-lived one-time enrollment token.
4. User installs/starts Conclave Agent.
5. Agent submits enrollment token and host public key/device metadata.
6. Cloud returns durable Agent identity/credential.
7. Agent stores credential in OS secure storage.
8. Cloud marks Agent online after authenticated channel is established.

Agent credentials:
- belong to one Workspace;
- are revocable independently;
- cannot act as a human User;
- cannot access unrelated Workspace resources.

## 11. Agent connection protocol

Prefer one outbound WebSocket connection per Agent.

Baseline messages:

```text
agent.hello
agent.heartbeat
agent.capabilities
agent.sync.request
agent.sync.result

plugin.install
plugin.update
plugin.remove

worker.configure
worker.enable
worker.disable
worker.status

assignment.start
assignment.ack
assignment.progress
assignment.result
assignment.error
assignment.cancel

artifact.upload
log.chunk

agent.update.available
agent.update.stage
agent.update.restart
```

Every execution message carries:
- workspaceId;
- agentId;
- workerId;
- runId;
- taskId;
- attemptId;
- assignmentId;
- protocol version;
- idempotency key.

## 12. Agent Gateway

Cloud should replace the current Local Runtime connection concept with an **Agent Gateway**.

Recommended Cloudflare mapping:
- Durable Object per connected Agent for live WebSocket/presence;
- D1 for Agent records, desired configuration, assignments, leases, statuses;
- Workflows wait for assignment completion events;
- optional Queues later if scale/offline delivery warrants it.

The Durable Object is not authoritative business state; D1/Core remain authoritative.

## 13. Offline and reconnect behavior

Assignments have durable Cloud records.

If Agent disconnects before accepting:
- assignment remains queued;
- Cloud may wait or reroute according to policy.

If Agent disconnects during execution:
- assignment becomes connection-lost/unknown;
- Agent may finish locally if safe;
- on reconnect Agent reports assignment journal;
- Cloud reconciles by assignmentId/idempotency key;
- duplicate terminal results are ignored.

Never silently execute the same write-capable Task on two Agents unless policy explicitly creates independent candidate Attempts.

## 14. Worker Plugin Registry

Cloud stores the official Worker Plugin registry.

D1 stores:
- plugin id;
- version;
- status;
- compatibility;
- manifest metadata;
- permissions;
- supported platforms;
- release channel;
- SHA-256 digest;
- signature metadata;
- package R2 key.

R2 stores plugin packages.

Agent downloads packages only from approved registry entries unless a future development mode explicitly permits local unsigned packages.

## 15. Worker Plugin manifest

Minimum manifest:

```text
pluginId
version
displayName
description
publisher
protocolVersion
minAgentVersion
maxAgentVersion
supportedOs
supportedArch
entrypoint
roles
capabilities
permissions
configSchema
secretSchema
billingModes
updateChannel
packageDigest
signature
```

Plugin permissions are explicit:
- network domains;
- repository read/write;
- process spawn;
- shell;
- filesystem scope;
- credentials;
- browser/connector;
- Docker;
- CI.

## 16. Worker configuration

Worker is a Cloud-managed configured instance:

```text
id
workspaceId
agentId
pluginId
pluginVersionPolicy
name
roles
capabilities
config
secretRefs
availability
enabled
independenceKey
billingMode
costMetadata
concurrencyLimit
sessionPolicy
createdBy
```

Cloud stores non-secret config.

For v1, secrets needed for execution should preferably remain on the Agent host in OS secure storage. Cloud stores only secret references/status.

Optional Cloud-managed encrypted secrets can be added later for team-shared API credentials.

## 17. Plugin execution isolation

Worker Plugin execution must not run inside the Agent control process.

Preferred boundary:
- one child process or sandbox per active plugin/worker execution;
- bounded environment variables;
- bounded filesystem access;
- explicit network policy where feasible;
- timeout/cancellation;
- stdout/stderr limits;
- crash isolation.

A plugin crash must not kill the Agent.

## 18. Agent self-update

Agent has an independent signed release channel.

Update flow:
1. Agent reports version/channel.
2. Cloud advertises compatible newer version.
3. Agent downloads update package.
4. Agent verifies digest/signature.
5. Agent stages update.
6. Agent waits for safe point when no incompatible assignment is running.
7. Agent restarts into new version.
8. Agent reports health.
9. Automatic rollback occurs if startup health fails.

Channels:
- stable;
- beta;
- development.

## 19. Worker Plugin update

Plugin updates are independent from Agent updates.

Cloud calculates compatibility from:
- Agent version;
- OS/architecture;
- plugin version constraints;
- Workspace policy.

Agent:
- downloads;
- verifies;
- stages;
- drains old Worker process;
- starts new version;
- health-checks;
- rolls back on failure.

Worker execution records exact plugin version for reproducibility.

## 20. Worker types

All external systems are represented as Worker Plugins.

Examples:

### API model
Agent -> OpenAI plugin -> OpenAI API

### Local AI agent
Agent -> Codex plugin -> Codex CLI/session

### Local model
Agent -> Ollama plugin -> local model

### Interactive web AI
Agent -> web connector plugin -> Cloud relay/MCP endpoint -> web AI session

### Tool/CI
Agent -> Git/Docker/test/GitHub plugin -> external system

Cloud still sees only Worker assignments/results.

## 21. Interactive web AI rule

The public connector endpoint may physically run in Cloud because web AI tools need a reachable URL, but it is a relay owned by a Worker execution.

Flow:

```text
Cloud schedules web Worker
  -> owning Agent/plugin opens WorkerSession
  -> Cloud exposes session mailbox/tool endpoint
  -> ChatGPT/Claude/etc calls connector
  -> connector routes messages to owning Worker/Agent
  -> Worker submits structured result
  -> Cloud completes Attempt
```

Cloud connector logic must not become a hidden direct model adapter.

## 22. Multi-worker orchestration

Existing execution-policy concepts remain valid.

One Task may use:
- single;
- parallel;
- synthesize;
- compare_and_select;
- competitive_implementation.

Cloud selects multiple Workers, potentially across multiple Agents.

Each candidate creates a distinct Attempt.

The accepted/synthesized result is explicit and auditable.

## 23. Storage

### D1

Authoritative metadata:
- users;
- workspaces;
- memberships;
- projects;
- chats/messages;
- goals/runs/tasks/attempts;
- agents;
- agent sessions/presence metadata;
- worker plugin registry;
- worker instances;
- assignments;
- events;
- findings/verifications;
- budgets/usage;
- audit.

### R2

Large immutable content:
- artifacts;
- model outputs when retained;
- diffs;
- logs;
- screenshots;
- CI outputs;
- Worker Plugin packages;
- Agent update packages if desired.

### Durable Objects

Transient live coordination:
- Agent WebSocket connection;
- optional real-time Chat/Run fanout;
- connector session relay.

Do not place irreplaceable orchestration state only in a Durable Object.

## 24. Cloudflare role

Cloudflare remains a good fit for the control plane:

- Workers: API, auth callbacks, connector endpoints;
- Workflows: durable Run orchestration and waits;
- D1: relational control-plane state;
- R2: artifacts/packages;
- Durable Objects: Agent/WebSocket sessions;
- Static Assets: Flutter Web Studio.

Do not introduce more infrastructure until measured requirements justify it.

## 25. Deployment topology

Initial:

```text
https://app.conclaveax.com/
  -> Flutter Studio

https://app.conclaveax.com/api/*
  -> Cloud Worker API

wss://app.conclaveax.com/api/agents/connect
  -> Agent Gateway

https://app.conclaveax.com/api/plugins/*
  -> Plugin Registry

https://app.conclaveax.com/api/connectors/*
  -> interactive worker relay
```

Keep same-origin API initially.

## 26. Core invariant

> Cloud orchestrates; Conclave Agents execute; Worker Plugins integrate; Workers perform work; Studio controls and observes.

No new feature should violate this boundary without a new ADR.
