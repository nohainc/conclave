# Conclave Protocol Boundaries

**Status:** Current V7 architecture contract  
**Applies to:** Conclave AX, Conclave Cloud, Conclave Workspace, and Worker adapters

Conclave has three protocol boundaries. They share domain vocabulary, but each
boundary has its own endpoints, authentication, transport, versioning, and wire
schemas.

```text
Conclave AX  <->  Conclave Cloud
                 Human Product Protocol

Conclave Workspace  <->  Conclave Cloud
                       Workspace Runtime Protocol

Conclave Workspace  <->  Worker adapter process
                       Local Adapter Protocol
```

The arrows show the three product/runtime boundaries. The Human Product
Protocol is primarily the AX-to-Cloud surface and includes only the
owner-authenticated Workspace management routes explicitly defined by
ADR-013/ADR-014. Cloud may implement both human-facing endpoints and the
Workspace Gateway, but those are separate surfaces with separate
authentication and contracts.

## 1. AX ↔ Cloud — Human Product Protocol

**Endpoints:** Conclave AX and Conclave Cloud's human-facing API/realtime
endpoints.  
**Authentication:** a human user session.  
**Transport:** HTTPS APIs and browser realtime connections.  
**Contract ownership:** Cloud publishes the API/read-model contracts consumed
by AX; AX owns human-facing product behavior.

This protocol carries Projects, Workstreams, collaboration, Workstream
execution policy, Workspace grants, human-readable Workspace/Worker inventory,
results, artifacts, and audit/read models. AX uses it to request product
actions and display Cloud-authoritative state.

AX MUST NOT open a Workspace Runtime Protocol connection, construct runtime
messages, or authenticate as a Workspace machine. AX cannot dispatch an
assignment directly to a Workspace or adapter. Cloud authorizes and schedules
work, then dispatches it through the Workspace Runtime Protocol.

The Workspace desktop's owner-authenticated account and registration requests
remain explicitly scoped management routes on Cloud's human-authenticated HTTP
surface, as defined by ADR-013/ADR-014. They use the Human Product Protocol's
HTTPS management surface, not the Workspace Runtime Protocol. Those requests
do not carry runtime assignments and do not make the Workspace desktop an AX
client. The separate runtime credential and Workspace Runtime Protocol remain
required for machine participation.

## 2. Workspace ↔ Cloud — Workspace Runtime Protocol

**Endpoints:** the Conclave Workspace runtime and Cloud's Workspace Gateway.  
**Authentication:** a machine runtime credential bound to one Workspace
runtime.  
**Transport:** WSS is primary; HTTPS long-poll is the functional fallback.  
**Contract ownership:** the versioned Workspace Runtime Protocol schema and
Cloud Gateway implementation.

This protocol carries runtime hello/heartbeat, safe Worker inventory and
status, assignment delivery/acknowledgement/progress/results/errors, and
cancellation. Cloud scheduling and Workspace execution use this boundary;
transport choice does not change assignment semantics.

Cloud-facing Worker Type IDs are product concepts. Project and Workstream
policy, Workspace inventory, and assignment snapshots use IDs such as
`chatgpt` and `gemini`; adapter package IDs are not accepted in this protocol.
Cloud forwards the selected product Worker Type ID unchanged. Workspace
validates it against the selected local Worker slot, then resolves the local
adapter package through its first-party descriptor registry. AX therefore
does not need to know which adapter package implements a product Worker.

Only Conclave Workspace speaks this protocol as a client. Cloud's Workspace
Gateway is its server. Conclave AX is not a runtime client. Worker adapters are
not runtime clients and MUST NOT connect to Cloud, invoke Workspace Gateway
routes, or receive the Workspace runtime credential. Workspace translates
between runtime messages and local adapter frames.

The current implementation is named
`conclave.workspace-runtime-protocol` and is defined in
`packages/host-protocol/src/workspace-runtime.ts`. Keep its runtime identity,
authentication, transport negotiation, and assignment envelopes inside this
boundary.

## 3. Workspace ↔ Adapter — Local Adapter Protocol

**Endpoints:** Conclave Workspace's per-assignment process supervisor and one
local adapter child process.  
**Authentication:** local process admission; no Cloud or human session
credential is part of this protocol.  
**Transport:** versioned NDJSON over the child's stdin/stdout.  
**Contract ownership:** Workspace defines the local adapter protocol;
first-party and third-party adapters implement it.

This protocol is limited to adapter initialization, readiness probes,
execution, and normalized progress, results, and errors. Workspace owns
process lifetime, filesystem CWD, permissions, cancellation, and Cloud synchronization. The
adapter may invoke its configured provider CLI or provider API, but MUST NOT
speak either Cloud-facing protocol or communicate directly with Conclave
Cloud. In particular, it must not receive Cloud URLs, runtime credentials,
Workspace Gateway envelopes, Cloud assignment authority, provider tokens, or
account secrets as protocol fields. Any explicitly approved local tool input
must use a bounded allowlisted non-secret field.

