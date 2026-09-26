# Architecture v7 — Workspace-Owned Workers Implementation Roadmap

**Status:** In progress
**Architecture:** [ARCHITECTURE_V7.md](../architecture/ARCHITECTURE_V7.md)  
**Decision:** [ADR-012](../decisions/ADR-012-workspace-owned-local-workers.md)  
**Date:** 2026-09-26

## Implementation status

- [x] V7-0 — v7 vocabulary/ownership is the active direction; the existing v6 execution path remains in service during migration. A source guard rejects newly added v6-style binding UX, Cloud Add Worker flows, AI Account peer resources, and model-specific Worker Types.
- [x] V7-1 — additive canonical v7 Worker and Worker Type contracts are available in `@conclave/core`; the legacy v6 contracts remain intact during migration. Contract checks cover Workspace ownership, name uniqueness scope, integration/model distinction, and immutable IDs.
- [~] V7-2 — local Workspace-scoped Worker registry with schema version 4, checksum verification, atomic replacement, revisioned mutations, lifecycle operations, credential-free removal tombstones, and credential-reference-free backup export. Cloud user attribution is not fabricated in local state.
- [~] V7-3 — local Add Worker catalog/form is wired into Conclave Workspace; existing Worker configuration can be edited, API credentials can be retained or rotated securely, and local disable/remove actions are available. Codex and Antigravity check their respective CLI and Node launcher prerequisites and offer local sign-in validation; Claude Code and Ollama executables are also checked. OpenAI/Gemini/Anthropic API credentials are verified through their admitted adapter's model-list request before the Worker is marked Ready. Fresh Workspaces still need API adapter releases published to Cloud; Ollama execution adapter remains.
- [~] V7-4 — strict v7 adapter manifest and bounded structured protocol schemas are defined with path checks; publisher signatures bind both the canonical file-tree digest and every manifest field other than the signature. The Host enforces platform and machine/Worker permission ceilings, resolves package-contained executables, and creates scoped process specs. The production resolver loads active packages from the Workspace-owned V7 store, looks up credentials only in the OS secure store, and dispatches V7 assignments through the framed executor. Staged installs run the declared protocol/process-exit health check before atomic activation, and rollback re-verifies and health-checks a selected installed version. The store extracts bounded gzip-compressed tar archives with traversal, link, duplicate-path, expanded-size, and catalog-manifest consistency checks before normal verification. Cloud provides owner-authorized immutable V7 release publishing, platform/channel-filtered catalog reads, publisher-scoped revocation, and R2 downloads. Add Worker can acquire the latest supported channel release; periodic update/revocation reconciliation remains.
- [~] V7-5 — existing child-process isolation now has a local per-Worker concurrency gate and queued cancellation; the configured Worker registry limit is wired into assignment resolution, and shutdown forces process-tree cleanup after graceful termination. Full acceptance coverage remains.
- [~] V7-7 — first-party Antigravity V7 protocol adapter wraps the local Antigravity CLI using JSONL execution, resolved Workstream CWD, model configuration, and CLI sandboxing. Google-account local authentication status is checked without exposing credentials. The Host package release packager signs, admits, and installs the package archive.
- [~] V7-8 — first-party OpenAI API, Gemini API, and Anthropic API adapters use separate provider implementations behind a shared V7 JSONL runtime. API keys enter only through the Host's scoped secure-credential environment injection, and provider model-list requests validate credentials before generation. Mocked provider tests and signed-package install/health tests pass. Streaming, provider tools, Workspace publication of release packages, and end-to-end scheduled execution remain.
- [~] V7-9 — version 5.1 Workspace Runtime messages carry bounded safe Worker inventory snapshots; Workspace runtime ownership, monotonic per-Worker revisions, and credential-free Cloud tombstones are persisted in an additive table. `/api/v7/workers` exposes an owner-scoped safe inventory projection; the Host reports adapter version and capabilities only from a digest/signature/permission-verified active manifest. The AX Workers tab reads and displays that inventory without credential references and rereads it after a lightweight realtime inventory-updated signal. Runtime reconnect/stale-revision end-to-end acceptance remains.
- [~] V7-14 — scheduler selects candidate Workers directly from synced Workspace inventory alongside legacy bindings during migration. Stateful assignments enforce Primary Workspace affinity and active execution leases, while stateless tasks discover any online, granted Workspace with matching capabilities.
- [~] V7-15 — Cloud Project and Workstream policies explicitly narrow candidate Workers by configured Worker ID, Worker Type, provider, and model without expanding local permissions. Effective permissions are strictly bounded by the intersection of member, grant, and local Worker grants.
- [~] V7-16 — adapter packages are decoupled from individual configured Worker identities. One verified adapter release in the Workspace package store serves all local Workers of that Worker Type with separate scoped credentials and per-Worker concurrency limits.


