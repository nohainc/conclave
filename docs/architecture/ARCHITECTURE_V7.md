# Conclave AX Architecture v7 — Local Worker Runtime and Adapter Execution

**Status:** Current architecture and active implementation target. V7 ownership, scheduler, E2E path, V6 compatibility retirement, and public-key release trust are implemented; production runtime gates remain open.
**Date:** 2026-09-26  
**Builds on:** Architecture v6 Workstreams + ADR-011 filesystem model  
**Primary decision:** [ADR-012](../decisions/ADR-012-workspace-owned-local-workers.md)

## 1. Executive decision

V7 is the sole current Worker ownership architecture. It is not yet the
implemented baseline: Phase 5 production Worker acceptance, Phase 6 full
failure/security acceptance, and Phase 7 native macOS `.app` updater recovery
remain open. See the [current implementation audit](V7_IMPLEMENTATION_AUDIT.md)
and [release gates](../roadmaps/ARCHITECTURE_V7_COMPLETION.md).

v7 keeps the product model already established by the current application:

~~~text
Conclave AX
  -> Projects
       -> Workstreams
            -> Discuss
            -> Work

Execution
  -> Workspaces
  -> Workers
~~~

The execution implementation becomes simpler and more machine-native:

> **Workers are configured locally on exactly one Conclave Workspace and synchronized to Cloud as safe execution inventory.**

The user installs one machine-side product:

> **Conclave Workspace**

There are no separately installed Worker applications.

Conclave Workspace manages signed Worker adapter packages and launches them as isolated child processes for assignments.

## 2. Product mental model

The complete mental model should fit in four lines:

> **Project** = collaboration boundary.  
> **Workstream** = persistent unit of work and local working directory.  
> **Workspace** = machine where AI can execute.  
> **Worker** = locally configured AI/tool identity on that machine.

The user does not need to understand:
- Worker packages;
- adapter protocol;
- credential profiles;
- AI Accounts;
- package desired state;
- Worker Workspace bindings.

## 3. Product topology

~~~text
                         CONCLAVE AX
                             |
                             v
                       CONCLAVE CLOUD
                             |
                    secure Workspace Gateway
                             |
               +-------------+-------------+
               |                           |
               v                           v
       Conclave Workspace A        Conclave Workspace B
          MacBook Pro                    Mac Mini
               |                           |
       +-------+--------+              +---+---+
       |       |        |              |       |
     Codex  Gemini API Claude        Codex  Ollama
   Personal   Work     Review         Build   Local
~~~

Each configured Worker exists on one Workspace only.

## 4. Application boundaries

### 4.1 Conclave AX

Conclave AX is the **web application** and human orchestration/control surface. It is not the machine executor and it does not configure provider credentials locally.

It owns UX for:
- authentication;
- Projects;
- Workstreams;
- Discuss;
- Work;
- execution inventory;
- Project/Workspace Grants;
- Worker eligibility/selection;
- remote enable/disable/drain controls;
- results/audit/artifacts;
- Workspace downloads/onboarding.

It does not own provider secrets.

### 4.2 Conclave Cloud

Cloud is the authoritative collaboration/orchestration control plane.

It owns:
- users and Project membership;
- Workstreams;
- Work Requests/Workflows/Runs;
- Workspace registrations/grants;
- synchronized Worker inventory projection;
- Worker authorization and scheduler eligibility;
- assignment snapshots;
- durable coordination;
- audit/artifacts;
- Workspace Gateway.

Cloud does not execute an external AI/tool directly.

### 4.3 Conclave Workspace

Conclave Workspace is the **desktop application/runtime** installed on the execution computer. It is the persistent local execution/security boundary. All configured Workers are created/authenticated here.

It owns:
- pairing;
- one machine runtime identity;
- local Work Root;
- Workstream directory resolution;
- configured Worker local registry;
- local credentials;
- Worker adapter package lifecycle;
- adapter/tool prerequisite checks;
- local permissions;
- child-process execution/supervision;
- cancellation/process-tree termination;
- local logs/diagnostics;
- runtime and adapter updates;
- sync of safe Worker metadata/readiness to Cloud.

### 4.4 Worker adapter

A Worker adapter is signed integration code managed by Conclave Workspace.

It owns translation between the Conclave assignment protocol and one external execution technology.

