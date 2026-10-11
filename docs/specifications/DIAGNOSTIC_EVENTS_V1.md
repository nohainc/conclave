# Diagnostic Events v1

Conclave execution diagnostics use one bounded, provider-neutral event shape
across AX, Cloud, the Workspace service, the CLI Worker Engine, Tool Profiles,
and provider adapters. The event is evidence for correlation and triage; it is
not conversational output and must never contain user prompts or provider
responses.

## Envelope

Each event has `schemaVersion: 1`, a generated `eventId`, a UTC `timestamp`,
and the execution identifiers that are available at the emitting boundary:
`requestId`, `assignmentId`, `workspaceId`, `workspaceRuntimeId`, `workerId`,
`runId`, `taskId`, and `attemptId`. `component`, `operation`, `stage`,
`severity`, `retryable`, and an optional normalized `errorCode` describe the
failure or lifecycle transition. Existing request, run, and assignment IDs
remain authoritative; the event ID only identifies the diagnostic record.

The public TypeScript contract is
`packages/protocol/src/diagnostic-events.ts`. The Dart runtime contract is
`packages/conclave_worker_protocol/lib/src/diagnostic_events.dart`.

## Context allowlist

`context` is a closed set of bounded scalar fields. It may contain versions,
profile identifiers and release numbers, provider tool name/version, protocol
stage, failure layer, process exit code, duration, transport state, status,
model/effort identifiers, catalog revision, selection source, HTTP status,
line byte count, and a recovery flag. Unknown keys, nested objects, prompts,
responses, file contents, credentials, environment variables, and local
filesystem paths are rejected or dropped at the boundary.

Diagnostic stores remain bounded JSONL logs with rotation. Report assembly
reads a capped number of safe records and reports completeness explicitly when
Workspace evidence is unavailable. Cloud and AX evidence already retained by
their execution/event projections remains usable after a Workspace disconnect.

## Lifecycle stages

Events should preserve the useful sequence across `admission`, `transport`,
`worker_start`, `provider_session`, `provider_execution`, `result`, and other
specific stages used by the execution boundary. Emit the final normalized
error in addition to preceding lifecycle events. Logging failures must never
change assignment or execution behavior.

## Privacy and retention

Diagnostic collection is event-driven and bounded; it does not run a continuous
process sampler. Exported Workspace diagnostics include safe worker records,
assignment correlation, version/profile evidence, and a completeness marker.
User Work Root and provider executable paths are intentionally represented as
configuration state rather than exported filesystem paths.