## Objective

Move Conclave AX from the current v6 configured-Worker model:

~~~text
Cloud creates Worker
Worker -> many Workspace bindings
credentials/readiness -> per binding
~~~

to the v7 model:

~~~text
Conclave Workspace creates Worker
Worker -> exactly one Workspace
credentials/readiness -> direct local Worker state
Cloud receives safe synchronized inventory
~~~

while preserving:
- Project/Workstream authorization;
- Workspace Grants;
- Workstream working directories;
- adapter child-process isolation;
- local credential security;
- current execution reliability.

The migration should land incrementally and keep one executable architecture at each step.

---

# V7-0 — Freeze v7 vocabulary and ownership

## Goal

Prevent new work from extending the v6 multi-Workspace Worker abstraction.

## Freeze

- Conclave Workspace = machine runtime/security boundary;
- configured Worker = one local executable AI/tool identity;
- one Worker belongs to exactly one Workspace;
- Worker Type = adapter/integration definition;
- model = Worker/Assignment configuration;
- provider secrets remain local;
- adapter packages are infrastructure;
- no separate Worker desktop applications;
- Conclave AX discovers/schedules Workers but does not normally create them.

## Source guards

Add source-level checks that reject new:
- Worker -> multiple Workspace binding UX;
- Cloud-side Add Worker wizard;
- AI Account peer resource;
- model-specific Worker Type names.

## Exit

New implementation work can rely on one ownership model.

---

# V7-1 — Canonical v7 domain contracts

## Goal

Introduce a clean domain model before persistence/UI migration.

## Add/reshape core entities

### ConfiguredWorker

Fields:
- id;
- workspaceId;
- ownerUserId;
- name;
- workerTypeId;
- status;
- authStrategy;
- defaultModel;
- allowedModels;
- capabilities;
- localPermissionsSummary;
- localConcurrencyLimit;
- adapterVersion;
- credentialStatus;
- lastSeenAt;
- revision;
- createdAt;
- updatedAt.

### WorkerType

Fields:
- id;
- displayName;
- publisher;
- adapterProtocolVersion;
- capabilities;
- authStrategies;
- modelSelectionMode;
- supportedPlatforms;
- permissions;
- prerequisites;
- currentRelease;
- releaseChannel.

## Remove from canonical model

- Worker Workspace bindings;
- per-binding credential state;
- per-binding package state as product/domain identity.

Those become direct Worker/Workspace-local state.

## Tests

- one Worker -> one Workspace;
- duplicate names allowed across Workspaces;
- duplicate names policy within one Workspace;
- model is not Worker Type;
- immutable Worker ID.

## Exit

Cloud, app, and runtime can share the new conceptual contract.

---

# V7-2 — Workspace-local Worker registry

## Goal

Make Conclave Workspace authoritative for configured Worker existence/configuration.

## Runtime storage

Add a local Worker registry under the Workspace data boundary.

Each Worker record stores:
- Worker ID;
- name;
- Worker Type;
- auth strategy;
- secure credential reference;
- defaults/model policy;
- local permission grants;
- local concurrency ceiling;
- adapter version policy;
- state/revision.

## Requirements

- atomic writes;
- schema versioning;
- corruption detection;
- no plaintext secrets in registry;
- safe backup/restore behavior;
- local ID generation;
- deterministic update revision.

## Lifecycle

Support:
- create;
- edit;
- validate;
- disable locally;
- remove;
- credential-ready/expired state.

