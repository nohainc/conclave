# Conclave AX Technology Stack

**Status:** Normative for Architecture v3

## Stack summary

| Layer | Technology |
| --- | --- |
| Studio | Flutter + Dart |
| Agent App | Flutter + Dart |
| Agent Engine | Dart native executable |
| Cloud | TypeScript + Cloudflare |
| Worker Plugin protocol | language-independent JSON-RPC / structured messages |
| First-party Worker Plugins | Dart where practical |
| Cloud database | Cloudflare D1 |
| Large artifacts/packages | Cloudflare R2 |
| Durable orchestration | Cloudflare Workflows |
| Live Agent connections | Durable Objects + WebSocket |
| Web hosting | Cloudflare Workers Static Assets |
| TypeScript tests | Vitest |
| Dart/Flutter tests | dart test / flutter_test |
| TypeScript quality | TypeScript, ESLint, Prettier |
| Flutter/Dart quality | flutter analyze / dart analyze |
| CI/CD | GitHub Actions |
| Cloud deployment | Wrangler |

## Why Flutter/Dart on user/host side

Flutter is used for both user-facing desktop applications:
- Studio;
- Agent App.

Benefits:
- one desktop UI codebase;
- macOS/Windows/Linux support;
- future mobile reuse;
- compiled native client;
- consistent design system.

Dart is used for Agent Engine because:
- shares models/protocols with Flutter apps;
- compiles to a self-contained native executable;
- supports filesystem/network/process work;
- avoids requiring Node.js on every host;
- allows the UI and engine to share Dart packages.

## Why separate Agent App and Agent Engine

The Flutter application is a UI lifecycle.

The Agent Engine is a service lifecycle.

They must be separate OS processes so:
- closing Studio/Agent UI does not stop work;
- UI crashes do not kill active assignments;
- Engine can start at login/boot;
- Engine can update/restart independently;
- plugin crashes remain isolated.

## Why not Flutter for the Agent Engine

The Agent Engine uses Dart, not Flutter.

Flutter adds rendering/platform UI infrastructure that a headless service does not need.

## Why TypeScript in Cloud

Cloudflare's primary ecosystem is JavaScript/TypeScript.

TypeScript is used for:
- APIs;
- orchestration;
- authentication/authorization;
- plugin registry;
- Agent Gateway;
- durable workflow integration.

Do not introduce a separate conventional Node server unless Cloudflare limits require one.

## Worker Plugins

Worker Plugins are not tied to Dart.

Protocol first; language second.

The v1 protocol should support:
- initialize;
- health;
- configure Worker;
- start assignment;
- progress;
- result;
- error;
- cancel;
- shutdown.

Preferred v1 transport:
- JSON-RPC over stdin/stdout.

This makes plugin execution:
- easy to spawn;
- port-free;
- firewall-free;
- language-independent.

## First-party plugin guidance

Prefer Dart when integration is simple:
- Codex CLI;
- Claude Code CLI;
- Git;
- shell/test runner;
- straightforward HTTP APIs.

Use another language when its ecosystem materially reduces complexity.

Do not rewrite an official SDK merely to keep a plugin in Dart.

## Shared contracts

Cloud contracts are defined in TypeScript.

Client/Agent contracts need generated Dart models from one schema source.

Architecture v3 should converge on a schema-first protocol source such as JSON Schema/OpenAPI where appropriate, with generated TypeScript and Dart bindings.

Do not hand-maintain equivalent protocol models indefinitely.

## Storage

### D1
Use for:
- users/workspaces/memberships;
- projects/chats/messages;
- goals/runs/tasks/attempts;
- Agents;
- Workers;
- plugin registry metadata;
- assignments;
- findings/verifications;
- usage/audit.

### R2
Use for:
- large artifacts;
- logs;
- model outputs retained as artifacts;
- diffs;
- screenshots;
- CI output;
- Worker Plugin packages;
- Agent App/Engine release packages.

## What we deliberately do not add

Not currently required:
- PostgreSQL;
- Redis;
- Kafka;
- Kubernetes;
- Next.js/React;
- Electron;
- Python backend;
- Rust Agent Engine.

These can be reconsidered only if measured requirements justify them.
