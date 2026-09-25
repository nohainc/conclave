# Configured Worker Execution Model — Implementation Roadmap

**Status:** Proposed  
**Architecture:** [ADR-010](../decisions/ADR-010-configured-worker-execution-model.md)  
**Builds on:** Architecture v6  
**Date:** 2026-09-25

## Target outcome

Replace the current user-facing split:

~~~text
Workspaces | Workers | AI Accounts
~~~

with:

~~~text
Execution
├── Workspaces
└── Workers
~~~

where **Worker** means one configured executable identity and **AI Account** becomes internal credential state.

This roadmap is intentionally separated from the broader v6 Workstream roadmap so implementation can proceed in controlled slices.

---

## EW-0 — Freeze vocabulary and invariants

### Goal

Make the target model unambiguous before changing schema or UI.

### Decisions to lock

- top-level product area is **Execution**;
- primary execution resources are **Workspaces** and **Workers**;
- Worker Type is catalog/infrastructure;
- Worker is a configured user resource;
- one Worker has one logical external AI identity;
- one Worker may bind to multiple Workspaces;
- one Workspace may host multiple Workers;
- multiple Workers may use the same Worker Type;
- credential material remains local to each Workspace where required;
- Worker role is not a single fixed mandatory role;
- Workflows continue to select by role/capability.

### Documentation updates

- Architecture v6 product vocabulary;
- top-level architecture summary;
- source audit notes;
- solo acceptance flow;
- UI/UX acceptance language.

### Exit

No active architecture document defines AI Account as an equal first-class user resource.

---

## EW-1 — Introduce canonical ConfiguredWorker domain

### Goal

Create a domain object distinct from Worker Type/catalog.

The core baseline is implemented in `packages/core/src/configured-worker.ts`.
It keeps Worker Type, ConfiguredWorker, Workspace binding, and internal
credential metadata as separate domain shapes without adding persistence or
Cloud secret storage.

### Add conceptual model

ConfiguredWorker:
- id;
- ownerUserId;
- name;
- workerTypeId;
- status;
- defaultModel;
- config;
- concurrencyLimit;
- billing/cost metadata;
- preferredRoles / allowedRoles optional;
- createdAt / updatedAt.

### Add Workspace binding model

WorkerWorkspaceBinding:
- workerId;
- workspaceId;
- enabled;
- desiredVersionPolicy;
- localReadiness;
- packageStatus;
- credentialStatus;
- permissionsStatus;
- lastSeen / updatedAt.

### Credential model

Credential metadata remains separate internally:
- auth type;
- owner;
- sharing policy;
- provider metadata;
- local secret reference;
- state per Workspace when needed.

### Invariants

- configured Worker references exactly one Worker Type;
- configured Worker cannot execute on unbound Workspace;
- ready = package ready + permissions ready + credential ready;
- deleting/revoking Worker disables all bindings;
- no Cloud secret storage introduced.

### Tests

- serialization;
- uniqueness/ownership;
- one type -> many Workers;
- one Worker -> many bindings;
- readiness aggregation.

### Exit

Core can represent Worker Type, configured Worker and Workspace binding without overloading one entity.

---

## EW-2 — Clean persistence model

### Goal

Persist configured Workers explicitly.

The v6 schema now adds `configured_workers`,
`worker_workspace_bindings`, and `workspace_worker_credentials`. The existing
`workers` table remains the Worker Type/catalog table for this migration slice;
AI Account records remain internal compatibility data and are no longer the
only persisted configured identity path.

### Preferred pre-production schema

Add:
- configured_workers;
- worker_workspace_bindings;
- workspace_worker_credentials or equivalent local-readiness metadata.

Retain/rename:
- workers -> Worker Type/catalog, or migrate to worker_types;
- worker_versions;
- workspace_worker_installations.

Deprecate as user-facing domain:
- ai_accounts.

### Migration options

Preferred:
- clean v6 dev reset with direct target schema.

Alternative temporary bridge:
- configured Worker row references one existing ai_account;
- old account APIs remain internal until subsequent cleanup.

### Required indexes

- owner + name;
- Worker Type;
- Workspace binding;
- readiness/status;
- active Worker eligibility.

### Exit

Database no longer requires AI Account as the only configured identity object.

---

