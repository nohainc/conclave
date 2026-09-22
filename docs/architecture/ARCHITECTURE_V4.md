# Conclave AX Architecture v4 — Host + Worker

**Status:** Normative  
**Date:** 2026-09-22  
**Supersedes:** Architecture v3

## 1. Product principle

Conclave AX is a cloud-orchestrated system for coordinating AI work across machines.

The v4 architecture deliberately reduces the execution model to four concepts:

```text
Studio -> Cloud -> Host -> Worker
```

A fifth concept, **Credential Profile**, determines whose AI account, API key, subscription, or local model identity a Worker uses for one assignment.

> **Cloud orchestrates. Hosts provide machines. Workers provide AI/tool capabilities. Credential Profiles provide identity and payment context.**

There is no separate product-level Agent, Agent Engine, Plugin, Connection, or configured Worker-instance abstraction in v4.

## 2. Product topology

```text
                         CONCLAVE STUDIO
                         Flutter Web
                              |
                              | HTTPS / realtime updates
                              v
                         CONCLAVE CLOUD
                  TypeScript / Cloudflare
          users / workspaces / chats / orchestration
                              |
                              | Host protocol
                              v
                  +--------------------------+
                  |      CONCLAVE HOST       |
                  | Flutter + Dart desktop   |
                  | one installation/device  |
                  +--------------------------+
                    |        |        |
                    v        v        v
                  Codex    Claude    OpenAI
                  Worker    Worker    Worker
                    |        |        |
                    +--------+--------+
                             |
                  AI model / CLI / API / tool
```

A Host may run many Worker assignments in parallel, subject to host, Worker, credential, and Cloud policy limits.

## 3. Applications

### 3.1 Conclave Studio

Conclave Studio is the primary user interface.

**Technology**
- Flutter;
- Dart;
- web-first deployment.

**v4 targets**
- Web is the only required Studio platform for v4.
- Mobile applications may be added later using the same Cloud APIs and Flutter design system.
- Desktop Studio is not a v4 product requirement.

**Responsibilities**
- authentication;
- Workspace and membership management;
- Projects and Chats;
- Goal/Run control;
- Host enrollment and management;
- Worker catalog and availability;
- Credential Profile setup and sharing;
- Worker/model selection;
- usage and cost visibility;
- approvals and final results.

Studio never talks directly to a Host or Worker. All communication goes through Cloud.

### 3.2 Conclave Cloud

Conclave Cloud is the authoritative control plane.

**Technology**
- TypeScript;
- Cloudflare Workers;
- Cloudflare Workflows;
- Durable Objects;
- D1;
- R2.

Cloud owns:
- human identity integration;
- Workspaces and authorization;
- Projects and Chats;
- Goals, Runs, Tasks, Attempts;
- Worker selection;
- Host selection;
- Credential Profile authorization;
- assignment creation;
- execution policies;
- budgets;
- verification;
- artifacts;
- audit;
- usage attribution.

Cloud does not execute AI models, CLIs, provider SDKs, repositories, or shell commands.

### 3.3 Conclave Host

Conclave Host is installed once per physical or virtual machine.

**Technology**
- Flutter + Dart desktop application;
- macOS first;
- Windows and Linux supported by the same product.

The Host combines the current Agent App and Agent Engine responsibilities into one application/runtime.

The Host may run minimized or in a tray. Closing/minimizing the window should not necessarily exit the application. Explicitly quitting/stopping the Host may interrupt active assignments; Cloud must reconcile those assignments.

**Responsibilities**
- machine identity;
- Cloud connection;
- Host enrollment;
- Workspace bindings;
- desired-state reconciliation;
- Worker installation/update/removal;
- secure local Credential Profile storage;
- process supervision;
- repository/filesystem permissions;
- assignment journal;
- concurrency enforcement;
- logs;
- Host self-update;
- minimal local UX for machine-specific operations.

The Host does not own project orchestration.

### 3.4 Worker

A Worker is the installable execution integration itself.

Examples:
- Codex Worker;
- Claude Code Worker;
- OpenAI Worker;
- Anthropic Worker;
- Gemini Worker;
- Ollama Worker;
- ChatGPT Web Worker;
- Git/Test Worker.

