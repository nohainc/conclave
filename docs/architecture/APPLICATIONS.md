# Conclave AX Applications

**Status:** Normative for Architecture v4

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
- Workspaces;
- Projects and Chats;
- Goals/Runs;
- Host management;
- Worker catalog;
- Accounts / Credential Profiles;
- usage/cost;
- approvals and evidence.

Conclave AX is web-first in v4. Desktop distribution of the main application is not a v4 requirement. Native mobile applications may be added later.

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
- Host Gateway;
- Worker catalog/package registry;
- Credential Profile authorization;
- assignment scheduling;
- audit/evidence;
- artifacts;
- budgets/usage.

Conclave Cloud never executes an external AI/model/tool directly.

## 3. Conclave Host

**Path:** `apps/host`

**Technology**
- Flutter;
- Dart;
- native desktop application.

**Targets**
- macOS first;
- Windows;
- Linux.

**Purpose**
- one machine identity;
- pairing;
- Cloud WebSocket connection;
- Worker installation/update/removal;
- secure local credentials;
- assignment journal;
- Worker process supervision;
- repository/filesystem permissions;
- logs;
- Host updates;
- minimal local UX.

One Host is installed per machine. Humans do not sign into or switch accounts inside the Host; Cloud authorization determines who may use/manage the Host.

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

Workers execute out-of-process under Host supervision.

A Worker does not connect directly to Conclave Cloud and does not hold a Host machine credential.

Workers are language-independent executable packages. First-party Workers use Dart when practical.

## Product vocabulary

Use:
- Conclave AX;
- Host;
- Worker;
- Account.

Use `CredentialProfile` only as the internal/domain term for Account.

## Removed v4 product concepts

Architecture v4 does not expose:
- Conclave AX Studio as a product name;
- Agent;
- Agent Engine;
- Plugin;
- configured Worker instance;
- Connection.
