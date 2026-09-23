# Conclave AX Applications

**Status:** Normative for Architecture v4

Conclave AX has three primary applications and one extension type.

## 1. Conclave Studio

**Path:** `apps/studio`

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

Studio is web-first in v4. Desktop Studio is not a product requirement.

Studio communicates only with Cloud.

## 2. Conclave Cloud

**Path:** `apps/cloud` after v4 migration  
**Current transitional path:** `apps/worker`

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
- Host Gateway;
- Worker catalog/package registry;
- Credential Profile authorization;
- assignment scheduling;
- audit/evidence;
- artifacts;
- budgets/usage.

Cloud never executes an external AI/model/tool directly.

## 3. Conclave Host

**Path:** `apps/host` after v4 migration

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
- Cloud connection;
- Worker installation/update/removal;
- secure local credentials;
- assignment journal;
- Worker process supervision;
- repository/filesystem permissions;
- logs;
- Host updates;
- minimal local UX.

One Host is installed per machine. Users do not log in/out of Host accounts; Cloud authorization determines who may use the Host.

## 4. Workers

**Path:** `workers/<worker-id>` after v4 migration  
**Current path:** `workers/*`

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

Workers are language-independent executable packages. First-party Workers use Dart when practical.

## Removed v4 product concepts

Architecture v4 does not expose these as product/domain concepts:
- Agent;
- Agent Engine;
- Plugin;
- configured Worker instance;
- Connection.

Their useful responsibilities are represented by Host, Worker, Credential Profile, and Assignment.