## EW-3 — Worker API resource

### Goal

Expose configured Workers directly.

The direct `/api/workers` resource is implemented. It owns configured Worker
CRUD, Workspace binding/readiness management, local setup/reauthentication
requests, and revocation. Existing account routes remain compatibility paths;
new clients do not need to create an AI Account separately.

### API

- GET /api/workers
- POST /api/workers
- GET /api/workers/:id
- PATCH /api/workers/:id
- DELETE/REVOKE /api/workers/:id
- GET/PUT /api/workers/:id/workspaces
- POST /api/workers/:id/workspaces/:workspaceId/setup
- POST /api/workers/:id/workspaces/:workspaceId/reauthenticate

### Create Worker request

Includes:
- name;
- workerTypeId;
- auth strategy / connection setup intent;
- default model/config;
- concurrency;
- Workspace IDs.

### Response

Returns:
- global Worker state;
- per-Workspace readiness;
- required next actions.

### Remove from public API

Do not expose standalone account creation as the normal flow once Worker creation is ready.

### Tests

- owner authorization;
- duplicate names policy;
- invalid Worker Type;
- invalid Workspace ownership;
- multi-Workspace binding;
- revoke behavior.

### Exit

A client can fully configure a Worker without creating an AI Account separately.

---

## EW-4 — Workspace convergence / desired state

Implementation status: implemented in the v6 runtime path. Configured Worker
bindings are now the declarative source for Workspace sync; package metadata is
resolved from the Worker Type release, while installation and readiness are
recorded per configured Worker and Workspace. Runtime reports package,
credential, permission, effective-readiness, and active-assignment metadata.

### Goal

Make Workspace binding declarative.

### On binding

Cloud desired state should ensure:
- Worker Type package version is available;
- package installed;
- permission requirements satisfied;
- credential setup requested if missing.

### Runtime

Workspace reports per configured Worker:
- package state;
- credential state;
- permission state;
- effective readiness;
- active assignment count.

### Automatic behavior

Normal user flow should not require:
- Make Worker available;
- install package manually;
- separately bind AI Account.

### Failure states

- package unavailable;
- unsupported OS/architecture;
- auth required;
- auth expired;
- permission denied;
- runtime offline;
- incompatible Worker version.

### Exit

Binding a Worker to a Workspace is the only normal installation/readiness action.

---

## EW-5 — Credential abstraction migration

Implementation status: credential operations are Worker-contextual. The
configured Worker API exposes only Workspace-binding credential metadata and
setup/revocation actions; runtime credential status updates reconcile the
corresponding binding. Secret values remain in the Workspace secure store and
are never returned by Cloud APIs.

### Goal

Hide AI Account as a product object without weakening security.

### Preserve internally

- local secure-store secrets;
- provider auth type;
- provider sharing policy;
- credential owner;
- grant/revocation semantics;
- audit;
- usage attribution.

### Change ownership model

Credential state is reached through:

~~~text
Configured Worker -> Workspace Binding -> Credential readiness
~~~

rather than through a standalone global AI Account tab.

### Multi-Workspace rule

One logical Worker identity may require independent local authentication on each Workspace.

Cloud stores only safe metadata and secret references.

### Tests

- Workspace A ready / Workspace B auth required;
- credential expiry on one Workspace only;
- revoke Worker;
- revoke one Workspace credential;
- provider private-only restrictions;
- no secret in Cloud payload/logs.

### Exit

All credential operations are Worker-contextual.

---

## EW-6 — Scheduler selection by configured Worker

Implementation status: scheduler candidates now resolve configured Worker IDs,
Worker Type IDs, Workspace bindings, package readiness, credential readiness,
credential ownership, capabilities, permissions, and configured-Worker
capacity. Assignment records preserve both configured Worker and Worker Type
identities; legacy Account IDs remain optional internal accounting metadata.

### Goal

Resolve execution against configured Workers instead of catalog Worker + AI Account pair.

### Scheduler candidate

Candidate contains:
- configuredWorkerId;
- workerTypeId;
- Workspace binding;
- resolved package version;
- credential readiness;
- provider/model;
- capacity;
- authorization;
- independence key if needed.

### Selection

Workflow step still declares:
- role;
- capabilities;
- execution class.

