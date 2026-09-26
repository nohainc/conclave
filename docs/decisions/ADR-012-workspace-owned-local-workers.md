# ADR-012: Workspace-Owned Workers and Managed Adapter Processes

**Status:** Accepted; implementation is converging under Architecture v7

**Date:** 2026-09-26  
**Builds on:** ADR-008, ADR-009, ADR-010, ADR-011  
**Partially supersedes:** ADR-010 configured-Worker ownership/cardinality and creation flow

## Context

The current v6 implementation established a useful user-facing distinction between:

- Workspace — machine-backed execution environment;
- Worker Type — installable integration definition;
- configured Worker — AI/tool identity;
- credential state — internal authentication/readiness.

It also implemented configured Workers as Cloud-created resources that may bind to multiple Workspaces.

That model is workable, but it makes one logical Worker span several machines even though the properties that make a Worker executable are local:

- installed tool/runtime;
- local account or subscription session;
- API key or other credential;
- operating-system permissions;
- filesystem/network permissions;
- local dependency/tool versions;
- local process environment.

It therefore creates per-Workspace credential and readiness state beneath a supposedly global Worker.

The next product version should make the machine boundary explicit and simpler.

## Decision

### 1. One Conclave Workspace application per normal machine installation

The user installs one product:

> **Conclave Workspace**

Conclave Workspace is the persistent local execution and security runtime for one machine/OS-user installation.

It:
- pairs with Conclave Cloud;
- maintains the secure Cloud connection;
- reports machine/runtime capabilities;
- owns the Work Root;
- creates/resolves Workstream working directories;
- manages local configured Workers;
- manages local credentials;
- manages Worker adapter packages;
- launches and supervises Worker child processes;
- enforces local permissions;
- streams execution status/results;
- handles cancellation;
- exposes minimal local diagnostics/update UX.

There is no separate user-installed Worker application.

### 2. A configured Worker belongs to exactly one Workspace

The v7 cardinality is:

~~~text
Workspace 1 -> N Configured Workers
Configured Worker N -> 1 Workspace
Worker Type 1 -> N Configured Workers
~~~

A configured Worker is created and configured locally in Conclave Workspace.

Examples:

~~~text
MacBook Pro
├── Codex Personal
├── Antigravity Personal
└── OpenAI API Work

Mac Mini
├── Codex Build
└── Claude Review
~~~

Two Workers on different Workspaces may have the same display name, but they have different immutable Worker IDs.

This supersedes the ADR-010 rule that one configured Worker may bind to multiple Workspaces.

### 3. Configured Worker identity is local-first and Cloud-synced

The Workspace runtime generates the configured Worker ID and persists its local configuration.

Local authoritative properties include:
- Worker ID;
- Workspace ID association;
- display name;
- Worker Type;
- authentication method/credential reference;
- local permissions;
- default/allowed model settings;
- local concurrency ceiling;
- adapter-specific configuration;
- local readiness.

Conclave Cloud stores a safe synchronized projection used for:
- discovery/inventory;
- authorization;
- scheduling;
- remote enable/disable/drain state;
- Work/Run attribution;
- audit;
- health/readiness display.

Cloud never receives provider secrets.

### 4. Worker Type means integration adapter, not AI model

Worker Types represent how Conclave executes an AI/tool system.

Initial examples:

~~~text
Codex
Antigravity
Claude Code
OpenAI API
Gemini API
Anthropic API
Ollama
~~~

Do not create Worker Types for individual models such as:
- GPT-5.x;
- Gemini Pro/Flash;
- Claude Sonnet/Opus.

Model is configuration resolved within a configured Worker/Assignment.

Multiple configured Workers may use one Worker Type:

~~~text
Codex Worker Type
├── Codex Personal
└── Codex Company
~~~

### 5. Worker adapter packages are managed by Conclave Workspace

A Worker Type is implemented by a signed adapter package.

The adapter translates between the Conclave Worker protocol and the external execution system.

Examples:

~~~text
Codex Adapter -> Codex CLI -> ChatGPT subscription/session
Antigravity Adapter -> Antigravity CLI -> Google subscription/session
OpenAI API Adapter -> HTTPS -> OpenAI API
Gemini API Adapter -> HTTPS -> Gemini API
~~~

Adapter packages are:
- versioned;
- signed;
- verified before execution;
- installed once per Workspace per Worker Type/version;
- shared by configured Workers of that Worker Type;
- hidden as infrastructure in normal product UX.

The publisher signature binds the package file-tree digest and the canonical
manifest with its `signature` field removed. This prevents executable,
permission, platform, authentication, or secret-requirement declarations from
being changed independently of the signed package contents. Cloud release
catalog metadata is advisory; Workspace verifies the downloaded archive,
manifest binding, signature, permissions, and health before activation.

The user installs only Conclave Workspace.

### 6. Adapter processes are separate child processes

Conclave Workspace remains the long-lived process.

Adapter execution remains out-of-process.

Default v7 lifecycle:

~~~text
Assignment
-> Workspace resolves configured Worker
-> Workspace resolves adapter/version
-> Workspace launches adapter child process
-> adapter executes/calls external tool/API
-> result/status returned
-> process exits
~~~

Per-assignment child processes are the default because they provide:
- crash isolation;
- cancellation boundaries;
- bounded secret exposure;
- Workstream CWD isolation;
- easier upgrades;
- simpler cleanup.

Persistent adapter daemons/pools are a later optimization only if measured startup cost justifies them.

### 7. External AI tools are not automatically bundled

For tool-backed Worker Types, the adapter may depend on a provider-supported local CLI/tool.

