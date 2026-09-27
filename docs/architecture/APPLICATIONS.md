# Conclave AX Applications

**Status:** Current v7 product/application boundary; production release gates remain open

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

Conclave AX communicates only with Conclave Cloud.

The canonical execution-capacity destination in AX is **Workspaces**. Workers
appear inside their owning Workspace rather than as an independent top-level
page. See the [Workspaces UX and data contract](WORKSPACES_UX_CONTRACT.md).

Home summarizes Projects, Workspaces, and locally ready Workers. Both the
Workspace count and Ready Workers count open `/workspaces`; AX does not expose
a global Worker inventory. Getting Started guides users to add a Workspace,
configure Workers in the Conclave Workspace desktop app, and create a Project.
Authentication and local readiness problems direct users back to that desktop
runtime.

Workspace-owned Worker inventory remains visible in AX, but the normal
Workspaces surface is moving to an operationally read-only model. Pairing,
recovery, local Worker lifecycle, credentials, permissions, and runtime
connection management belong to Conclave Workspace. Project/Workstream
authorization remains a Cloud/AX concern. Existing remote scheduling-control
APIs may remain temporarily for compatibility/internal use while their product
surface is retired.

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
- Worker Type/adapter catalog and signed package registry;
- synchronized configured Worker inventory;
- Project/Workstream Worker authorization;
- assignment scheduling;
- audit/evidence;
- artifacts.

Conclave Cloud never executes an external AI/model/tool directly.

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
- Worker adapter install/update/rollback;
- local permission approval;
- child-process supervision;
- assignment execution/cancellation;
- logs, diagnostics and updates;
- minimal local UX.

One normal Conclave Workspace installation runs per machine/OS-user installation.

Configured Workers are created/authenticated locally and belong to exactly one Workspace. Safe Worker inventory is synchronized to Cloud for scheduling and remote control.

Conclave Workspace is background-first. Its GUI is intentionally limited to
local concerns such as account/session state, Workspace registration/recovery,
Workers, provider authentication, permissions, current local work, connection
mode, diagnostics and updates. Human desktop authentication is distinct from
the machine runtime credential; provider credentials remain local.

Projects, Workstreams, Discuss, Work orchestration and Project administration remain in Conclave AX.

## 4. Worker Types / adapter packages

**Suggested path:** `workers/<worker-type-id>`

A Worker Type is a signed integration adapter definition, not a user-installed application and not an AI model.

Examples:
- Codex;
- Antigravity;
- Claude Code;
- OpenAI API;
- Gemini API;
- Anthropic API;
- Ollama.

Adapter packages are installed/verified by Conclave Workspace and execute out-of-process as child processes.

One adapter package/version may serve many local configured Workers of the same Worker Type.

A configured Worker:
- belongs to exactly one Workspace;
- has one local authentication/configuration context;
- may define default/allowed models;
- is synchronized to Cloud as safe metadata/readiness;
- does not connect directly to Conclave Cloud.

Models such as GPT, Gemini Pro/Flash or Claude Sonnet/Opus are configuration, not separate Worker Types.

## Product vocabulary

Use:
- Conclave AX;
- Workspaces for the top-level AX execution-capacity page;
- Workspace;
- Worker;
- Worker Type when referring to adapter/catalog infrastructure;
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

See [Architecture v7](ARCHITECTURE_V7.md) and [V7 Implementation Audit](V7_IMPLEMENTATION_AUDIT.md).


## Workspace authentication and transport

The target desktop ownership/connection model is defined by
[ADR-013](../decisions/ADR-013-desktop-auth-and-dual-transport.md) and the
[implementation plan](../roadmaps/WORKSPACE_AUTH_TRANSPORT_IMPLEMENTATION.md).
WebSocket remains the preferred runtime transport; HTTPS long-poll is the
fallback. AX is not required for normal Workspace repair or registration.