Scheduler filters configured Workers by:
1. Project/Workstream authorization;
2. Workspace grant;
3. Worker binding;
4. package readiness;
5. credential readiness;
6. permissions;
7. capability;
8. capacity/concurrency;
9. independence requirement.

### Assignment snapshot

Store both:
- configuredWorkerId;
- workerTypeId.

Keep credential-owner/attribution metadata internally where required.

### Exit

Assignments no longer require users to reason about an independent Account selection.

---

## EW-7 — Project and Workstream authorization migration

Implementation status: scheduler authorization is Worker-first. Workspace
grants constrain configured Worker IDs, while Workstream execution policies
can narrow configured Workers, Worker Types, providers, and models.
Account identifiers remain optional internal attribution fields only.

### Goal

Replace account-first policy with Worker-first policy.

### Project

Workspace Grants continue to authorize execution environments.

Add/adjust Worker policy so a Project may use an explicit or eligible set of configured Workers.

### Workstream

Execution policy may narrow:
- allowed Workers;
- allowed Worker Types;
- provider/model.

### Sponsor/shared use

If another user's Worker may be used:
- owner explicitly grants Worker use;
- provider sharing policy is checked;
- audit log records requester and Worker/credential owner;
- Workstream policy only narrows existing authorization.

### Product wording

Use:
- Allowed Workers;
- Execution Worker;
- Worker owner;
- Worker connection.

Avoid normal-user wording:
- Project Account Grant;
- explicit_accounts;
- Account policy.

### Exit

Users authorize execution through Worker resources.

---

## EW-8 — Execution page information architecture

### Goal

Replace current Workspaces page.

### Rename

Current page title:
- Workspaces

New:
- **Execution**

Subtitle:
- Manage execution environments and configured Workers.

### Primary tabs

- Workspaces
- Workers

Remove:
- AI Accounts

### Navigation

- /execution
- /execution/workspaces
- /execution/workers

Legacy routes may redirect during development but should be removed before release.

### Exit

Top-level navigation reflects the new model.

---

## EW-9 — Workers page UX

### Goal

Make Workers the main setup surface.

### List card

Show:
- name;
- Worker Type;
- provider/connection;
- status;
- Workspace readiness;
- active assignments;
- operational health/metrics where available.

### Add Worker

Single wizard:
1. name;
2. Worker Type;
3. connection/authentication;
4. defaults;
5. Workspace selection;
6. review/create.

### Worker detail

Recommended sections:
- Overview;
- Workspaces;
- Observability / Audit;
- Settings.

Overview:
- Worker Type;
- connection;
- model/defaults;
- capabilities;
- global status.

Workspaces:
- one row per binding;
- package/auth/permissions/readiness;
- Connect Workspace;
- Reauthenticate;
- Remove from Workspace.

### Exit

A new user can create Codex Personal and Codex Company without learning about AI Account objects.

---

## EW-10 — Workspace detail UX

### Goal

Make Workspace show its bound configured Workers.

### Tabs

Recommended:
- Overview;
- Workers;
- Project access;
- Activity;
- Settings.

Remove:
- AI Accounts.

### Workers tab

For each configured Worker show:
- name;
- type;
- package version/state;
- credential state;
- readiness;
- active work.

Actions:
- open Worker;
- authenticate/re-authenticate;
- remove binding;
- troubleshoot.

### Exit

Workspace detail answers: "Which configured Workers can run here?"

---

## EW-11 — Remove manual Worker catalog management from normal UX

### Goal

Worker Type/package lifecycle becomes infrastructure.

### Keep

Catalog data is still required for:
- available Worker Types;
- versions;
- capabilities;
- permissions;
- OS/architecture support;
- signing/publishing.

### Hide from normal user

Remove normal-flow actions:
- Make available;
- Remove from Workspace;
- Connect Account from catalog card.

### Optional advanced/admin surface

A future diagnostics/catalog page may show:
- available Worker Types;
- package versions;
- release health.

It must not be confused with configured Workers.

### Exit

"Worker" always means configured Worker in normal product UX.

---

## EW-12 — Usage, audit and observability migration

### Usage dimensions

Record:
- Project;
- Workstream;
- Work Request;
- requester;
- Workspace;
- configured Worker;
- Worker Type;
- provider/model;
- credential owner;
- cost/tokens/duration.

