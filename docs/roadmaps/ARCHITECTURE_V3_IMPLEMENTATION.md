# Architecture v3 Implementation Roadmap

This roadmap supersedes Architecture v2 implementation phases where they conflict with the Flutter/Dart Agent design.

## P0 — Stabilize main

- fix all current Prettier failures;
- fix Flutter analyzer findings;
- run full TypeScript lint/typecheck/tests;
- run Flutter analyze/tests;
- run Wrangler startup checks.

**Exit:** CI green before migration work.

## P1 — Documentation and architecture freeze

- make Architecture v3 normative;
- replace top-level legacy architecture/roadmap;
- mark ConnectionResource/Local Runtime/direct-provider specs superseded;
- add Architecture v3 ADR;
- document apps and stack.

**Exit:** one architecture source of truth.

## P2 — Schema-first cross-language protocols

Define canonical schemas for:
- Cloud <-> Agent Engine;
- Agent App <-> Agent Engine;
- Agent Engine <-> Worker Plugin.

Generate/validate:
- TypeScript models;
- Dart models.

Do not hand-maintain two independent protocol definitions.

**Exit:** TS and Dart compatibility tests use identical fixture messages.

## P3 — Dart Agent Engine skeleton

Create a Dart console application:
- config;
- logging;
- lifecycle;
- local storage paths;
- graceful shutdown;
- assignment journal interface;
- IPC server interface;
- Cloud client interface.

Compile AOT on macOS/Linux/Windows CI.

**Exit:** self-contained engine executable starts and stops cleanly.

## P4 — Flutter Agent App skeleton

Create Flutter desktop Agent App:
- engine status;
- Cloud connection status;
- enrollment screen;
- Workers/Plugins placeholders;
- logs/settings shell.

Agent App starts/connects to the Agent Engine through local IPC.

**Exit:** closing Agent App leaves Engine running.

## P5 — Local IPC

Implement authenticated local IPC:
- Engine discovery;
- status;
- start/restart;
- logs;
- settings;
- enrollment commands.

Prefer Unix sockets/named pipes long-term; loopback authenticated transport allowed initially.

**Exit:** UI and Engine communicate without Cloud dependency.

## P6 — Cloud Agent Gateway parity

Port the current Agent Cloud client semantics to Dart:
- enrollment;
- durable machine identity;
- WebSocket;
- protocol negotiation;
- heartbeat;
- reconnect/backoff;
- desired-state sync;
- assignment acknowledgement.

Cloud stays TypeScript.

**Exit:** Dart Engine appears online in Cloud and survives reconnect.

## P7 — Dart assignment journal/reconciliation

Implement persistent:
- accepted assignments;
- progress;
- terminal result;
- reconnect reconciliation;
- idempotency.

**Exit:** Engine restart during an assignment does not corrupt Cloud state.

## P8 — Worker Plugin Protocol

Define language-independent executable plugin protocol.

Implement in Dart Engine:
- spawn;
- initialize;
- configure;
- health;
- execute;
- progress;
- result;
- cancel;
- shutdown;
- crash/restart handling;
- bounded stdout/stderr.

**Exit:** Echo plugin executes out-of-process.

## P9 — Plugin package/install manager

Port plugin lifecycle:
- registry query;
- compatibility;
- download;
- digest/signature verify;
- install side-by-side;
- enable/disable;
- update;
- rollback;
- garbage collection.

**Exit:** Cloud Worker configuration automatically installs required plugin.

## P10 — Deterministic Dart plugin

Implement first-party Echo/Test plugin in Dart.

Use it for full Cloud -> Agent Engine -> Plugin -> Cloud tests.

**Exit:** no TypeScript Agent required for deterministic assignment E2E.

## P11 — Runtime capability library in Dart

Build reusable Agent Engine utilities:
- process spawning;
- process-tree cancellation;
- filesystem boundaries;
- Git helpers;
- safe command execution;
- output limits;
- hashing;
- artifact creation.

Use safe behavior from current Local Runtime as requirements.

**Exit:** security regression tests pass.