Examples:
- Codex adapter;
- Antigravity adapter;
- Claude Code adapter;
- OpenAI API adapter;
- Gemini API adapter;
- Anthropic API adapter;
- Ollama adapter.

Adapters are infrastructure, not separately installed product apps.

## 5. Workspace lifecycle

### 5.1 Create

Conclave AX asks only for Workspace name.

Do not ask the user for platform.

~~~text
Add Workspace
Workspace name: [MacBook Pro]
~~~

### 5.2 Connect

Workspace exists in Cloud as Not connected.

User chooses **Connect machine**, receives an enrollment code, installs/opens Conclave Workspace and pairs it.

### 5.3 Runtime reports machine facts

After pairing, Workspace reports:
- OS;
- architecture;
- hostname;
- Conclave Workspace version;
- runtime capabilities;
- connection/readiness.

Machine facts are observed runtime state, not user configuration.

### 5.4 Downloads

The canonical download surface remains a dedicated Downloads page.

Contextual links may appear:
- Workspaces empty state;
- Connect machine flow;
- global app menu;
- Workspace update prompt.

### 5.5 Pairing protocol

The web application creates a one-time `workspace_enrollments` code.

Conclave Workspace redeems it through:

~~~text
POST /api/workspace-runtime/enroll
~~~

Cloud returns:
- Workspace Runtime ID;
- Workspace ID/name;
- one runtime bearer token.

The desktop app stores the bearer token only in the OS secure credential store and writes only non-secret registration metadata to disk. It then opens:

~~~text
/api/workspace-gateway/connect?workspaceRuntimeId=<runtime-id>
~~~

and authenticates with the bearer token.

The first successful `workspace.hello` establishes the live session and publishes real machine facts and Worker inventory.

### 5.6 macOS distribution

macOS is the first desktop release target.

The supported repository build entrypoint is:

~~~text
bash scripts/build-workspace-macos.sh
~~~

The script:
- resolves Flutter dependencies;
- runs analyze/tests unless explicitly skipped;
- builds the native release app;
- injects the Workspace version;
- optionally signs with a Developer ID identity and hardened runtime;
- optionally notarizes with Apple;
- produces a ZIP under `dist/conclave-workspace/macos`.

Conclave Workspace is distributed directly rather than through Mac App Store sandboxing because it must execute local CLI/tool child processes and operate in persistent Workstream directories.

A real Cloud smoke procedure is available through:

~~~text
CONCLAVE_ENROLLMENT_TOKEN=... bash scripts/test-workspace-cloud-connection.sh
~~~

Use a disposable Workspace because the test consumes a real one-time enrollment and establishes a real runtime identity.

## 6. Conclave Workspace UI

Conclave Workspace is background-first with a minimal GUI.

### 6.1 Before pairing

~~~text
Conclave Workspace

Connect to Conclave AX
Pairing code: [________]

[Connect]
~~~

### 6.2 Main local view

~~~text
Conclave Workspace

MacBook Pro
● Connected

Workers
Codex Personal       Ready
Antigravity Personal Ready
OpenAI API Work      Authentication required

[+ Add Worker]

Current work
Authentication · Codex Personal · Running

Machine
Work Root   ...
Version     ...
~~~

### 6.3 Local-only areas

Recommended:
- Overview;
- Workers;
- Permissions;
- Diagnostics;
- Settings/Updates.

Do not replicate Projects/Workstreams/Work UI.

### 6.4 Background/tray behavior

Desktop builds should continue execution when the main window is closed.

Tray/menu-bar controls may include:
- connection status;
- current work;
- pause accepting new work;
- open Conclave Workspace;
- open Conclave AX;
- logs;
- quit.

## 7. Worker resource model

### 7.1 Configured Worker

A configured Worker contains safe logical/local fields:

~~~text
id
workspaceId
name
workerTypeId
authStrategy
credentialRef (local only)
defaultModel
allowedModels
capabilities
localPermissions
localConcurrencyLimit
status
adapterVersion
createdAt
updatedAt
~~~

Cloud stores only the safe projection.

### 7.2 Cardinality

~~~text
Workspace 1 -> N Workers
Worker N -> 1 Workspace
Worker Type 1 -> N Workers
~~~

No configured Worker Workspace-binding table is needed in the target model.

### 7.3 Duplicate names

Worker name need not be globally unique.

Recommended uniqueness:
- unique within one Workspace, case-insensitive where practical.

Cloud always uses immutable Worker ID.

