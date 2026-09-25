# Conclave AX Architecture v7 — Local Worker Runtime and Adapter Execution

**Status:** Proposed next architecture  
**Date:** 2026-09-26  
**Builds on:** Architecture v6 Workstreams + ADR-011 filesystem model  
**Primary decision:** [ADR-012](../decisions/ADR-012-workspace-owned-local-workers.md)

## 1. Executive decision

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

Conclave AX is the human orchestration/control application.

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

Conclave Workspace is the persistent local execution/security runtime.

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

Minimum messages:
- initialize;
- execute;
- progress;
- request-input where supported;
- result;
- error;
- cancel/termination semantics;
- health/version.

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
| scheduling enable/drain | Cloud |
| Project/Workstream Worker authorization | Cloud |
| local permission ceiling | local Workspace |
| Run/Assignment/audit | Cloud |

## 27. Migration from v6 configured Workers

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