A Worker is versioned software downloaded and managed by the Host.

There is no separate Plugin concept in v4.

A Worker package declares:
- Worker ID and version;
- publisher;
- supported OS/architecture;
- protocol version;
- capabilities;
- permissions;
- credential requirements;
- configuration schema;
- supported session modes;
- concurrency behavior;
- package digest/signature;
- entrypoint.

One Worker package is installed once per Host/version and may serve many users, Credential Profiles, Projects, and concurrent assignments.

### 3.5 Credential Profile

A Credential Profile represents one usable account/credential identity for a Worker.

Examples:
- Vitalii's Codex subscription;
- Alice's Codex subscription;
- Vitalii's OpenAI API key;
- Conclave Team OpenAI account;
- local Ollama profile with no secret.

Credential Profiles solve the multi-user shared-Host problem.

A Credential Profile has:
- owner type: user or workspace;
- owner ID;
- Workspace;
- Worker ID;
- Host scope when credentials are stored locally;
- display name;
- auth type;
- secret storage location;
- auth/readiness state;
- sharing policy;
- optional usage/concurrency limits;
- optional provider metadata.

The secret itself is not exposed to other users.

Default policy:

> **Personal Credential Profiles are private to their owner.**

A user may explicitly grant use to:
- selected users;
- a Workspace;
- selected Workspace roles.

A Workspace may own a shared Credential Profile directly.

### 3.6 Assignment

An Assignment is one concrete execution request sent by Cloud to a Host.

It snapshots:
- Workspace;
- Project/Run/Task/Attempt;
- requesting User;
- Host;
- Worker;
- resolved Worker version;
- Credential Profile;
- model/configuration;
- session policy;
- context/artifact references;
- permissions;
- timeout;
- idempotency key.

Assignments never contain long-lived raw secrets when a local Credential Profile can be referenced instead.

## 4. Simplified execution model

The current v3 model:

```text
Agent -> Agent Engine -> Plugin -> configured Worker
```

becomes:

```text
Host -> Worker
```

At execution time:

```text
Task
  -> scheduler resolves Execution Target
       Host
       Worker
       Credential Profile
       effective configuration
  -> Attempt
  -> Assignment
  -> Host
  -> Worker process
  -> external AI/tool
  -> result/evidence
```

An **Execution Target** is an ephemeral resolved value, not a persistent business entity.

## 5. Worker package vs installed Worker

Users see one concept: Worker.

Internally Cloud/Host distinguish:
- **Worker catalog entry** — e.g. `codex`;
- **Worker version** — e.g. `2.4.0`;
- **Host Worker installation** — version installed on one Host.

Do not create persistent configured Worker instances such as "GPT Reviewer" or "Codex Researcher".

Role, model, reasoning level, system instructions, and task-specific options belong to:
- Task;
- Project policy;
- user execution preference;
- Assignment snapshot.

Optional saved execution presets may be added later without changing the core model.

## 6. Multi-user Host model

A Host is a machine identity, not a human login session.

Users authenticate only to Studio/Cloud.

A Host may be bound to one or more Workspaces:

```text
Host: MacBook Pro
  -> Personal Workspace
  -> Conclave Team Workspace
```

Cloud authorization decides whether a user may:
- see the Host;
- schedule work on it;
- install/enable a Worker;
- use a Credential Profile;
- change Host policy.

The Host never signs in as User A or User B and does not need account switching.

### v4 UX default

For simplicity, onboarding initially binds a new Host to one Workspace.

The data model and protocol should support multiple Workspace bindings from the beginning so one machine never needs multiple Conclave installations.

## 7. Credential and sharing model

### 7.1 Local-first secrets

Personal credentials should normally be stored in the Host's platform credential store.

Cloud stores metadata and an opaque local secret reference.

Example:

```text
Credential Profile
  id: cred_vitalii_codex
  owner: user_vitalii
  worker: codex
  host: host_macbook
  secretLocation: local
  localRef: keychain://...
  status: ready
```

The Assignment carries `credentialProfileId`, not the secret.

### 7.2 Cloud-managed secrets