## Exit

A Worker can exist locally without first existing in Cloud.

---

# V7-3 — Local Add Worker UX in Conclave Workspace

## Goal

Create the primary local Worker setup flow.

## UI flow

~~~text
Workers
-> Add Worker
-> choose Worker Type
-> Worker name
-> prerequisite validation
-> authentication
-> model/defaults
-> permissions
-> validate
-> create
~~~

Local inventory rows also provide disable/enable and remove actions. Removing
a Worker requires confirmation and removes its referenced credential from the
machine secure store.

## Worker Type selection

Show user-facing types:
- Codex;
- Antigravity;
- Claude Code;
- OpenAI API;
- Gemini API;
- Anthropic API;
- supported local model adapters.

Do not expose package/version jargon in the normal flow.

## Auth UX

Adapter-defined local steps:
- browser/account sign-in;
- API key;
- local endpoint;
- no-auth.

## Permission UX

Show clear local machine permissions before creation.

## Validation

Worker cannot become Ready until:
- adapter available;
- prerequisite satisfied;
- auth ready if required;
- permission ceiling satisfied.

## Exit

A user can configure a complete Worker locally without opening Conclave AX.

---

# V7-4 — Adapter SDK and manifest v7

## Goal

Formalize Worker Type as an adapter contract.

## Manifest

Define:
- workerTypeId;
- adapter version;
- protocol version;
- publisher;
- supported platforms/architectures;
- capabilities;
- permissions;
- auth strategies;
- model selection mode;
- prerequisites;
- executable;
- launch args;
- secret requirements;
- health check behavior.

## Prerequisites

Support declarative detection:
- executable name/path policy;
- minimum/maximum supported version;
- detection command;
- install-help URL/message.

Do not allow manifest to redirect to arbitrary executables outside verified package boundaries.

The Host prerequisite probe accepts command names only, launches without a
shell, passes only a small runtime environment, bounds version output and
execution time, and enforces declared semantic version ranges. Local setup
invokes it for catalog-declared Codex, Claude Code, and Ollama CLI executables.
Manifest admission now parses prerequisite declarations using the same Host
policy, although Add Worker still reads the temporary built-in catalog.
Ollama endpoint reachability and the Antigravity executable check remain
outstanding.

## Protocol

Structured stdin/stdout:
- initialize;
- validate;
- execute;
- progress;
- result;
- error;
- health/version.

The Host executor implements these messages with bounded output, the shared
local Worker concurrency gate, process-tree cancellation, and secret redaction.
`WorkerAssignmentHandler` resolves active V7 adapters from the Workspace-owned
package store and dispatches them through the V7 executor; assignments for
Workers outside the local registry keep the v6 JSON-RPC path. Workstream CWD
resolution, local permission checks, and stateful mutation locks wrap either
path. Staged installs run the declared health handshake before activation, and
rollback re-verifies and health-checks the selected installed version. The
installer accepts pre-extracted local directories and bounded gzip tar
archives. Cloud now provides immutable V7 adapter release publication, catalog
filtering, publisher-scoped revocation, and R2 downloads. Add Worker fetches a
supported release, checks the archive SHA-256 and exact catalog manifest, and
installs through the signed package store. Periodic update/revocation
reconciliation and first-party adapter coverage remain to be completed.

## Exit

Codex/API/local-model adapters can share one stable contract.

---

# V7-5 — Per-assignment adapter process execution

## Goal

Make separate child processes the default execution boundary.

## Runtime flow

~~~text
Assignment
-> resolve Worker
-> resolve adapter
-> validate adapter package
-> resolve Workstream CWD
-> inject scoped credential/environment
-> launch child process
-> supervise
-> stream progress/result
-> terminate/cleanup
~~~

## Isolation

- explicit CWD;
- bounded env;
- secret allowlist;
- stdout/stderr limits;
- timeout;
- graceful cancel;
- forced process-tree termination;
- temp cleanup;
- crash containment.

## Concurrency