## 8. Worker Type / adapter model

Worker Type describes an integration.

Suggested metadata:

~~~text
id
displayName
adapterProtocolVersion
releaseVersion
supportedPlatforms
capabilities
authStrategies
modelSelectionMode
permissions
prerequisites
publisher
packageDigest
signature
releaseChannel
~~~

### 8.1 Tool-backed types

Examples:
- Codex;
- Antigravity;
- Claude Code.

Adapter may invoke a locally installed provider tool.

Manifest declares:
- executable prerequisite;
- supported versions;
- detection command;
- auth/setup support;
- execution/cancellation behavior.

### 8.2 API-backed types

Examples:
- OpenAI API;
- Gemini API;
- Anthropic API.

Adapter directly communicates with provider API.

API credentials remain in local secure storage.

### 8.3 Local-model types

Examples:
- Ollama;
- LM Studio;
- vLLM endpoint.

Same Worker protocol; no Cloud architecture change.

### 8.4 Worker Type naming rule

Name a Worker Type after the execution integration that Conclave invokes.

- **Codex** invokes Codex CLI. A user may authenticate Codex with a **ChatGPT account**. Do not call this a ChatGPT adapter.
- **Antigravity** invokes Google Antigravity CLI, whose executable is `agy`. It may use a Google-account subscription/session. Do not rename it Gemini merely because its model family is Gemini.
- **Gemini API** means direct Gemini API integration.
- A future distinct **Gemini CLI** integration may be added as its own Worker Type if Conclave explicitly supports that product.

Subscription/account brand, Worker Type and model are separate concepts.

## 9. Model selection

Model is not Worker Type.

A configured Worker may use:
- fixed model;
- default model + allowed set;
- provider/tool Auto mode.

An Assignment may request a model.

Effective model must satisfy:

~~~text
Assignment request
∩ configured Worker allowed models
∩ adapter/tool capabilities
~~~

If no model is explicitly requested, use configured Worker default/Auto.

## 10. Local Worker creation

### 10.1 Add Worker

Flow:

~~~text
Workers
-> Add Worker
-> choose Worker Type
-> name
-> prerequisite check
-> authenticate/connect
-> model/defaults
-> local permissions
-> validate
-> create
-> sync safe projection
~~~

### 10.2 Authentication

Auth is adapter-defined but local.

Possible strategies:
- provider browser login;
- cached subscription session;
- API key;
- local session token;
- no credential/local endpoint.

Cloud receives only:
- strategy label;
- readiness;
- safe provider/account hint if permitted.

### 10.3 Permission approval

Local user approves machine-sensitive permissions.

Cloud cannot broaden them.

## 11. Cloud Worker projection

Cloud stores enough Worker data to schedule safely without owning secret configuration.

Suggested projection:

~~~text
workerId
workspaceId
ownerUserId
name
workerTypeId
status
capabilities
supportedModels / model policy summary
localPermissionSummary
localConcurrencyLimit
adapterVersion
credentialStatus
lastSeenAt
revision
~~~

Workspace sends idempotent upsert/tombstone events.

Cloud rejects inventory updates from any runtime other than the Worker's owning Workspace.

## 12. Synchronization model

### 12.1 Local -> Cloud inventory

Workspace is authoritative for existence/local configuration/readiness.

Sync triggers:
- Worker created;
- Worker edited;
- credential state changed;
- adapter updated;
- permissions changed;
- Worker removed;
- periodic reconciliation;
- reconnect.

### 12.2 Cloud -> local operational policy

Cloud may synchronize:
- scheduling enabled/disabled;
- drain state;
- Project/Workstream authorization context;
- assignment;
- cancellation;
- local-action request such as reauthenticate/update attention.

Cloud policy may narrow local Worker ability, never broaden it.

Cloud persists a separate scheduling state (`enabled`, `disabled`, or
`draining`) for each synchronized Worker. New and migrated inventory starts
disabled. Scheduling requires local `ready` status and ready credentials as
well as Cloud `enabled`; the Cloud control cannot change local credentials,
permissions, ownership, or readiness. Drain rejects new assignments, lets
active assignments finish, and transitions to disabled when a state read
observes that active count has reached zero. The request and completion are
audited with actor and time. A full inventory snapshot is authoritative:
omitted Workers become tombstones and are disabled; a later source revision (or
the same revision after an omission tombstone) may restore an omitted Worker.
Explicit Worker tombstones continue to use strictly increasing source
revisions. Worker IDs remain permanently bound to their first Workspace.

