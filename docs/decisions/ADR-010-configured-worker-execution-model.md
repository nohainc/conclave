# ADR-010: Configured Worker as the User-Facing Execution Identity

**Status:** Accepted
**Date:** 2026-09-25  
**Builds on:** ADR-008, ADR-009, Architecture v6

## Context

Conclave AX currently exposes three execution concepts side by side:

- Workspace — the machine-backed execution environment;
- Worker — primarily an installable/catalog capability such as Codex or Claude Code;
- AI Account — the external provider identity and credential state used by a Worker.

This is technically explicit, but it creates product duplication.

A user who wants two Codex identities should naturally think:

- Codex Personal;
- Codex Company.

The current model instead asks the user to reason about one Codex Worker package plus separate AI Account records and Workspace installation state.

The existing UI reinforces this mismatch:

- the global Workers surface is largely a Worker catalog / installation-management view;
- Add AI Account separately asks for Worker type, Workspace, authentication and sharing;
- Workspace detail separately exposes Workers and AI Accounts.

The resulting product model is more infrastructure-oriented than task-oriented.

## Decision

Adopt **Configured Worker** as the primary user-facing execution identity.

The normal user-facing execution model becomes:

~~~text
Execution
├── Workspaces
└── Workers
~~~

There is no standalone **AI Accounts** primary product surface.

This vocabulary is frozen by EW-0. **Execution** is the top-level product
area; **Workspaces** and **Workers** are its primary user-facing resources.
AI Account, Credential Profile, connection, and local credential records are
implementation/security terms beneath a Worker, not peer user resources.

EW-13 closes the migration boundary: the application exposes no AI Account
navigation, setup wizard, or standalone account API routes. Credential setup
and reauthentication are reached from a configured Worker Workspace binding;
the underlying metadata remains internal where required for runtime security,
provider policy, audit, and accounting.

### Workspace

A Workspace is one machine-backed execution environment.

A Workspace provides:
- runtime capacity;
- repository/path access;
- local permissions;
- local secure credential storage;
- installed Worker packages;
- Project grants;
- execution state.

### Worker Type

A Worker Type is an installable integration/capability definition such as:
- Codex;
- Claude Code;
- OpenAI;
- Anthropic;
- Forge.

Worker Types are catalog/infrastructure objects. They are selected during Worker creation and are not normally managed as first-class user resources.

### Configured Worker

A Worker is a user-managed configured executable identity.

A Worker contains:
- id;
- owner;
- display name;
- Worker Type;
- one logical external AI identity / connection;
- global/default configuration;
- capabilities;
- model defaults;
- concurrency;
- cost/billing metadata where applicable;
- Workspace bindings;
- status/readiness.

Examples:

~~~text
Codex Personal
Codex Company
Claude Review
GPT Research
~~~

Multiple Workers may use the same Worker Type.

### Credential state

Credential/authentication state remains a separate internal security concern.

A Worker has one logical external AI identity, but credential material may need to be established independently on each bound Workspace because secrets remain in the Workspace secure store and are not uploaded to Conclave Cloud.

Therefore:

~~~text
Configured Worker
  └── one logical AI identity
      ├── credential readiness on Workspace A
      └── credential readiness on Workspace B
~~~

The credential implementation may continue to use internal records during migration, but those records are not a standalone user-facing product concept.

### Workspace binding

A Worker may be bound to one or more Workspaces.

Binding a Worker to a Workspace causes Conclave to converge the required runtime state automatically:

1. required Worker Type/package is installed or updated;
2. local permissions are checked;
3. credential setup is requested when required;
4. readiness is tracked.

Users should not normally perform a separate "install Worker package" step.

### Cardinality

- one Worker Type -> many configured Workers;
- one configured Worker -> exactly one logical AI identity;
- one configured Worker -> one or more Workspaces;
- one Workspace -> many configured Workers;
- one Project/Workstream may be authorized to use a subset of configured Workers.