The adapter manifest declares prerequisites and detection/setup behavior.

Conclave Workspace may:
- detect an installed tool;
- validate supported version;
- guide installation;
- launch provider-supported authentication;
- report missing/outdated prerequisites.

Conclave should not redistribute third-party binaries unless licensing, update ownership, and platform support are intentionally accepted.

### 8. Worker creation/authentication belongs to Conclave Workspace

The normal local flow is:

~~~text
Conclave Workspace
-> Workers
-> Add Worker
-> choose Worker Type
-> name Worker
-> configure authentication
-> choose model/defaults where applicable
-> approve local permissions
-> validate
-> Ready
-> sync safe metadata to Cloud
~~~

Authentication examples:
- ChatGPT sign-in for Codex;
- Google sign-in for Antigravity;
- local secure API key for OpenAI/Gemini/Anthropic;
- local endpoint for Ollama.

Secrets remain local.

### 9. Conclave AX manages remote operation, not local trust setup

Conclave AX keeps:

~~~text
Execution
├── Workspaces
└── Workers
~~~

The Workers tab becomes an aggregated inventory of Workers discovered from Workspaces.

Conclave AX may:
- inspect Worker/Workspace/status/capabilities;
- enable or disable scheduling;
- drain a Worker;
- authorize/narrow Project/Workstream use;
- select an eligible Worker/model for Work;
- request local reauthentication/setup attention;
- inspect current/recent execution/audit.

Conclave AX does not normally:
- create a local Worker;
- enter provider secrets;
- approve new local permissions;
- silently remove local credentials;
- silently install arbitrary third-party tools.

### 10. Local policy is an upper bound; Cloud policy may only narrow it

Effective execution is the intersection of:

~~~text
local Worker capabilities/permissions
∩ Workspace runtime policy
∩ Cloud Project/Workstream authorization
∩ remote scheduling state
∩ Assignment request
~~~

Cloud cannot broaden local permissions.

A model requested by Cloud must be locally allowed and supported.

### 11. Workstream filesystem architecture remains unchanged

ADR-011 remains normative.

Every stateful assignment receives:

~~~text
<work-root>/<project-id>/<workstream-id>/
~~~

as its runtime-resolved CWD.

Project/Workstream names and Workspace/Worker IDs do not define that path.

Different configured Workers participating in one Workstream on the same Workspace receive the same Workstream directory.

### 12. One normal Workspace runtime per OS-user installation remains the product rule

The Workspace runtime continues to use one local data/configuration identity and process lock.

No hardware fingerprint is required.

Workspace re-enrollment may create a new Cloud Workspace ID while preserving local Work Root data as defined by ADR-011.

Configured Worker continuity across re-enrollment is allowed only when the local Worker configuration remains present and is safely re-associated during pairing/sync.

### 13. Conclave Workspace has a minimal GUI, not a duplicate Conclave AX

Local GUI responsibilities:
- pairing/connection;
- Workers;
- local authentication;
- permission prompts;
- current local execution;
- Work Root;
- diagnostics/logs;
- runtime/adapter updates;
- pause/quit.

Do not add:
- Projects;
- Workstreams;
- Discuss;
- Work timeline;
- Project members;
- orchestration configuration.

Those remain in Conclave AX.

### 14. Headless mode reuses the same runtime architecture

Future Linux/server deployment may run Conclave Workspace without GUI.

Local Worker configuration can later be exposed through a CLI/admin channel while preserving the same:
- runtime;
- Worker model;
- adapter packages;
- Cloud protocol;
- security boundaries.

A headless mode does not justify separate Worker applications.

## Security invariants

1. Provider secrets never enter Conclave Cloud.
2. Configured Worker belongs to one Workspace only.
3. Adapter packages are verified before launch.
4. Adapter child processes receive only explicitly required secrets.
5. Cloud cannot provide an arbitrary executable path.
6. Cloud cannot broaden local permissions.
7. Cloud cannot provide an arbitrary local CWD.
8. Workstream CWD is resolved by ADR-011 rules.
9. Local credential actions are explicit and auditable.
10. Runtime can terminate the full adapter/tool process tree.
11. Adapter stdout/stderr and logs are bounded/redacted.
12. Worker inventory sync contains safe metadata only.
13. Removing/revoking a Cloud projection does not silently destroy local secrets unless a local destructive action is explicitly authorized.

## Consequences

### Positive

- simpler resource hierarchy: Workspace owns Workers;
- local credentials and execution identity align naturally;
- no multi-Workspace credential matrix beneath one Worker;
- only one user-installed machine application;
- provider integrations remain independently versionable;
- adapter crashes do not kill the Workspace connection;
- one adapter package can serve many local Worker identities;
- model changes do not require new Worker Types;
- subscription CLI tools and direct APIs fit one contract;
- future local-model integrations fit without changing Cloud orchestration;
- Conclave AX remains a clean orchestration/control product.

### Tradeoffs

- Worker setup requires local access to the target machine;
- Cloud can no longer create a fully ready Worker by itself;
- current multi-Workspace configured Worker schema/API must migrate;
- local inventory reconciliation becomes security-critical;
- Workspace UI needs real Worker setup/authentication UX;
- tool prerequisite/version detection becomes adapter-specific;
- duplicate logical identities across machines are intentionally separate Workers.

## Core invariant

> **Conclave Workspace is the machine runtime. A configured Worker is one local executable AI/tool identity on that Workspace. Worker Type is the adapter. Model is configuration. Adapter execution is isolated in child processes. Conclave AX orchestrates and remotely controls use, but local trust and secrets remain local.**
