# Conclave AX Applications

**Status:** Normative for Architecture v5

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
- Projects and Chats;
- Goals/Runs;
- Workspace management;
- Worker catalog;
- Accounts / Credential Profiles;
- usage/cost;
- approvals and evidence.

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
- Worker catalog/package registry;
- Credential Profile authorization;
- assignment scheduling;
- audit/evidence;
- artifacts;
- budgets/usage.

Conclave Cloud never executes an external AI/model/tool directly.

## 3. Workspace runtime application

**Path:** `apps/host` (runtime implementation; user-facing product term is Workspace)

**Technology**
- Flutter;
- Dart;
- native desktop application.

**Targets**
- macOS first;
- Windows;
- Linux.

**Purpose**
- one Workspace runtime identity;
- pairing;
- Cloud WebSocket connection;
- Worker installation/update/removal;
- secure local credentials;
- assignment journal;
- Worker process supervision;
- repository/filesystem permissions;
- logs;
- Workspace runtime updates;
- minimal local UX.

One Workspace runtime is installed per machine. Humans do not sign into or switch accounts inside the runtime; Cloud authorization and Project Workspace Grants determine which Projects may execute through it.

## 4. Workers

**Path:** `workers/<worker-id>`

A Worker is an installable execution integration.

Examples:
- Codex;
- Claude Code;
- OpenAI;
- Anthropic;
- Ollama;
- Web AI;
- Git/Test.

Workers execute out-of-process under Workspace runtime supervision.

A Worker does not connect directly to Conclave Cloud and does not hold a Workspace runtime credential.

Workers are language-independent executable packages. First-party Workers use Dart when practical.

## Product vocabulary

Use:
- Conclave AX;
- Workspace;
- Worker;
- Account.

Use `CredentialProfile` only as the internal/domain term for Account.

## Removed v4 product concepts

Architecture v5 does not expose:
- Conclave AX Studio as a product name;
- Agent;
- Agent Engine;
- Plugin;
- configured Worker instance;
- Connection.