Each assignment process is independent. `WorkerProcessExecutor` enforces a per-Worker local concurrency limit (default 1) and queues additional assignments; cancellation also removes queued work before it launches. Assignment resolution supplies the configured Worker limit, capped by the executor's local safety ceiling.

POSIX cancellation discovers and signals descendants explicitly, preserving the
descendant PID set through graceful shutdown so the forced-kill pass can still
terminate children after the adapter exits. An acceptance test runs a nested
process that writes a heartbeat and verifies that cancellation stops it.

Persistent processes are not part of initial v7.

## Tests

- adapter crash leaves Workspace online;
- cancel kills full child tree;
- two Workers run concurrently;
- same Worker respects local concurrency;
- stateful Workstream lock still serializes mutation.

## Exit

Workspace process is stable while adapter execution is isolated.

---

# V7-6 — First-party Codex adapter

## Goal

Prove subscription-backed tool integration.

## Responsibilities

- detect Codex CLI;
- validate supported version;
- detect/authenticate local ChatGPT-backed session;
- execute in headless/non-interactive supported mode;
- pass Workstream CWD;
- normalize output/progress/errors;
- support cancel;
- report model capability/selection where available.

## UX

Local Worker example:

~~~text
Codex Personal
Type: Codex
Authentication: ChatGPT
Status: Ready
~~~

## Security

- do not copy provider session token into Cloud;
- do not log raw session data;
- use provider-supported local auth store.

The first-party Codex V7 protocol adapter now wraps the local Codex CLI using
JSONL execution, the resolved Workstream CWD, locally selected models, and the
CLI workspace-write sandbox. It checks the local subscription session through
`codex login status`, emits only sanitized progress, and leaves provider tokens
in Codex's local auth store. Protocol tests use a fake CLI and make no live model
request. Conclave Workspace now offers a local `codex login` action and checks
`codex login status` when saving a Worker, recording only local authentication
readiness. The Worker remains in Needs attention until an admitted adapter is
installed. Host assignment resolution and the Add Worker readiness check now
share the same package store; the UI checks the active package's digest,
signature, platform, permissions, and protocol health before treating it as
available. Cloud now hosts owner-authorized immutable releases, filtered
catalog metadata, downloads, and publisher-scoped revocation. Add Worker can
automatically acquire and admit the latest supported release. The Windows
launcher and end-to-end assignment acceptance remain outstanding. The Host
release packager accepts the checked-in manifest template, generates the signed
release manifest, and has an integration test that packages, verifies, and
installs the resulting archive using an isolated test signing key.

## Exit

A Work Request can execute through a subscription-authenticated Codex Worker.

---

# V7-7 — First-party Antigravity adapter

## Goal

Prove a second subscription-backed integration with different provider behavior.

## Responsibilities

Same shape as Codex, adapted to supported Antigravity CLI/headless interfaces.

## Verify

- Google-account local auth;
- cached auth readiness;
- model/default handling;
- cancellation;
- Workstream CWD;
- error/status normalization.

The first-party Antigravity V7 protocol adapter now wraps the local Antigravity
CLI using JSONL execution, the resolved Workstream CWD, locally selected models,
and the CLI workspace-write sandbox. It checks the local Google-account session
through `antigravity auth status`, emits sanitized progress, and keeps provider
tokens in Antigravity's local store. Conclave Workspace offers local sign-in
validation and launch for Antigravity. Host release packager tests verify that
the checked-in manifest template is signed, admitted, and installed cleanly into
the Workspace package store.

## Exit

The adapter abstraction is proven across two independent tool providers.

---

# V7-8 — First-party API adapters

## Goal

Support pay-per-use/provider API Workers without changing Worker architecture.

## Initial adapters

- OpenAI API;
- Gemini API;
- Anthropic API.

## Local setup

Each uses:
- local secure API credential;
- default/allowed model policy;
- optional HTTPS endpoint metadata (loopback HTTP is allowed for local development);
- provider credential validation through the adapter model-list endpoint before Ready.

## Shared SDK

Factor shared HTTP/streaming/tool-call helpers, but keep provider adapters separate.

Do not create one giant provider-switch adapter initially.

## Exit

Subscription tools and API Workers expose the same Conclave execution contract.