### Roles and workflows

A configured Worker does not have one mandatory permanent workflow role.

Workflow steps continue to declare:
- role;
- required capabilities;
- execution class.

The scheduler resolves eligible configured Workers.

Workers may optionally define preferred/allowed roles as advanced policy, but a Worker is not intrinsically "the reviewer" or "the implementer".

## Product UX

Rename the current top-level Workspaces execution area to **Execution**.

Primary tabs:

~~~text
Execution
├── Workspaces
└── Workers
~~~

### Workers

The Workers page lists configured Workers, not Worker catalog packages.

Example card:

~~~text
Codex Personal
Type: Codex
Connection: OpenAI
Status: Ready
Workspaces: 2 / 2 ready
Active assignments: 1
~~~

### Add Worker

One setup flow should collect:
- Worker name;
- Worker Type;
- authentication/connection;
- default model/config;
- concurrency;
- Workspace bindings;
- optional advanced policy.

Creating a Worker should replace the current multi-step mental model of:
install Worker -> create AI Account -> select Worker -> select Workspace -> authenticate.

### Workspace detail

Workspace detail should retain a Workers view, but it lists configured Workers bound to that Workspace and their local readiness.

Standalone AI Accounts should be removed from Workspace navigation.

## Authorization

Worker authorization becomes the primary product policy.

Project/Workstream execution policy answers:

> Which configured Workers may this work use?

Credential ownership, provider sharing policy, secure secret location and billing attribution remain enforced internally.

The architecture must not weaken these existing security boundaries merely to simplify the UX.

### Runtime-reported machine facts

Workspace machine information is runtime state, not Workspace configuration. When
the Conclave Workspace application connects, it reports its platform,
architecture, hostname, application version, and runtime capabilities. Cloud
stores these facts separately from the logical execution Workspace identity and
the UI presents them as read-only diagnostics. Users configure only the
Workspace display name; they do not enter or edit machine identity facts.

## Usage and audit

Usage should remain attributable to:
- requester;
- Project;
- Workstream;
- Work Request;
- Workspace;
- configured Worker;
- Worker Type/provider/model;
- logical credential owner;
- cost/tokens/duration.

Credential-owner attribution may remain separately recorded even though AI Account is not a primary product noun.

## Migration stance

Conclave AX is pre-production.

Prefer a clean domain migration over preserving the current product vocabulary indefinitely.

During migration it is acceptable for current `ai_accounts` and Worker-installation records to remain implementation details behind the new Worker resource.

Do not expose them as parallel user-managed objects once the configured Worker flow is available.

## Consequences

### Positive

- simpler mental model;
- no duplicate Worker/AI Account setup surfaces;
- multiple identities of the same provider are natural;
- Worker names become meaningful execution identities;
- Workspace package installation becomes automatic infrastructure;
- Project/Workstream policy becomes easier to explain;
- credential security remains local and explicit internally.

### Tradeoffs

- reintroduces a persistent configured Worker entity that ADR-004 intentionally removed;
- scheduler and authorization must distinguish configured Worker from Worker Type;
- credential readiness becomes per-Workspace beneath one logical Worker;
- migration touches schema, APIs, Studio, scheduler, runtime desired state, usage and docs.

The previous ADR-004 choice remains valid historical context, but v6 product needs now justify reintroducing a configured Worker entity at the product/domain layer.

## Core product invariant

> **Workspace is where AI can work. Worker is the configured AI/tool identity that can work. Project and Workstream define what it works on. Credential and package state are implementation details beneath those concepts.**

## EW-0 frozen invariants

- Worker Type is catalog/infrastructure, not a configured user resource.
- A Worker has exactly one logical external AI identity.
- A Worker may bind to multiple Workspaces.
- A Workspace may host multiple Workers.
- Multiple Workers may use the same Worker Type.
- Credential material remains local to each Workspace where required.
- A Worker has no single mandatory role; Workflows select Workers by role and
  capability.