A future encrypted Cloud secret vault may support team/API credentials that need portability across Hosts.

It is not required for the first v4 cutover.

### 7.3 Sharing

Sharing grants permission to **use** a Credential Profile. It never grants permission to reveal/export the secret.

Initial sharing modes:
- private;
- selected users;
- workspace.

Workspace-owned credentials are shared resources controlled by Workspace permissions.

### 7.4 Provider restrictions

Worker metadata may declare credential sharing behavior:
- `private_only`;
- `owner_controlled`;
- `workspace_capable`.

Conclave must not encourage sharing where a provider/account type prohibits it.

### 7.5 Usage attribution

Every metered execution records:
- requesting User;
- Credential Profile;
- credential owner;
- Worker;
- Host;
- provider/model where applicable;
- tokens/cost/duration.

This makes shared-cost accounting possible.

## 8. Session/history isolation

Provider history is different from Conclave project history.

### Conclave history
Belongs to Workspace/Project:
- Chats;
- Tasks;
- Attempts;
- Artifacts;
- Findings;
- final results.

### Provider/Worker session history
Belongs to a Credential Profile and session namespace.

Persistent local Worker state must be namespaced at minimum by:

```text
host / worker / credentialProfile / session
```

A Worker must not reuse User A's provider session for User B unless the Credential Profile itself is explicitly shared and the execution policy allows reuse.

Default for independent research/review is a fresh Worker session.

## 9. Parallel execution

A Worker package may execute multiple Assignments concurrently.

Capacity is constrained by:

```text
effective capacity =
  min(
    Host capacity,
    Worker capacity,
    Credential Profile capacity,
    Workspace policy
  )
```

The Host enforces local capacity and process limits.

Cloud owns queueing and global scheduling.

One Worker binary must not be duplicated merely because several users or Tasks use it simultaneously.

## 10. Worker process model

Worker processes remain separate from the Host process.

This is the principal failure/security boundary.

Recommended default:

```text
Conclave Host process
  -> Assignment A Worker process
  -> Assignment B Worker process
  -> Assignment C Worker process
```

A Worker package may declare a persistent-runtime mode if required by browser/session integrations, but per-assignment processes are preferred because they simplify:
- cancellation;
- isolation;
- resource accounting;
- credential scoping;
- crash containment.

The Host acts as a supervisor:
- start;
- monitor;
- cancel;
- kill process tree;
- collect bounded logs;
- enforce permissions;
- restart only when policy allows.

## 11. Desired-state reconciliation

Studio/Cloud should manage the desired Worker state.

Users should not manually download Worker packages.

Example:

```text
User chooses Codex on Host A
  -> Cloud desired state requires Worker "codex"
  -> Host notices missing Worker
  -> downloads signed package
  -> verifies
  -> installs
  -> health checks
  -> reports ready
```

If no Workspace needs an installed Worker, Cloud may mark it removable and Host may garbage-collect it according to retention policy.

This desired-state controller is intentionally small; do not build a generic Kubernetes-style subsystem.

## 12. Worker selection and orchestration

Task requirements are capability-oriented.

Example:

```text
role: reviewer
requiredCapabilities:
  - code_review
  - repository_read
qualityPolicy:
  independentProvider: true
```

Scheduler resolves eligible Execution Targets using:
- Host online state;
- Worker availability/version;
- required capabilities;
- user's Credential Profile grants;
- provider/model independence;
- concurrency;
- cost/budget;
- Workspace policy;
- user override;
- session policy.

The user may choose:
- **Auto** — Conclave chooses;
- a specific Worker/model/account;
- a quality preset that requests multiple candidates.

The scheduler must not depend on provider-specific branching.

## 13. Multi-worker orchestration

The existing modes remain useful:
- single;
- parallel;
- synthesize;
- compare-and-select;
- competitive implementation.

Rename "multi-agent" concepts to "multi-worker".

Candidate identity should be based on the resolved execution snapshot:

```text
Host + Worker + Credential Profile + provider/model + session
```

Independence policy should distinguish:
- same model, different account;
- same provider, different model;
- different provider;
- different session;
- different Host.