The three first-party API adapters are implemented as separate provider modules
over a shared framed protocol runtime. They validate API-key credentials with
provider model-list requests and normalize non-streaming text output from the
OpenAI Responses, Gemini generateContent, and Anthropic Messages APIs. The Host
injects keys from its secure store only into the matching adapter process, and
provider-specific network permissions are recorded in signed manifests. Tests
use mocked HTTP responses and make no provider or billable requests. These
initial adapters provide text generation only; they do not stream partial
output or give models file, shell, or function-call tools. Signed releases are
not yet published to a Cloud catalog, so they cannot be auto-installed by a
fresh Workspace until a release owner publishes them.

---

# V7-9 — Local Worker inventory sync protocol

## Goal

Synchronize safe local Worker state to Cloud.

## Runtime -> Cloud events

- worker.upsert;
- worker.status;
- worker.credential_status;
- worker.removed/tombstone;
- periodic inventory snapshot.

## Safe projection

Include:
- Worker ID;
- Workspace ID;
- name;
- Worker Type;
- capabilities;
- model policy summary;
- status;
- credential status;
- local concurrency ceiling;
- adapter version;
- last seen;
- revision.

Never include:
- raw provider token;
- API key;
- cookies;
- private credential payload;
- arbitrary local paths.

## Idempotency

Use Worker ID + monotonically increasing local revision.

Cloud accepts updates only from owning Workspace runtime.

## Exit

Cloud Worker inventory can be reconstructed entirely from Workspace sync.

The Workspace sends a full safe inventory after each successful hello and
every fourth heartbeat. Cloud binds every entry to the authenticated runtime's
Workspace, rejects cross-Workspace ID reuse and stale/equal revisions, and
persists removal tombstones. The authenticated `/api/v7/workers` read returns
only the signed-in user's projection and never includes secure-store references
or local paths. Snapshot omission reconciliation and reconnect/stale-revision
end-to-end acceptance remain open.

---

# V7-10 — Cloud persistence migration

## Goal

Make Worker -> Workspace direct.

## Target schema

Configured Worker table should directly contain:
- workspace_id;
- owner_user_id;
- worker_type_id;
- synced status/config projection;
- local revision;
- scheduling state;
- timestamps.

## Remove target dependence on

- configured_worker_workspace_bindings;
- per-binding credential state;
- binding-specific package/readiness product records.

Infrastructure package install metrics may remain separately if useful.

## Pre-production preference

Use a clean v7 dev schema/reset rather than long-lived compatibility complexity.

## Temporary conversion

For each current Worker binding:
- create one v7 Worker projection;
- assign owning Workspace;
- create new Worker ID if required;
- preserve safe names/settings;
- drop global multi-Workspace identity.

## Exit

Cloud data model matches one-Workspace Worker ownership.

---

# V7-11 — Cloud Worker inventory API

## Goal

Change Worker APIs from creation/control to inventory/operational control.

## Read APIs

Keep:
- list Workers;
- get Worker;
- filter by Workspace/Type/status.

## Remote-control APIs

Support:
- scheduling enable/disable;
- drain;
- request reauthentication attention;
- request diagnostics refresh;
- optionally request adapter update.

## Remove/retire

- Cloud Add Worker;
- Cloud credential entry;
- attach/detach Worker to/from arbitrary Workspaces;
- direct Workspace binding CRUD.

## Ownership

Worker creation/deletion source of truth is local Workspace sync.

## Exit

Cloud cannot manufacture a ready local Worker without Workspace participation.

---

# V7-12 — Conclave AX Execution UX migration

## Goal

Keep Execution simple while reflecting local Worker ownership.

## Execution

~~~text
Execution
├── Workspaces
└── Workers
~~~

## Workspaces tab

Show:
- name;
- OS/architecture;
- online state;
- Worker count;
- Project Grants;
- active work.

Workspace detail Workers tab:
- Workers physically configured on this Workspace;
- status/readiness;
- local-attention badge;
- open Worker details.

Remove:
- connect existing Worker binding;
- remove binding;
- authenticate directly in AX.

## Workers tab

Aggregated inventory.

