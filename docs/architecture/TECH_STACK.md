# Conclave AX Technology Stack

**Status:** Current Architecture v8 implementation.

## Stack summary

| Layer | Technology |
| --- | --- |
| Conclave AX | Flutter + Dart, Web |
| Cloud | TypeScript + Cloudflare Workers |
| Conclave Workspace | Flutter + Dart desktop/background runtime |
| Local Worker Protocol | Protocol 4.0, versioned NDJSON |
| Local CLI execution | Generic Dart CLI Worker Engine + signed Tool Profiles |
| Database | Cloudflare D1 |
| Artifact and release storage | Cloudflare R2 |
| Durable orchestration | Cloudflare Workflows |
| Live Workspace connection | Durable Objects + WebSocket; HTTPS fallback |
| AX-to-Cloud boundary | Human Product Protocol over HTTPS and browser realtime |
| Workspace-to-Cloud boundary | Workspace Runtime Protocol |
| Workspace-to-Engine boundary | Local Worker Protocol 4.0 over stdin/stdout |
| TypeScript tests | Vitest |
| Dart/Flutter tests | `dart test` / `flutter test` |
| CI and deployment | GitHub Actions + Wrangler |

## Applications and runtime

Conclave AX is the human web application. Conclave Cloud owns identity,
authorization, Spaces, Threads, scheduling, Profile releases, and
persistence. Conclave Workspace owns local Work Root data, logical Worker
readiness, Profile verification/cache, Engine supervision, permissions,
cancellation, and diagnostics.

Each assignment or probe runs through the generic CLI Worker Engine as a
separate process. The Engine starts a locally installed provider CLI using
structured arguments. Workspace owns the process tree and applies deadlines,
output limits, cancellation, and cleanup. Provider authentication remains with
the provider CLI; Conclave Cloud never receives provider credentials.

The Engine plus Profile boundary is defined by [Architecture v8](ARCHITECTURE_V8.md),
[ADR-018](../decisions/ADR-018-generic-cli-worker-engine-and-tool-profiles.md),
and the [Tool Profile v1 specification](../specifications/TOOL_PROFILE_V1.md).

## Contract boundaries

Human Product, Workspace Runtime, and Local Worker Protocol contracts have
separate owners, endpoints, authentication, versions, and wire schemas. Keep
one canonical schema source per boundary and generate language bindings from
it. Shared domain IDs do not justify sharing transport envelopes.

See [Protocol Boundaries](PROTOCOL_BOUNDARIES.md).

## Implementation principles

- Keep D1 persistence owned by Cloud route and service modules; keep Workspace local persistence in the Workspace data directory.
- Prefer explicit domain types, state machines, immutable assignment snapshots,
  and idempotent commands.
- Keep scheduling authorization in Cloud and process/filesystem enforcement in
  Workspace and Engine.
- Keep logs, output, artifacts, and diagnostics bounded and redact secrets.
- Use platform-specific code only for actual OS behavior.
- Do not add infrastructure or providers without a concrete product requirement.

## Storage and secrets

D1 stores structured metadata and state. R2 stores large immutable artifacts
and releases. Local provider credentials remain in the provider's secure
configuration. Never write plaintext credentials to D1, assignment payloads,
logs, or artifacts.