Do not treat different Host IDs alone as intellectual independence.

## 14. Studio UX v4

Studio is chat-first.

Primary navigation:

```text
Workspace
  + New chat

Projects
  Project A
    Chat 1
    Chat 2
  Project B
    Chat 1

Execution
  Hosts
  Workers
  Accounts

Settings
```

### 14.1 Hosts

Hosts view shows:
- machine name;
- online/offline;
- OS;
- version;
- current load;
- installed Workers;
- Workspace bindings;
- last seen;
- update state.

Primary action: **Add Host**.

Pairing flow:
1. User selects Workspace.
2. Studio creates one-time pairing code/link.
3. User installs/opens Conclave Host.
4. Host accepts pairing.
5. Cloud creates Host binding.
6. Studio shows Host online.

### 14.2 Workers

Workers view is a catalog, not a list of configured instances.

Example cards:
- Codex;
- Claude Code;
- OpenAI;
- Anthropic;
- Ollama.

Each card shows:
- available Hosts;
- installation/readiness;
- supported capabilities;
- connected accounts;
- models where discoverable.

Primary action:
- **Use Worker** or **Connect account**.

Installation is automatic.

### 14.3 Accounts

User-facing name: **Accounts**.

Backend/domain name: **Credential Profiles**.

Examples:
- Vitalii Codex — Private;
- Team OpenAI — Workspace;
- Alice Claude — Private.

Account page shows:
- owner;
- Worker;
- Host;
- auth state;
- sharing;
- usage;
- concurrency/rate limits;
- revoke/re-authenticate.

Never display stored secret values after setup.

### 14.4 Chat execution controls

Default composer state:

```text
Execution: Auto
Quality: Balanced
```

Advanced popover may choose:
- Worker;
- model;
- Account;
- Host;
- quality/parallel candidates;
- cost ceiling.

Do not force these controls into every request.

### 14.5 Run progress

Main Chat shows concise progress:

```text
Research     2/2
Plan         complete
Implementation running
Review       waiting
```

Raw Worker logs and inter-worker messages stay in Run details.

### 14.6 Responsive design

Studio must be adaptive:
- wide screen: project/chat sidebar + conversation + optional details;
- medium: collapsible sidebar;
- narrow/mobile: single-column navigation with sheets/drawers.

Build for keyboard, mouse, touch, screen readers, and browser refresh/reconnect.

## 15. Host UX v4

Host UI is intentionally small.

Suggested sections:
- Status;
- Accounts requiring local action;
- Local permissions/repositories;
- Logs;
- Settings.

Do not duplicate:
- Projects;
- Chats;
- Workspace membership management;
- Run orchestration;
- Worker catalog management.

Normal Worker installation/update/removal is remote desired-state behavior.

The Host may surface local-only actions such as:
- authenticate Codex/Claude;
- grant filesystem permission;
- allow repository;
- confirm sensitive local permission;
- stop Host.

## 16. Modern implementation patterns

### 16.1 Control plane / execution plane

Cloud is the control plane.

Hosts/Workers are the execution plane.

Never mix provider execution into Cloud domain services.

### 16.2 Hexagonal boundaries

Core domain depends on ports/interfaces, not Cloudflare/D1/Flutter/provider implementations.

Examples:
- HostRegistry;
- WorkerCatalog;
- CredentialProfileRepository;
- AssignmentDispatcher;
- ArtifactStore;
- UsageRecorder.

Infrastructure implements these ports.

### 16.3 Functional core, imperative shell

Keep scheduling/state-transition logic deterministic and testable.

Put I/O at boundaries:
- database;
- WebSocket;
- R2;
- Host process;
- Worker process.

### 16.4 State machines

Explicit state machines for:
- Run;
- Task;
- Attempt;
- Assignment;
- Host;
- Worker installation;
- Credential Profile auth state.

Reject illegal transitions rather than relying on UI conventions.

### 16.5 Schema-first protocols

One canonical schema source generates/validates TypeScript and Dart protocol models.

No manually duplicated Cloud/Host protocol objects.

### 16.6 Desired-state reconciliation

Cloud declares desired Host Worker state.

Host reconciles actual state idempotently.