## P12 — Codex Worker Plugin

Implement Dart Codex plugin:
- discover CLI;
- authentication readiness;
- non-interactive execution;
- streaming/progress;
- structured result;
- cancellation;
- isolated session/workspace.

**Exit:** real Codex assignment through Dart Engine.

## P13 — Claude Code Worker Plugin

Same plugin protocol and lifecycle as Codex.

**Exit:** Worker switching requires only configuration.

## P14 — API Worker Plugins

Implement/migrate:
- OpenAI;
- Anthropic;
- later Gemini.

Prefer Dart HTTP implementation where simple.

If an official JS SDK provides material functionality that would be expensive/risky to reproduce, keep that plugin as a bundled Node executable implementing the same plugin protocol.

**Exit:** Cloud never directly calls model APIs.

## P15 — Interactive web AI Worker Plugin

Port current web-AI session/relay behavior behind the Worker Plugin protocol.

Cloud hosts only public connector/mailbox relay.

Agent Engine owns the Worker assignment/session.

**Exit:** web subscription Worker completes a candidate Attempt.

## P16 — Agent App functional UI

Implement:
- enrollment;
- Engine status;
- Agent version/update;
- installed plugins;
- configured Workers;
- authentication readiness;
- assignment list/progress;
- logs;
- permissions;
- settings.

**Exit:** normal host setup requires no terminal.

## P17 — Agent Engine self-update

Implement signed releases:
- check;
- download;
- verify;
- stage;
- drain;
- restart;
- health;
- rollback.

Agent App displays update state.

**Exit:** Engine safely updates between test releases.

## P18 — Agent App update/distribution

Package Flutter Agent App for macOS first.

Bundle/install Agent Engine.

Then add Windows/Linux.

**Exit:** fresh machine can install one package and enroll.

## P19 — Studio architecture cleanup

Keep Studio Flutter.

Refactor to chat-first stores:
- Auth/Workspace;
- Project;
- Chat;
- Run;
- Agent;
- Worker;
- Plugin.

Remove remaining demo/static assumptions.

**Exit:** Studio controls Cloud only.

## P20 — Multi-user authentication

Complete:
- login;
- sessions;
- Workspaces;
- roles;
- invitations;
- Project access;
- audit.

**Exit:** tenant isolation tests pass.

## P21 — Cloud/Agent management UI

Studio manages:
- enrolled Agents;
- Workers;
- Worker Plugin catalog;
- plugin versions;
- update channels;
- assignment status.

Agent App manages only the local host.

**Exit:** user can configure fleet centrally.

## P22 — Multi-worker / multi-Agent orchestration

Run:
- parallel research;
- synthesis;
- implementation;
- review;
- verification

across multiple Agents/Workers.

**Exit:** same execution policy works regardless of Worker implementation language.

## P23 — Forge E2E on Dart Agent Engine

End-to-end repository scenario:
- Chat request;
- Goal/Run;
- research;
- plan;
- Codex implementation;
- independent review;
- tests;
- verification;
- result in Chat.

**Exit:** no TypeScript Agent process participates.

## P24 — Retire TypeScript Agent

After parity:
- remove `apps/agent`;
- remove Agent-specific Node runtime dependencies;
- archive migration notes;
- adjust pnpm CI;
- add Dart/Flutter Agent CI.

**Exit:** host execution stack is Flutter/Dart + plugin executables.

## P25 — Supply-chain and sandbox hardening

- plugin signing;
- Agent App/Engine signing;
- permission enforcement;
- plugin sandboxing;
- credential storage;
- update key rotation;
- threat model;
- dependency scanning.

**Exit:** no unresolved release-blocking security findings.

## P26 — v0.1 release gate

Required:
- Studio Flutter web/desktop;
- Agent App Flutter;
- Agent Engine Dart native;
- Cloud TypeScript/Cloudflare;
- signed plugin registry;
- Codex + one API plugin;
- multi-worker orchestration;
- multi-user tenancy;
- E2E Forge;
- safe updates/rollback;
- full CI green.