The current V7 Local Adapter Protocol is version 2.0 and uses
`initialize.request/result`, `probe.request/result`, `execute.request`,
`progress`, `result`, and `error`. Every exchange carries a `requestId`.
`probe.result` contains `ready`, nullable `toolVersion`, `checkKind`, and
bounded `issues[]`. Optional probe settings are restricted to a safe endpoint
URL, organization ID, and project ID; provider tokens and account secrets are
not represented. Frames reject unknown fields, bound strings and arrays, and
must fit within 1 MiB. The same contract test runs against fake ChatGPT/Codex
and Gemini/Antigravity adapters. First-party issue codes are normalized by
Workspace to the stable readiness reasons `cli_not_found`,
`unsupported_cli_version`, `authentication_required`,
`execution_test_failed`, and `ready`; provider stderr is never a UI message.
Antigravity may return `permission_configuration_required` as an additional
safe local diagnostic for a requested setup/manual execution test.
The schema is specified by
`packages/worker-manifest/src/adapter-v7.ts` and implemented by the Workspace
process supervisor. Changes require a versioned Local Adapter Protocol change
and do not change either Cloud-facing protocol.

## Shared canonical domain vocabulary

These names describe Conclave domain values used across boundaries:

| Canonical name | Meaning |
| --- | --- |
| `ProjectId` | Stable identity of a collaboration Project |
| `WorkstreamId` | Stable identity of a persistent unit of work |
| `WorkspaceId` | Cloud identity of an enrolled machine Workspace |
| `WorkspaceRuntimeId` | Identity of the connected machine runtime |
| `WorkerId` | Identity of one Workspace-owned local Worker slot/configuration |
| `WorkerTypeId` | Stable product integration type, such as `chatgpt` or `gemini` |
| `AssignmentId` | Identity of one immutable unit of scheduled execution |
| `RunId` | Identity of the orchestration Run containing work |
| `TaskId` | Identity of one task within a Run |
| `WorkerReadiness` | Domain readiness state used for scheduling and display |
| `AssignmentStatus` | Domain lifecycle state for scheduled execution |
| `ErrorCode` | Stable machine-readable failure category |

These are canonical domain concepts, not a shared message envelope. At the
wire boundary, each protocol owns its own versioned schemas, required fields,
field names, validation, and authentication context. A value such as
`AssignmentId` may appear in multiple protocol payloads, but a Human Product
Protocol request, Workspace Runtime Protocol frame, and Local Adapter Protocol
frame are never interchangeable. Do not import one protocol's envelope or
transport into another boundary to reuse these names.

The TypeScript/Dart or service-specific representations may remain distinct
while carrying the same canonical meaning. Changes to a canonical concept must
be reviewed across each affected boundary; this does not authorize merging the
wire contracts.

## Boundary ownership matrix

| Flow | Client | Server/process peer | Protocol | Credentials allowed |
| --- | --- | --- | --- | --- |
| Product and collaboration actions/read models | Conclave AX | Cloud human API/realtime | Human Product Protocol | Human session |
| Desktop owner/account management | Workspace management UI | Cloud management routes | Human Product Protocol, HTTPS management surface | Human session |
| Inventory, assignments, progress, cancellation | Workspace runtime | Cloud Workspace Gateway | Workspace Runtime Protocol | Workspace runtime credential |
| Local setup, execution, progress, result | Workspace supervisor | Adapter child process | Local Adapter Protocol | Bounded non-secret tool settings; no provider tokens or account secrets |

Cloud may translate and persist domain state between its product API and
Workspace Gateway. Workspace may translate between its Cloud runtime client
and adapter child process. Neither translation forwards a wire envelope
unchanged across a boundary.

## Current schema locations

- Human Product Protocol: AX `apps/app/lib/src/studio/studio_data.dart` and
  `apps/app/lib/src/realtime/realtime_client.dart`; Cloud
  `apps/cloud/src/routes/handlers.ts` and `apps/cloud/src/realtime-gateway.ts`.
- Workspace Runtime Protocol: Workspace
  `apps/host/lib/cloud_connection.dart`; schema
  `packages/host-protocol/src/workspace-runtime.ts`; Cloud
  `apps/cloud/src/workspace-gateway.ts`.
- Local Adapter Protocol: Workspace `apps/host/lib/worker_executor.dart` and
  `apps/host/lib/v7_adapter_protocol.dart`; adapter schema
  `packages/worker-manifest/src/adapter-v7.ts`.
- Canonical domain model: domain entities in `packages/core/src` and the
  canonical vocabulary in this document; wire validators remain protocol-owned.