Show:
- Worker;
- Worker Type;
- Workspace;
- Ready/Needs attention/Offline;
- current work;
- scheduling state.

Primary CTA when no Workers:

> Add a Worker in Conclave Workspace.

Optionally deep-link/open local app when on same machine later.

## Exit

AX clearly communicates that Worker setup happens on the machine.

The AX Workers tab currently reads the owner-scoped V7 inventory API and
displays Workspace, Worker Type, readiness, model/capability summary, and local
concurrency. V6 Cloud-created Workers are explicitly labeled as legacy during
the migration. V7 Worker inventory cards now open a detail view with Overview,
Workspace, Local attention, Scheduling, and Activity/Audit sections. The current
inventory contract omits remote scheduling state and recent activity, so those
sections state that limitation explicitly. When no local Workers are synced,
the primary CTA directs the user to add one in Conclave Workspace and explains
that it will appear after sync; legacy Cloud creation remains a secondary
migration action. Live scheduling controls and synced activity remain
outstanding.

---

# V7-13 — Conclave AX Worker detail UX

## Goal

Replace multi-Workspace Worker detail.

## Sections

- Overview;
- Workspace;
- Scheduling;
- Activity/Audit.

## Overview

Show:
- Worker Type;
- owning Workspace;
- readiness;
- credential status;
- adapter version;
- model/default summary;
- capabilities.

## Local attention

For auth/permission/tool issues:

~~~text
Authentication required
Complete this action in Conclave Workspace on MacBook Pro.
~~~

Optional:
- Request attention/re-authentication.

## Scheduling

Remote controls:
- Enabled;
- Disabled;
- Draining.

Cloud concurrency may only narrow local ceiling.

The detail view is driven by the safe V7 inventory projection and shows Worker
Type, owning Workspace, readiness, credential status, adapter version,
model/capability summary, and local concurrency. Auth/prerequisite attention
points the user back to Conclave Workspace on the owning machine. Scheduling
state and recent audit data are not yet present in the inventory contract.

## Exit

No binding matrix remains in normal UX; remote scheduling and activity are
visible when their control/event contracts are available.

---

# V7-14 — Scheduler simplification

## Goal

Remove Worker-binding search from candidate resolution.

## Candidate flow

~~~text
Worker
-> owning Workspace
-> Workspace online
-> Project Workspace Grant active
-> Worker ready
-> Worker scheduling enabled
-> Workstream policy allows Worker
-> capability/model compatible
-> capacity available
~~~

## Stateful work

Worker's Workspace must equal Workstream Primary Workspace.

## Stateless work

Candidate Workers may come from any eligible granted Workspace.

## Remove

- multi-binding readiness resolution;
- credential-per-binding selection;
- package-per-binding selection as product logic.

## Snapshot

Preserve:
- Worker ID;
- Workspace ID;
- Worker Type;
- adapter version;
- resolved model;
- capability/permission snapshot.

## Exit

Scheduler treats Worker as a concrete machine-local resource.

---

# V7-15 — Authorization migration

## Goal

Keep Cloud authorization while respecting local ownership.

## Project policy

May allow:
- explicit Workers;
- Worker Types;
- capabilities/models;
- any eligible Worker on a granted Workspace.

## Workstream policy

May narrow Project policy.

## Local bound

Cloud cannot schedule a Worker:
- on another Workspace;
- with permissions not locally granted;
- with unsupported model;
- when local Worker disabled/unready.

## Cross-user use

If shared Worker use is supported:
- Worker owner explicitly enables remote sharing policy locally or via an already-authorized Cloud policy;
- Cloud Project policy authorizes requester;
- audit records requester and Worker owner.

Do not silently turn a personal subscription Worker into a shared team resource.

## Exit

Authorization remains explicit at both Cloud and local trust layers.

---

# V7-16 — Runtime desired-state split

## Goal

Separate adapter infrastructure management from configured Worker identity.

## Cloud -> Workspace desired state may include

- approved adapter catalog/releases;
- adapter update policy;
- remote scheduling state;
- assignment/cancel;
- attention request.

## Workspace local state owns

