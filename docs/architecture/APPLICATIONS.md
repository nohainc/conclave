# Conclave AX Applications

**Status:** v6 baseline with proposed v7 execution/runtime changes

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
- Workspace management;
- remote Worker inventory and scheduling controls;
- approvals, evidence and artifacts.

Conclave AX is web-first in v5. Desktop distribution of the main application is not a v5 requirement. Native mobile applications may be added later.

Conclave AX communicates only with Conclave Cloud.

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
- native desktop application/runtime.

**Targets**
- macOS first;
- Windows;
- Linux;
- headless Linux/server later using the same runtime model.

**Purpose**
- one machine runtime/security identity;
- pairing and persistent Cloud connection;
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

Conclave Workspace is background-first. Its GUI is intentionally limited to local concerns such as pairing, Workers, authentication, permissions, current local work, diagnostics and updates.

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
- Execution;
- Workspace;
- Worker;
- Worker Type when referring to adapter/catalog infrastructure;
- Conclave Workspace for the machine-side application/runtime;
- credential state when referring to local authentication/readiness.

Do not expose AI Account or Credential Profile as a peer product resource.
Those terms may remain in internal/domain code while the migration is in
progress.

## Removed v4 product concepts

Architecture v5 does not expose:
- Conclave AX Studio as a product name;
- Agent;
- Agent Engine;
- Plugin;
- configured Worker instance;
- Connection.
