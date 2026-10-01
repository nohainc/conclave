# Conclave AX Applications

**Status:** Architecture v8 product/application boundary. Architecture v7 and
Worker Runtime v2 details are historical predecessor material where noted.

Conclave AX has three primary applications and one extension type.

## 1. Conclave AX

**Current path:** `apps/app`
**Target path:** `apps/app`

**Technology**
- Flutter;
- Dart;
- Web.

**Purpose**
- human authentication;
- Projects and Workstreams;
- Discuss/Work;
- read-only Workspace/runtime/Worker visibility;
- Project-facing Workspace Grants and execution authorization;
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

Home summarizes Projects, Workspaces, and locally ready Workers. Both the
Workspace count and Ready Workers count open `/workspaces`; AX does not expose
a global Worker inventory. Getting Started guides users to add a Workspace,
configure Workers in the Conclave Workspace desktop app, and create a Project.
Authentication and local readiness problems direct users back to that desktop
runtime.

Workspace-owned Worker inventory remains visible in AX as operational
readiness. Pairing, recovery, local Worker lifecycle, credentials, permissions,
and runtime connection management belong to Conclave Workspace. AX owns actual
Project/Workstream Worker use: task role, Workspace/Worker selection, model,
fallback policy, Cloud scheduling state, and Cloud concurrency ceilings. These
choices live with Project and Workstream policy, not local Worker setup. See
[ADR-016](../decisions/ADR-016-ax-owned-worker-usage.md).

The Work composer and its built-in Workflow/step semantics follow the frozen
[Work v1 Contract](../specifications/WORK_V1_CONTRACT.md). That contract is
the sole authoritative catalog; the historical V6 Workflow presets are not
additional Work v1 choices.

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
- synchronized configured Worker inventory;
- Project/Workstream Worker authorization;
- assignment scheduling;
- audit/evidence;
- artifacts.

Conclave Cloud never executes an external AI/model/tool directly.
Cloud exposes separate human-facing product APIs and an authenticated
Workspace Gateway. The former serves AX and human management operations; the
latter speaks only the Workspace Runtime Protocol with Conclave Workspace.

## 3. Conclave Workspace

**Path:** `apps/host`  
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
- local Work Root and Workstream directories;
- local configured Worker registry;
- local provider authentication/secure credentials;
- CLI Worker Engine and signed Tool Profile cache/admission;
- local permission approval;
- child-process supervision;
- assignment execution/cancellation;
- logs, diagnostics and updates;
- minimal local UX.

One normal Conclave Workspace installation runs per machine/OS-user installation.

Configured Workers are created/authenticated locally and belong to exactly one Workspace. Safe Worker readiness is synchronized to Cloud; AX Workstream policy determines how that capacity is used.

Conclave Workspace is background-first. Human desktop authentication is
distinct from Workspace runtime participation and from Worker/provider
credentials. Signing in establishes management identity; an explicit **Connect
Workspace** action registers/recovers runtime participation. A connected
Workspace may auto-start/reconnect in the background after OS login using its
runtime credential even when the human management session later requires
reauthentication. The management UI may be locally locked without stopping
runtime execution. Signed-out and locked users do not see the normal Workspace
or Workers management surfaces. Provider credentials remain local.

Projects, Workstreams, Discuss, Work orchestration and Project administration remain in Conclave AX.

## 4. Logical Workers, CLI Worker Engine, and Tool Profiles

**Current v8 runtime:** `engines/cli_worker` plus official Profile definitions
and immutable releases. Do not add `workers/<worker-type-id>` executable
packages for normal provider CLIs.

A Worker Type is the stable product/catalog identity for a Logical Worker, not
a user-installed application and not an AI model.

The frozen first-party v1 product catalog contains two Logical Workers:
- **ChatGPT**, resolved by the `chatgpt-codex` Tool Profile Definition to Codex CLI (`codex`);
- **Gemini**, resolved by the `gemini-antigravity` Tool Profile Definition to Antigravity CLI (`agy`).

Each Workspace has one stable slot for each type and at most one configured
Worker per slot. The CLI owns provider authentication and billing mode; Conclave
does not ask the user to choose subscription versus API-key authentication or
store the provider credentials. See the
[Worker catalog contract v1](../specifications/FIRST_PARTY_WORKER_CATALOG_V1.md).

Conclave Workspace resolves each Logical Worker to one compatible signed Tool
Profile Release and starts the generic CLI Worker Engine out of process. The
Engine invokes the locally installed Provider CLI using structured arguments
and Local Worker Protocol 4.0. Provider binaries and release tooling from
Worker Runtime v2 are migration-only until v8 acceptance; they are not the
architecture target for new integrations.

A configured Worker:
- belongs to exactly one Workspace;
- has one local authentication/configuration context;
- is displayed using its fixed product type name, without a configurable Worker name;
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

Do not expose AI Account or Credential Profile as a peer product resource.
Credential state remains local Workspace-owned implementation/security state.

## Historical v4/v5 product terminology

The following names belong to historical architecture documents and are not
current product surfaces:
- Conclave AX Studio as a product name;
- Agent;
- Agent Engine;
- Plugin;
- Connection.

Architecture v5 preceded the configured Worker model. V6 introduced configured
Workers, and V7 makes them Workspace-owned local execution identities; see
[ADR-012](../decisions/ADR-012-workspace-owned-local-workers.md).


## Build and pairing references

macOS package:

~~~text
bash scripts/build-workspace-macos.sh
~~~

Real desktop-to-Cloud smoke:

~~~text
CONCLAVE_ENROLLMENT_TOKEN=... bash scripts/test-workspace-cloud-connection.sh
~~~

For historical ownership decisions, see [Architecture v7](ARCHITECTURE_V7.md)
and [V7 Implementation Audit](V7_IMPLEMENTATION_AUDIT.md). New runtime work
starts from [Architecture v8](ARCHITECTURE_V8.md) and [ADR-018](../decisions/ADR-018-generic-cli-worker-engine-and-tool-profiles.md).


## Workspace authentication and transport

The target desktop ownership/connection model is defined by
[ADR-013](../decisions/ADR-013-desktop-auth-and-dual-transport.md) and the
[implementation plan](../roadmaps/WORKSPACE_AUTH_TRANSPORT_IMPLEMENTATION.md).
WebSocket remains the preferred runtime transport; HTTPS long-poll is the
fallback. AX is not required for normal Workspace repair or registration.

## Desktop lifecycle

The canonical Workspace desktop lifecycle is defined by
[ADR-014](../decisions/ADR-014-workspace-desktop-lifecycle.md) and its
[implementation plan](../roadmaps/WORKSPACE_DESKTOP_LIFECYCLE_IMPLEMENTATION.md).
The product distinguishes Sign in, Connect/Disconnect Workspace, Lock/Unlock,
Release ownership, Sign out, and Reset. These actions must not be aliases for
one another.


## Architecture v8 local runtime refinement

Conclave Workspace launches one generic standalone CLI Worker Engine process
per assignment/probe by default. Product-visible ChatGPT/Gemini rows remain
Logical Workers. Official signed Tool Profile Releases map those identities to
supported Provider CLI behavior. New normal CLI integrations should be added
through the Cloud Worker catalog and Tool Profile releases when Profile v1 can
express them. Existing v2 provider-specific binaries are migration-only.
