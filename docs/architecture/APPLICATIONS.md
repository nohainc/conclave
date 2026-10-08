# Conclave Applications & Architecture Boundaries

**Status:** Current Architecture v8 product/application boundary.

Conclave defines four primary product surfaces:
1. **Conclave AX** (`apps/app`): Human web interface for space orchestration, thread binding, and approvals.
2. **Conclave Cloud** (`apps/cloud`): Authoritative Cloud API, database, catalog store, signature authority, and Workspace Gateway.
3. **Conclave Workspace** (`apps/workspace`): Native machine-side desktop application and execution runtime.
4. **Conclave Profile Lab** (`apps/profile_lab`): Internal administrative desktop engineering application for Worker catalog management, Profile authoring, sandbox testing, release promotion, and revocation.

---

## 1. Conclave AX

**Current path:** `apps/app`
**Target path:** `apps/app`

**Technology**
- Flutter;
- Dart;
- Web.

**Purpose**
- human authentication;
- Spaces and Threads;
- Discuss/Work;
- read-only Workspace/runtime/Worker visibility;
- Space-facing Workspace Grants and execution authorization;
- approvals, evidence and artifacts.

Conclave AX is the web application. It is not packaged as the machine-side executor. Native mobile clients may be added later without changing the Workspace runtime boundary.

Conclave AX communicates only with Conclave Cloud through the Human Product
Protocol. It MUST NOT connect to the Workspace Runtime Protocol or send
machine-authenticated runtime messages. Protocol ownership and the explicit
Workspace-to-Engine boundary are defined in the
[Protocol Boundaries contract](PROTOCOL_BOUNDARIES.md).

The canonical execution-capacity destination in AX is **Workspaces**. Workers
appear inside their owning Workspace rather than as an independent top-level
page. See the [Workspaces UX and data contract](WORKSPACES_UX_CONTRACT.md).

Home summarizes Spaces, Workspaces, and locally ready Workers. Both the
Workspace count and Ready Workers count open `/workspaces`; AX does not expose
a global Worker inventory. Getting Started guides users to add a Workspace,
configure Workers in the Conclave Workspace desktop app, and create a Space.
Authentication and local readiness problems direct users back to that desktop
runtime.

Workspace-owned Worker inventory remains visible in AX as operational
readiness. Workspace registration and recovery, local Worker lifecycle,
credentials, permissions, and runtime connection management belong to Conclave Workspace. AX owns actual
Space/Thread Worker use: task role, Workspace/Worker selection, model,
fallback policy, Cloud scheduling state, and Cloud concurrency ceilings. These
choices live with Space and Thread policy, not local Worker setup. See
[ADR-016](../decisions/ADR-016-ax-owned-worker-usage.md).

The Work composer and its built-in Workflow/step semantics follow the frozen
[Work v1 Contract](../specifications/WORK_V1_CONTRACT.md). That contract is
the sole authoritative catalog.

## 2. Conclave Cloud

**Current path:** `apps/cloud`
**Target path:** `apps/cloud`

**Technology**
- TypeScript;
- Cloudflare Workers;
- Cloudflare Workflows;
- Durable Objects;
- D1;
- R2.

**Purpose**
- authoritative multi-user state;
- orchestration;
- human authentication;
- realtime App connections;
- Workspace Gateway;
- built-in Work catalog, logical Worker catalog, and signed Tool Profile release registry;
- synchronized logical Worker inventory and readiness;
- Space/Thread Worker authorization;
- assignment scheduling;
- audit/evidence;
- artifacts.

Conclave Cloud never executes an external AI/model/tool directly.
Cloud exposes separate human-facing product APIs and an authenticated
Workspace Gateway. The former serves AX and human management operations; the
latter speaks only the Workspace Runtime Protocol with Conclave Workspace.

## 3. Conclave Workspace

**Path:** `apps/workspace`
**User-facing product name:** Conclave Workspace

**Technology**
- Flutter;
- Dart;
- native desktop application/runtime;
- macOS first, then Windows/Linux.

**Targets**
- macOS first;
- Windows;
- Linux;
- headless Linux/server later using the same runtime model.

**Purpose**
- one machine runtime/security identity;
- human sign-in for local Workspace management/recovery;
- authenticated Workspace registration/recovery;
- persistent Cloud communication with WebSocket primary and HTTPS fallback;
- platform/architecture/runtime reporting;
- local Work Root and Thread directories;
- local logical Worker registry;
- provider CLI-owned local sign-in;
- CLI Worker Engine and signed Tool Profile cache/admission;
- local permission approval;
- child-process supervision;
- assignment execution/cancellation;
- logs, diagnostics and updates;
- minimal local UX.

One normal Conclave Workspace installation runs per machine/OS-user installation.

Each logical Worker Type has one local Worker slot in a Workspace. Provider
CLIs own their sign-in; safe Worker readiness is synchronized to Cloud, and AX
Thread policy determines how that capacity is used.

Conclave Workspace is background-first. Human desktop authentication is
distinct from Workspace runtime participation and from Worker/provider
credentials. Signing in establishes management identity; an explicit **Connect
Workspace** action registers/recovers runtime participation. A connected
Workspace may auto-start/reconnect in the background after OS login using its
runtime credential even when the human management session later requires
reauthentication. The management UI may be locally locked without stopping
runtime execution. Signed-out and locked users do not see the normal Workspace
or Workers management surfaces. Provider credentials remain local.