### 12.3 Conflict rule

Split ownership prevents generic last-write-wins.

Local owns local configuration fields.
Cloud owns remote scheduling/authorization fields.

## 13. Scheduler

Scheduler candidate becomes simpler:

~~~text
Configured Worker
-> owning Workspace
-> active Workspace Project Grant
-> Worker synced + ready
-> adapter ready
-> credential ready
-> capability/model compatible
-> local capacity available
-> Cloud scheduling enabled
-> Workstream policy allows Worker
~~~

There is no Workspace-binding search for a configured Worker because Worker already has exactly one Workspace.

For stateful Work:
- Workspace must equal Workstream Primary Workspace.

For stateless Work:
- eligible Worker/Workspace may be selected from granted Workspaces.

## 14. Assignment snapshot

Assignment snapshots include:

~~~text
projectId
workstreamId
workRequestId
runId
configuredWorkerId
workspaceId
workerTypeId
adapterVersion
requested/resolvedModel
capabilities/permissions snapshot
executionClass
lease/fencing data where stateful
~~~

Do not include:
- provider secret;
- arbitrary executable path;
- arbitrary local CWD.

## 15. Execution lifecycle

Default:

~~~text
Cloud assignment
-> Workspace validates
-> resolve Workstream CWD
-> resolve configured Worker
-> verify adapter package/version
-> load only required local credential
-> launch adapter child process
-> adapter invokes API/tool/local model
-> stream progress
-> capture result
-> terminate/cleanup
-> report completion
~~~

One assignment child process is default.

## 16. Adapter process protocol

Prefer structured stdin/stdout protocol.

Initial protocol messages:
- initialize;
- validate;
- execute;
- progress;
- result;
- error;
- health/version.

Cancellation is enforced by the Workspace process supervisor. Interactive
request/response input is deferred until a supported adapter requires it; add it
through an explicit versioned protocol extension rather than implying that the
initial V7 schema already supports it.

Protocol must include:
- schema version;
- assignment ID;
- bounded payload sizes;
- explicit result contract.

Do not scrape interactive terminal UI when a supported machine-readable/headless mode exists.

## 17. Process isolation

Workspace runtime supervises adapter/tool process trees.

Requirements:
- explicit CWD;
- minimal environment;
- scoped secret injection;
- no inherited secret environment by default;
- stdout/stderr limits;
- timeout;
- graceful cancel then forced kill;
- process-group/tree termination;
- temp-file cleanup;
- exit status normalization.

A crashed adapter must not disconnect the Workspace runtime.

## 18. Workstream working directory

ADR-011 remains unchanged:

~~~text
<work-root>/<project-id>/<workstream-id>/
~~~

All Workers on one Workspace assigned to the same Workstream see the same directory.

Different Workstreams are isolated and may run in parallel.

Workers manage repositories inside the directory.

## 19. Concurrency

Two separate limits exist:

### Workspace capacity

Machine-wide total active executions.

### Worker local concurrency ceiling

Maximum simultaneous assignments for one configured Worker.

Cloud may set a lower scheduling limit but cannot exceed local ceiling.

Stateful Workstream mutation lock is an additional independent constraint.

## 20. Remote controls in Conclave AX

### Workers inventory

Show:
- Worker name;
- Worker Type;
- owning Workspace;
- readiness;
- adapter/tool status;
- credential attention;
- current active work;
- scheduling state.

### Allowed actions

Initial:
- open Worker details;
- enable/disable scheduling;
- drain;
- inspect capabilities/status;
- request local reauthentication;
- navigate to owning Workspace;
- use in Project/Workstream policy.

### Not allowed initially

- enter/change provider secret;
- approve new local permissions;
- silently remove local credential;
- silently change prerequisite tool installation.

Worker removal is local-first; Cloud may support a remote removal request later with explicit local confirmation.

## 21. Worker details in Conclave AX

Recommended sections:
- Overview;
- Workspace;
- Activity/Audit;
- Scheduling.

Remove multi-Workspace binding UX.

Connection/authentication details are informational:
- Ready;
- Needs authentication;
- Needs local attention.

Action copy should say:
> Complete in Conclave Workspace on MacBook Pro.

## 22. Project/Workstream authorization