Every operation must be retry-safe.

### 16.7 Supervisor pattern

Host supervises Worker child processes.

Worker crashes must not crash Host.

### 16.8 Immutable execution snapshots

Attempts/Assignments snapshot:
- Worker version;
- Credential Profile identity;
- model/config;
- permissions;
- context/artifact references;
- policy.

Later config changes must not rewrite historical execution.

### 16.9 Capability-based security

Workers request explicit permissions.

Assignments grant only the permissions needed for that Task.

Credential secret exposure is scoped to one Worker execution.

### 16.10 Event/audit trail without full event sourcing

Keep durable events for:
- orchestration;
- assignment transitions;
- security changes;
- sharing;
- updates.

D1 relational state remains the primary read/write model. Do not force the whole product into event sourcing.

### 16.11 Bounded AI context

Do not send complete Chat history automatically.

Context assembly uses:
- current request;
- accepted decisions;
- relevant artifacts;
- Project instructions;
- explicit references;
- compact summaries.

### 16.12 AI proposes, deterministic Core decides

AI Workers may propose:
- plans;
- Task decomposition;
- selections;
- findings.

Core validates:
- permissions;
- schema;
- budgets;
- transitions;
- completion;
- evidence.

## 17. Technology stack

### Studio
- Flutter/Dart;
- Web only for v4;
- Cloud API only.

### Cloud
- TypeScript;
- Cloudflare Workers;
- Workflows;
- D1;
- R2;
- Durable Objects with WebSocket hibernation for Host connectivity.

### Host
- Flutter/Dart desktop application;
- shared Dart runtime/services;
- no separate Agent Engine process.

### Workers
- language-independent executable packages;
- Dart preferred for first-party Workers when practical;
- TypeScript/Rust/Python/Go allowed where ecosystem value justifies it;
- structured Worker protocol over stdin/stdout or another explicitly versioned local transport.

## 18. Target repository layout

```text
apps/
  studio/                 # Flutter Web
  cloud/                  # TypeScript / Cloudflare
  host/                   # Flutter + Dart desktop Host

packages/
  core/                   # pure TS domain
  orchestration/
  persistence/
  security/
  protocol/               # canonical schemas + generated TS
  worker-manifest/
  dart/
    protocol/             # generated Dart protocol
    worker_protocol/
    host_runtime/         # reusable Dart runtime services if needed

workers/
  codex/
  claude_code/
  openai/
  anthropic/
  echo/
  forge/
```

Avoid package proliferation. Add a package only when it has a real ownership/reuse boundary.

## 19. Target data model

Core v4 execution tables:

```text
hosts
host_workspace_bindings
host_enrollments
host_sessions
host_releases

workers
worker_versions
host_worker_installations

credential_profiles
credential_grants

attempts
worker_assignments
usage
```

Remove v3 configured Worker-instance tables and terminology.

### hosts

One machine identity.

### host_workspace_bindings

Many-to-many Host/Workspace authorization.

Allows one installed Host to serve personal and team Workspaces.

### workers

Global/catalog Worker definition.

Examples: `codex`, `openai`.

### worker_versions

Signed distributable versions.

### host_worker_installations

Actual installed version/status on a Host.

### credential_profiles

User/workspace account metadata and secret reference.

### credential_grants

Who may use a Credential Profile.

### worker_assignments

Resolved Host + Worker + Credential Profile + execution snapshot.

## 20. Security invariants

1. A Host never authenticates as a human User.
2. A Host receives Assignments only for bound Workspaces.
3. A user can schedule on a Host only through Cloud authorization.
4. A Credential Profile is private by default.
5. Sharing grants use, never secret disclosure.
6. Worker processes receive only secrets explicitly required for their Assignment.
7. Provider session state is isolated by Credential Profile.
8. Cloud never executes external AI/provider work.
9. Worker packages must be signed/verified before activation.
10. Every Assignment is idempotent and auditable.

## 21. Architecture summary

The v4 mental model should fit in one sentence:

> **Conclave Cloud coordinates work; Studio lets people control it; Hosts provide machines; Workers connect those machines to AI and tools; Credential Profiles decide whose account is used.**