- Worker existence;
- Worker credential;
- local permissions;
- prerequisite tool;
- model ceiling/default;
- local concurrency ceiling.

## Adapter package sharing

One installed adapter release serves all local Workers of same Worker Type.

Do not install one package copy per configured Worker.

## Exit

Configured Worker count does not duplicate adapter binaries.

---

# V7-17 — Conclave Workspace background/tray UX

## Goal

Make Workspace practical as an always-on local runtime.

## Desktop behavior

- closing main window does not stop runtime;
- tray/menu-bar status;
- open local app;
- open Conclave AX;
- pause accepting new work;
- current active assignment summary;
- logs;
- quit.

## Quit behavior

Warn when assignments are active.

Define:
- graceful drain;
- cancel/quit option where appropriate.

## Exit

Workspace behaves like a real background execution product, not a foreground setup wizard.

---

# V7-18 — Local permissions and reauthentication UX

## Goal

Keep sensitive machine decisions local and understandable.

## Permission flow

Adapter/Worker requests:
- filesystem scope;
- network;
- shell/tool execution;
- credential access;
- other declared capabilities.

Local user approves/denies.

## Reauthentication

Credential expiry:
- Worker becomes Needs authentication;
- Cloud receives safe status;
- AX shows local-action message;
- Workspace notification opens local auth flow.

## Security tests

- Cloud cannot auto-approve new local permission;
- Cloud cannot inject secret;
- another Workspace cannot mutate Worker;
- revoked local credential makes Worker ineligible.

## Exit

Trust boundary is demonstrably local.

---

# V7-19 — Updates and rollback

## Goal

Separate three update domains.

## Conclave Workspace app

- signed application release;
- update notification/self-update strategy.

## Adapter package

- signed/digest verified;
- staged install;
- health check;
- atomic activate;
- rollback to previous verified version.

The Workspace V7 store stages adapter directories or bounded gzip-compressed
tar archives, rejects unsafe archive entries, verifies the signed digest and
declared health check before activation, and can reactivate a re-verified,
healthy installed version. Cloud stores immutable V7 releases in R2 and exposes
catalog metadata, downloads, and revocation. Add Worker verifies the archive
hash and catalog manifest before package admission; background update and
revocation reconciliation remain open.

## Third-party tool

- provider-owned unless explicitly managed;
- detect missing/outdated;
- show local remediation.

## Exit

An adapter update cannot brick the Workspace runtime.

---

# V7-20 — Workstream directory integration verification

## Goal

Prove v7 does not regress ADR-011.

## Verify

- Worker A and Worker B in same Workstream see same CWD;
- different Workstreams use distinct ID-only directories;
- Project/Workstream rename has zero path effect;
- Workspace re-enrollment preserves work root behavior;
- adapter cannot supply/override arbitrary CWD.

## Exit

Local Worker redesign composes cleanly with Workstream filesystem architecture.

---

# V7-21 — Audit and operational observability

## Goal

Preserve useful non-Usage diagnostics after Usage removal.

## Record

- Worker created/edited/removed locally;
- inventory sync;
- credential state transitions;
- scheduling enable/disable/drain;
- adapter install/update/rollback;
- assignment start/end/failure;
- permission denial;
- prerequisite missing;
- auth failure.

## Metrics

Operational only:
- online/offline;
- active assignments;
- adapter crash count;
- auth failure count;
- update failure;
- execution duration;
- queue/concurrency state.

Do not reintroduce token/cost Usage accounting.

## Exit

Operations are diagnosable without a Usage subsystem.

---

# V7-22 — Legacy v6 Worker cleanup

## Goal

Remove compatibility paths after v7 is end-to-end.

## Remove

- Cloud Add Worker flow;
- Worker Workspace binding APIs/UI;
- multi-Workspace credential readiness;
- old binding tables;
- binding-specific setup/reauth endpoints;
- old copy saying "connect Worker to Workspace".

## Rename/refactor internals

Update classes/types where old semantics become misleading.

Avoid large cosmetic renames before behavior migration is proven.

## Exit

One Worker ownership model remains.

---

# V7-23 — Solo acceptance

From clean environment:

