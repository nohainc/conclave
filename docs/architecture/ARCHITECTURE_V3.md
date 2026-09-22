# Conclave AX Architecture

**Status:** Normative  
**Version:** Architecture v3  
**Date:** 2026-09-21

Conclave AX uses a cloud-first orchestration model with a cross-platform Flutter/Dart client and host stack.

> **Cloud orchestrates. Agent Engine executes. Worker Plugins integrate. Workers do the work. Flutter apps control and observe.**

## Product topology

```text
Conclave AX Studio
Flutter / Dart
        |
        | HTTPS / WebSocket
        v
Conclave AX Cloud
TypeScript / Cloudflare
        |
        | Agent protocol
        v
Conclave AX Agent Engine
Dart native executable
        |
        | local IPC
        +--------------------+
        |                    |
        v                    v
Conclave Agent App      Worker Plugin processes
Flutter / Dart          language-independent protocol
                             |
                             v
                     AI / agent / tool / service
```

## Applications

### Conclave AX Studio
Primary user-facing application.

Technology:
- Flutter;
- Dart.

Targets:
- Web;
- macOS;
- Windows later;
- Linux later;
- mobile later if useful.

Studio owns no orchestration state. It communicates with Cloud.

### Conclave AX Cloud
Authoritative multi-user control plane.

Technology:
- TypeScript;
- Cloudflare Workers;
- Cloudflare Workflows;
- Durable Objects;
- D1;
- R2.

Cloud owns:
- authentication;
- Workspaces;
- Projects;
- Chats;
- Goals;
- Runs;
- Tasks;
- scheduling;
- policies;
- Agent/Worker configuration;
- plugin registry;
- audit/evidence.

Cloud never directly executes external AI/model/tool work.

### Conclave AX Agent App
Cross-platform host-management application.

Technology:
- Flutter;
- Dart.

Targets:
- macOS;
- Windows;
- Linux.

Responsibilities:
- enrollment/setup UI;
- connection/status UI;
- Workers and Plugins UI;
- update state;
- logs;
- permissions;
- local settings;
- start/stop/restart Agent Engine.

The Agent App is not the execution engine.

### Conclave AX Agent Engine
Long-running headless execution process.

Technology:
- Dart;
- AOT-compiled native executable.

Responsibilities:
- outbound Cloud connection;
- machine authentication;
- assignment journal;
- plugin manager;
- worker process supervision;
- local credentials integration;
- plugin/update lifecycle;
- filesystem/process/runtime primitives;
- result/evidence streaming.

The Agent Engine runs independently from the Flutter Agent App.

Closing or crashing the Agent App must not stop active work.

### Worker Plugins
Worker Plugins are separate executable processes implementing the Conclave Worker Plugin Protocol.

The protocol is language-independent.

First-party plugins should use Dart where practical, but plugins may use:
- Dart;
- TypeScript/Node.js;
- Rust;
- Python;
- Go;
- another language.

Examples:
- Codex;
- Claude Code;
- OpenAI API;
- Anthropic API;
- Gemini;
- Ollama;
- Git;
- shell/test runner;
- interactive web AI connector.

Cloud-side TypeScript code does not execute plugins. The `plugin-manifest`
package only validates manifest metadata, semantic versions, compatibility,
and declared permissions/billing modes. Plugin execution belongs to the
language-independent protocol implemented by the Agent Engine.

### Worker
A Worker is a configured instance of one Worker Plugin hosted by one Agent Engine.

Examples:
- GPT Architect;
- Codex Main;
- Claude Reviewer;
- ChatGPT Web Researcher.

Cloud schedules Workers, not providers or transports.

## Process model

```text
Process 1
Conclave Agent App
Flutter

Process 2
Conclave Agent Engine
Dart

Process 3+
Worker Plugin processes

Process N+
external agent/CLI processes
Codex / Claude Code / Git / Docker / etc.
```

Use OS processes as the primary reliability and security boundary.

Dart isolates may be used for CPU-heavy concurrent work inside a process, but they do not replace process isolation.

## Local communication

Agent App <-> Agent Engine uses a local IPC abstraction.

