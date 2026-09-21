# Conclave AX Applications

**Status:** Normative for Architecture v3

## Deployable applications

### Studio
Path: `apps/flutter_app` (planned rename to `apps/studio`)

Technology:
- Flutter;
- Dart.

Purpose:
- user authentication;
- Workspaces/Projects/Chats;
- Run progress/results;
- centralized Agent/Worker/Plugin management.

### Cloud
Path: `apps/worker`

Technology:
- TypeScript;
- Cloudflare Workers/Workflows/Durable Objects/D1/R2.

Purpose:
- authoritative state and orchestration;
- multi-user API;
- Agent Gateway;
- plugin registry;
- audit/evidence.

### Agent App
Path: `apps/agent_app`

Technology:
- Flutter;
- Dart.

Purpose:
- local host setup and monitoring UI.

### Agent Engine
Path: `apps/agent_engine`

Technology:
- Dart native executable.

Purpose:
- long-running host service;
- Cloud connection;
- assignments;
- plugin/worker process supervision;
- local credentials/runtime;
- updates.

## Non-app packages

Core, protocols, persistence, security, orchestration, and plugin SDKs remain libraries and must not be treated as deployable applications.