1. sign in to Conclave AX;
2. create Workspace with name only;
3. install/pair Conclave Workspace;
4. local app reports platform automatically;
5. Add Worker locally;
6. choose Codex;
7. authenticate with subscription locally;
8. Worker becomes Ready;
9. Cloud inventory shows Worker;
10. create Project/Workstream;
11. grant Workspace;
12. run Work;
13. scheduler chooses Worker;
14. adapter child process executes in Workstream CWD;
15. results return;
16. no secret appears in Cloud.

## Exit

Primary v7 value proposition works end-to-end.

---

# V7-24 — Multi-Worker / mixed billing acceptance

Configure locally:

- Codex Personal (subscription);
- Antigravity Personal (subscription);
- OpenAI API Work (API key);
- Ollama Local.

Verify:
- all appear as Workers;
- model selection works within each;
- scheduler can distinguish capabilities;
- simultaneous stateless assignments run safely;
- stateful Workstream mutation remains serialized;
- provider billing model does not change Conclave architecture.

## Exit

One Worker contract supports subscription, API and local-model execution.

---

# V7-25 — Failure and recovery acceptance

Test:
- Cloud disconnect;
- Workspace reconnect;
- adapter crash;
- tool crash;
- credential expiry;
- missing CLI;
- adapter update failure;
- Workspace app update;
- Workstream active during rename;
- cancellation;
- forced process kill;
- local Worker removed while Cloud stale;
- duplicate inventory event;
- stale Worker revision.

## Exit

Failure behavior is explicit and idempotent.

---

# V7-26 — Security acceptance

Test:
- forged Worker inventory from wrong Workspace;
- path traversal;
- arbitrary executable request;
- arbitrary CWD request;
- secret exfiltration via logs;
- malicious adapter manifest;
- tampered package;
- permission escalation request;
- Cloud trying to broaden permissions;
- cross-user scheduling without authorization;
- local API key never transmitted;
- child process escaping process-tree cancellation.

## Exit

Workspace remains the machine security boundary.

---

# V7-27 — UX acceptance

A new user should understand without docs:

~~~text
1. Add a Workspace in Conclave AX.
2. Install and pair Conclave Workspace.
3. Add/authenticate Workers on that computer.
4. Workers appear automatically in Conclave AX.
5. Use them from Workstreams.
~~~

They should not need to understand:
- Worker package;
- Worker binding;
- AI Account;
- Credential Profile;
- provider secret synchronization;
- model-specific Worker installation.

## Exit

The architecture is reflected faithfully in both apps.

---

# Recommended delivery sequence

## Foundation

1. V7-0 vocabulary
2. V7-1 domain contracts
3. V7-2 local Worker registry
4. V7-3 local Add Worker UX
5. V7-4 adapter SDK

## Execution

6. V7-5 child-process execution
7. V7-6 Codex adapter
8. V7-7 Antigravity adapter
9. V7-8 API adapters

## Cloud synchronization

10. V7-9 inventory sync
11. V7-10 persistence migration
12. V7-11 inventory/control API
13. V7-12 AX Execution UX
14. V7-13 AX Worker detail
15. V7-14 scheduler
16. V7-15 authorization
17. V7-16 desired-state split

## Product/runtime maturity

18. V7-17 background/tray UX
19. V7-18 permissions/auth
20. V7-19 updates/rollback
21. V7-20 Workstream directory verification
22. V7-21 observability

## Cleanup and acceptance

23. V7-22 legacy cleanup
24. V7-23 solo acceptance
25. V7-24 mixed Worker acceptance
26. V7-25 failure recovery
27. V7-26 security
28. V7-27 UX

## Critical sequencing rule

> **Do not delete the current Cloud-created/multi-Workspace Worker path until local Worker creation, inventory sync, Cloud scheduling, and one real adapter execute end-to-end.**

The first vertical slice should be:

~~~text
Local Codex Worker
-> inventory sync
-> AX sees Worker
-> Project/Workstream authorization
-> scheduler selects it
-> Workspace launches Codex adapter
-> Work completes
~~~

Only after that slice passes should the v6 binding model be removed.