Preferred long-term transport:
- Unix domain socket on macOS/Linux;
- named pipe on Windows.

A loopback-only authenticated socket may be used during development.

Agent Engine <-> Worker Plugin uses a language-independent structured protocol, preferably JSON-RPC over stdin/stdout for v1.

## Multi-user hierarchy

```text
User
  -> Workspace
      -> Project
          -> Chat
              -> Message
              -> Goal
                  -> Run
                      -> Task
                          -> Attempt(s)
```

Workspace is the tenancy/security boundary.

Studio is chat-first. Run/task details are available as advanced views.

## Execution hierarchy

```text
Workspace
  -> Conclave Agent
      -> Agent Engine
          -> Worker Plugin
              -> Worker
```

One host machine normally has one Agent Engine and one optional Agent App.

One Agent Engine may host many Worker Plugins and many Workers.

## Forge execution boundary

Forge uses the same native execution model as every other v3 workflow:

```text
Forge
  -> Worker
      -> WorkerAssignment
          -> AgentGateway
              -> Agent
                  -> Worker Plugin
```

Forge selects a `Worker` together with its owning `Agent`, creates an
`Attempt`, and submits a `WorkerAssignment` through `AgentGateway`. The
assignment result is the only execution response Forge consumes. Transport,
provider, and billing details are adapter concerns of the Agent/Plugin path;
Forge must not reconstruct a connection resource or invoke a provider-specific
executor.

This keeps the workflow portable across local agents, remote agents, API
workers, and subscription-backed workers while preserving the same persisted
assignment and attempt identity.

## Web AI connector boundary

Web AI participation uses the same assignment lifecycle. The Web AI Worker
Plugin runs on an Agent Engine and uses the Cloud connector only as a relay:

```text
WorkerAssignment
  -> Agent Engine
      -> Web AI Worker Plugin
          -> Cloud connector mailbox/session lease
              -> ChatGPT, Claude, or another web session
```

The connector provides authenticated session registration, assignment claim,
bounded context/message retrieval, status reporting, finding/candidate relay,
and correlated `WorkerAssignmentResult` submission. It does not execute work,
select providers, create fallback Workers, or own orchestration state.

## Worker Plugin Registry

Cloud stores:
- plugin metadata in D1;
- packages in R2;
- version/compatibility metadata;
- permissions;
- signatures/digests;
- release channels.

Agent Engine downloads only required plugins.

Every package must be verified before execution.

## Updates

### Agent App / Agent Engine
Distributed as signed releases.

Update flow:
- download;
- verify;
- stage;
- wait for safe point;
- restart;
- health check;
- rollback on failure.

### Worker Plugins
Updated independently from the Agent.

Worker execution records the exact plugin version.

## Security boundaries

- Human User authentication is separate from Agent authentication.
- Agent App never embeds long-lived Cloud credentials.
- Agent Engine stores machine credentials in OS secure storage.
- Plugin secrets remain local by default in v1.
- Worker Plugin processes are isolated from the Agent Engine control process.
- Cloud is authoritative for orchestration.
- Agent Engine never invents follow-up Tasks.
- Cloud never directly calls model/provider APIs.

## Cloudflare role

Cloudflare remains the Cloud control-plane platform:

- Workers: HTTP API, auth callbacks, connector endpoints;
- Workflows: durable Runs;
- D1: structured state;
- R2: artifacts, plugin packages, release packages;
- Durable Objects: live Agent connections and transient realtime coordination;
- Static Assets: Flutter Web Studio.

## Source documents

- [Technology Stack](TECH_STACK.md)
- [Applications](APPLICATIONS.md)
- [Migration to Architecture v3](MIGRATION_TO_V3.md)
- [Architecture v3 Implementation Roadmap](../roadmaps/ARCHITECTURE_V3_IMPLEMENTATION.md)
- [Authentication and Multi-User](../specifications/AUTHENTICATION_MULTIUSER.md)
- [Studio Chat and Projects](../specifications/STUDIO_CHAT_PROJECTS.md)
- [Multi-Worker Orchestration](../specifications/MULTI_WORKER_ORCHESTRATION.md)
- [Domain Specification](../specifications/DOMAIN_SPECIFICATION.md)