Spaces, Threads, Discuss, Work orchestration and Space administration remain in Conclave AX.

## 4. Logical Workers, CLI Worker Engine, and Tool Profiles

**Current v8 runtime:** `engines/cli_worker` plus official Profile definitions
and immutable releases. Do not add `workers/<worker-type-id>` executable
packages for normal provider CLIs.

A Worker Type is the stable product/catalog identity for a Logical Worker, not
a user-installed application and not an AI model.

Conclave v1 initially provisions these official Logical Workers:
- **ChatGPT**, resolved by the `chatgpt-codex` Tool Profile Definition to Codex CLI (`codex`);
- **Gemini**, resolved by the `gemini-antigravity` Tool Profile Definition to Antigravity CLI (`agy`).

The official Worker Catalog is Cloud-managed and dynamically delivered.
Additional approved Worker Types can become available without a Workspace
application release when an existing Engine family and supported Tool Profile
schema can express them.

Each Workspace has one stable local slot for each type. The provider CLI owns
sign-in and billing mode; Conclave
does not ask the user to choose subscription versus API-key authentication or
store the provider credentials. See the
[Worker catalog contract v1](../specifications/FIRST_PARTY_WORKER_CATALOG_V1.md).

Conclave Workspace resolves each Logical Worker to one compatible signed Tool
Profile Release and starts the generic CLI Worker Engine out of process. The
Engine invokes the locally installed Provider CLI using structured arguments
and Local Worker Protocol 4.0. The Engine is the sole production CLI Worker
runtime. Real-provider acceptance and remaining release gates are tracked in
the current v8 implementation plan.

A local Worker slot:
- belongs to exactly one Workspace;
- uses its fixed logical Worker Type name;
- relies on provider CLI-owned local sign-in;
- does not own model defaults or allow-lists; model choice comes from the Work/Assignment;
- is synchronized to Cloud as safe metadata/readiness;
- does not connect directly to Conclave Cloud.

Models such as GPT, Gemini Pro/Flash or Claude Sonnet/Opus are configuration, not separate Worker Types.

## Product vocabulary

Use:
- Conclave AX;
- Workspaces for the top-level AX execution-capacity page;
- Workspace;
- Worker;
- Worker Type for the stable catalog identity;
- Conclave Workspace for the machine-side application/runtime;
- credential state when referring to local authentication/readiness.

Provider credentials remain local to provider CLI software and are not Cloud
product resources. Readiness may report safe credential state without exposing
credential material.

## Build and connection validation

macOS package:

~~~text
bash scripts/build-workspace-macos.sh
~~~

Workspace connects to Cloud after browser-assisted desktop authentication.
Registration and recovery use the authenticated
`POST /api/workspace-runtime/register` contract.
The production Workspace Gateway smoke exercises this same registration and
runtime-connection path.

Current ownership and runtime decisions are defined by
[Architecture v8](ARCHITECTURE_V8.md),
[ADR-012](../decisions/ADR-012-workspace-owned-local-workers.md), and
[ADR-018](../decisions/ADR-018-generic-cli-worker-engine-and-tool-profiles.md).


## Workspace authentication and transport

The desktop ownership/connection model is defined by
[ADR-013](../decisions/ADR-013-desktop-auth-and-dual-transport.md).
WebSocket remains the preferred runtime transport; HTTPS long-poll is the
fallback. AX is not required for normal Workspace repair or registration.

## Desktop lifecycle

The canonical Workspace desktop lifecycle is defined by
[ADR-014](../decisions/ADR-014-workspace-desktop-lifecycle.md) and the
[release validation runbook](../operations/WORKSPACE_DESKTOP_LIFECYCLE_RELEASE_VALIDATION.md).
The product distinguishes Sign in, Connect/Disconnect Workspace, Lock/Unlock,
Release ownership, Sign out, and Reset. These actions must not be aliases for
one another.


## Architecture v8 local runtime refinement

Conclave Workspace launches one generic CLI Worker Engine process
per assignment/probe by default. Product-visible ChatGPT/Gemini rows remain
Logical Workers. Official signed Tool Profile Releases map those identities to
supported Provider CLI behavior. New normal CLI integrations should be added
through the Cloud Worker catalog and Tool Profile releases when Profile v1 can
express them.

## 5. Conclave Profile Lab

**Path:** `apps/profile_lab`
**Internal product name:** Conclave Profile Lab

**Technology**
- Flutter;
- Dart;
- native desktop application.

**Target**
- macOS only.

**Purpose**
- internal engineering and operations application for maintaining the Worker and Tool Profile ecosystem;
- dynamic Worker Catalog browsing and Profile Definition inspection;
- author, edit, and validate local Draft Profiles;
- test unsigned local Draft Profile candidates directly against locally installed provider CLIs using the generic CLI Worker Engine in an isolated test sandbox;
- capture cryptographic test evidence bound to exact Profile payload digests;
- request immutable signed Profile releases from Cloud;
- manage release lifecycle promotion (`Testing` → `Beta` → `Stable`), rollback, and revocation.

Conclave Profile Lab is strictly separated from Conclave Workspace and Conclave AX. It never registers as an execution Workspace, never advertises Workers to Cloud inventory, never accepts Work assignments, and never owns Space Work Roots. Provider credentials remain owned by local provider CLIs; Profile Lab never stores provider credentials. See [ADR-019](../decisions/ADR-019-conclave-profile-lab.md).