Worker authorization remains Cloud-controlled.

Project policy may allow:
- any eligible Worker on granted Workspace;
- explicit Worker IDs;
- Worker Types;
- models/capabilities.

Workstream policy can narrow Project policy.

Because a Worker has one Workspace, authorization is easier to reason about.

## 23. Security boundary

Conclave Workspace is the local authority.

Cloud can request execution but local runtime verifies:
- owning Worker;
- Workspace grant context;
- adapter signature/version;
- local readiness;
- permissions;
- CWD containment;
- Workstream lease/fencing;
- credential availability.

No Cloud instruction can override local trust boundaries.

## 24. Updates

Three update layers:

### Conclave Workspace app
Normal signed application update.

### Worker adapter package
Managed inside Conclave Workspace with signature/digest verification and rollback.

The signature covers both the file-tree digest and the canonical manifest
without its signature field. Workspace checks downloaded catalog metadata
against the archived manifest, then verifies signature, permissions, platform,
and health before atomic activation. Cloud stores versioned release metadata
and archives but does not grant execution trust.

### Third-party tool
Provider-owned lifecycle unless Conclave intentionally takes ownership.

UI must distinguish these.

## 25. Failure behavior

### Cloud offline
Workspace does not accept new Cloud work; running assignment follows explicit connection-loss policy.

### Workspace offline
Cloud stops scheduling it.

### Adapter crash
Assignment fails/retries according to Workflow; Workspace remains online.

### Credential expiry
Worker becomes Needs authentication; other Workers remain eligible.

### Tool missing/outdated
Worker becomes Needs attention.

### Adapter update failure
Keep previously verified active version where safe.

## 26. Data ownership summary

| Data | Authority |
| --- | --- |
| Project/Workstream | Cloud |
| Workspace registration | Cloud |
| Work Root/files | local Workspace |
| configured Worker existence/config | local Workspace |
| Worker safe inventory projection | Cloud replica |
| provider secret | local Workspace secure store |
| adapter catalog/release metadata | Cloud |
| adapter installed state | local Workspace |
| scheduling enable/drain (target; controls incomplete) | Cloud |
| Project/Workstream Worker authorization | Cloud |
| local permission ceiling | local Workspace |
| Run/Assignment/audit | Cloud |

## 27. Migration from v6 configured Workers

This section records the migration rationale and target mapping. The Phase 3
forward migration and runtime/API retirement are complete; it is not a
compatibility design for current runtime code. Current behavior is defined by
the sections above and ADR-012.

Current v6:
- configured Worker is Cloud-created;
- Worker may bind to multiple Workspaces;
- credential/readiness is per binding.

v7 target:
- configured Worker is local-created;
- Worker has exactly one Workspace;
- credential/readiness is direct local Worker state.

Pre-production migration preference:
- clean dev schema/reset where practical;
- do not preserve multi-Workspace binding complexity as permanent compatibility architecture.

Temporary migration may convert each current Worker/Workspace binding into one local-style Worker projection.

## 28. Non-goals for initial v7

Do not initially build:
- separate Worker desktop apps;
- persistent Worker daemons;
- hardware fingerprinting;
- Cloud secret vault for provider credentials;
- universal generic adapter for every provider;
- automatic third-party tool redistribution;
- Source/repository registry;
- usage/cost accounting;
- remote destructive credential removal;
- Kubernetes/container orchestration.

## 29. Acceptance mental model

A new user should be able to understand:

~~~text
Install Conclave Workspace on a computer.
Add/authenticate Workers on that computer.
Conclave AX discovers those Workers.
Use them from Projects and Workstreams.
~~~

No additional infrastructure vocabulary should be required.


## 30. Implementation audit and release gates

The current source-level convergence is tracked in [V7 Implementation Audit](V7_IMPLEMENTATION_AUDIT.md).

Do not declare v7 production-complete until:
- desktop pairing + Workspace Gateway smoke succeeds against the target Cloud;
- signed/notarized macOS build passes;
- at least one real Codex and one real Antigravity execution succeed from locally configured Workers;
- legacy Cloud-created/multi-Workspace Worker execution is no longer required;
- adapter package verification no longer requires shipping the signing secret and uses asymmetric public-key trust.


## Completion plan

See [Architecture v7 Completion Plan](../roadmaps/ARCHITECTURE_V7_COMPLETION.md) for the remaining convergence and release gates.