### Audit events

Add:
- worker.created;
- worker.updated;
- worker.revoked;
- worker.workspace.bound;
- worker.workspace.unbound;
- worker.credential.setup_requested;
- worker.credential.ready;
- worker.credential.revoked.

### Metrics

- Workers ready/partial/offline;
- bindings per Workspace;
- auth failures;
- package convergence latency;
- assignment utilization by Worker.

### Exit

Operations can diagnose the configured Worker abstraction end to end.

---

## EW-13 — Remove standalone AI Account product paths

### Goal

Delete obsolete product surface and compatibility logic.

### Remove

- AI Accounts tab;
- account-first setup wizard;
- account navigation route;
- account-specific product copy;
- Worker catalog "Connect Account" action.

### Backend cleanup

When all consumers use configured Workers:
- remove public account CRUD routes;
- collapse bridge tables where safe;
- remove scheduler account-selection inputs from normal API;
- retain only internal credential metadata necessary for security/accounting.

### Guard

Add architecture/source verification that prevents reintroducing standalone AI Account navigation.

### Exit

No normal product workflow requires an AI Account object.

---

## EW-14 — Migration of existing development data

### Clean reset preferred

Because Conclave is pre-production, prefer rebuilding dev fixtures.

### If conversion is needed

For each existing AI Account:
- create configured Worker;
- copy display name;
- map account.worker_id -> Worker Type;
- copy owner/sharing/provider metadata;
- bind to account execution Workspace;
- preserve safe credential references;
- map audit attribution.

For existing Workspace Worker installations:
- retain as package infrastructure;
- associate with new bindings where applicable.

### Exit

No orphaned execution identity remains.

---

## EW-15 — Solo acceptance

From empty DB:

1. sign in;
2. open Execution;
3. add Workspace;
4. Add Worker;
5. choose Codex;
6. authenticate;
7. bind Workspace;
8. Worker reaches Ready;
9. create Project;
10. grant Workspace;
11. create Workstream;
12. Run Work;
13. assignment uses configured Worker;
14. assignment and audit are recorded correctly.

### Exit

No AI Account or package-installation knowledge is required.

---

## EW-16 — Multi-identity acceptance

Create:
- Codex Personal;
- Codex Company;
- Codex Backup;
- Claude Review.

Verify:
- all may use same/different Worker Types;
- each has separate logical credentials;
- one Worker may bind to multiple Workspaces;
- one Workspace may run several Workers;
- authentication can differ per Workspace;
- Project can allow a subset;
- workflow capability selection works;
- audit distinguishes identities.

### Exit

The primary reason for configured Workers is proven.

---

## EW-17 — Security acceptance

Test:
- Cloud never stores provider secret;
- Workspace credential isolation;
- unauthorized Worker use;
- unauthorized Workspace binding;
- provider private-only sharing;
- revoked credential;
- revoked Worker;
- revoked Workspace Grant;
- stale package;
- malicious Worker Type permissions;
- cross-user Worker ID enumeration;
- audit completeness.

### Exit

Product simplification does not weaken execution security.

---

## EW-18 — UX acceptance

A new user should understand without architecture knowledge:

> Workspace = where AI runs.  
> Worker = the configured AI/tool identity that runs.  
> Project/Workstream = what it works on.

They should not need to understand:
- AI Account;
- Credential Profile;
- Worker installation desired state;
- worker_versions;
- secret references.

### Exit

The execution model can be explained in three lines and the UI matches those lines.

---

## Recommended delivery order

1. EW-0 vocabulary/invariants
2. EW-1 canonical domain
3. EW-2 persistence
4. EW-3 Worker API
5. EW-4 Workspace convergence
6. EW-5 credential abstraction
7. EW-6 scheduler
8. EW-7 authorization
9. EW-8 Execution page IA
10. EW-9 Workers UX
11. EW-10 Workspace UX
12. EW-11 catalog hiding
13. EW-12 audit/observability
14. EW-13 old Account cleanup
15. EW-14 data migration
16. EW-15..18 acceptance

## Sequencing rule

> Do not remove credential/account security metadata before configured Worker execution is end-to-end. Remove the **product concept** first, then retire internal compatibility state only after Worker-based scheduling, authorization and attribution are proven.
