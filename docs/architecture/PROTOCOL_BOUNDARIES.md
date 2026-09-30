# Conclave Protocol Boundaries

**Status:** Current V7 architecture contract  
**Applies to:** Conclave AX, Conclave Cloud, Conclave Workspace, and Worker Packages

Conclave has three protocol boundaries. They share domain vocabulary, but each
boundary has its own endpoints, authentication, transport, versioning, and wire
schemas.

```text
Conclave AX  <->  Conclave Cloud
                 Human Product Protocol

Conclave Workspace  <->  Conclave Cloud
                       Workspace Runtime Protocol

Conclave Workspace  <->  Worker Package process
                       Local Worker Protocol
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
assignment directly to a Workspace or Worker Package. Cloud authorizes and schedules
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
`chatgpt` and `gemini`; Worker Package IDs are not accepted in this protocol.
Cloud forwards the selected product Worker Type ID unchanged. Workspace
validates it against the selected local Worker slot, then resolves the local
Worker Package through its product-to-package registry. AX therefore does
not need to know which package implements a product Worker.

Only Conclave Workspace speaks this protocol as a client. Cloud's Workspace
Gateway is its server. Conclave AX is not a runtime client. Worker Packages are
not runtime clients and MUST NOT connect to Cloud, invoke Workspace Gateway
routes, or receive the Workspace runtime credential. Workspace translates
between runtime messages and Local Worker Protocol frames.

The current implementation is named
`conclave.workspace-runtime-protocol` and is defined in
`packages/host-protocol/src/workspace-runtime.ts`. Keep its runtime identity,
authentication, transport negotiation, and assignment envelopes inside this
boundary.

## 3. Workspace ↔ Worker Package — Local Worker Protocol

**Endpoints:** Conclave Workspace's process supervisor and one Worker Package
child process.
**Authentication:** local process admission; no Cloud or human session
credential is part of this protocol.  
**Transport:** versioned NDJSON over the child's stdin/stdout.  
**Contract ownership:** Workspace defines the Local Worker Protocol;
first-party and third-party Worker Packages implement it.

This protocol carries package initialization, package-reported readiness,
execution, progress, results, errors, and cancellation. Workspace owns package
admission, process lifetime, filesystem CWD, local permissions, cancellation,
and Cloud synchronization. Workspace MUST NOT discover, version, authenticate
with, or execute a provider CLI or other provider tool directly. The Worker
Package owns all provider-specific discovery, version/authentication checks,
command construction, environment interpretation, output parsing, and
diagnostics. It may invoke its configured provider CLI or API, but MUST NOT
speak either Cloud-facing protocol or communicate directly with Conclave
Cloud. In particular, it must not receive Cloud URLs, runtime credentials,
Workspace Gateway envelopes, Cloud assignment authority, provider tokens, or
account secrets as protocol fields. Any explicitly approved local tool input
must use a bounded allowlisted non-secret field.

The current V7 Local Worker Protocol is implemented by the versioned adapter-v7
schema (versions 2.1 through 2.5) and uses
`initialize.request/result`, `probe.request/result`, `execute.request`,
`progress`, `result`, and `error`. Every exchange carries a `requestId`.
Versions 2.3 through 2.5 `probe.request` explicitly select `passive` or `live`; `probe.result`
contains that mode, package-reported `ready`, nullable safe `toolVersion`, and
structured `checks[]` with stable issue codes and bounded local diagnostics.
Versions 2.1 and 2.2 retain their legacy readiness-result shape during
migration. Optional probe settings are restricted to bounded non-secret fields.
Provider tokens and account secrets are not protocol fields. Frames reject
unknown fields, bound strings and arrays, and must fit within 1 MiB. Workspace
validates the package's bounded safe result without interpreting
provider-specific codes or raw provider output. Packages return stable readiness
codes and safe display diagnostics. Packages capture provider CLI stdout/stderr
and map it into bounded provider-neutral diagnostics. If a package exits before
returning a protocol frame, Workspace may retain a bounded, redacted tail of
the package process stderr for local diagnostics; this fallback is never sent
to Cloud. Protocols 2.4 and 2.5 `execute.request` include the remaining assignment
`timeoutMs`; the package subtracts a small cleanup grace when choosing its CLI
deadline. Readiness live tests retain their separate explicit short deadline.
Protocol 2.5 adds the Conclave `sessionPolicy` values `stateless` and
`durable_session`. Durable requests carry an opaque `sessionKey`; stateless
requests do not. Cloud and Workspace route these generic fields without
interpreting provider session IDs. Each Worker Package maps the key to its own
provider session ID in package-local storage. Provider session IDs are never
persisted by Cloud. Persistent provider processes are outside this contract;
each assignment still starts a fresh package and CLI process.
Raw provider stderr and output never become a Cloud message.
The schema is specified by
`packages/worker-manifest/src/adapter-v7.ts` and implemented by the Workspace
process supervisor and Worker Package process. Changes require a versioned
Local Worker Protocol change and do not change either Cloud-facing protocol.

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
Protocol request, Workspace Runtime Protocol frame, and Local Worker Protocol
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
| Local setup, readiness, execution, progress, result | Workspace supervisor | Worker Package process | Local Worker Protocol | Bounded non-secret settings; no provider tokens or account secrets |

Cloud may translate and persist domain state between its product API and
Workspace Gateway. Workspace may translate between its Cloud runtime client
and Worker Package process. Neither translation forwards a wire envelope
unchanged across a boundary.

## Current schema locations

- Human Product Protocol: AX `apps/app/lib/src/studio/studio_data.dart` and
  `apps/app/lib/src/realtime/realtime_client.dart`; Cloud
  `apps/cloud/src/routes/handlers.ts` and `apps/cloud/src/realtime-gateway.ts`.
- Workspace Runtime Protocol: Workspace
  `apps/host/lib/cloud_connection.dart`; schema
  `packages/host-protocol/src/workspace-runtime.ts`; Cloud
  `apps/cloud/src/workspace-gateway.ts`.
- Local Worker Protocol: Workspace `apps/host/lib/worker_executor.dart` and
  `apps/host/lib/v7_adapter_protocol.dart`; Worker Package schema
  `packages/worker-manifest/src/adapter-v7.ts`.
- Canonical domain model: domain entities in `packages/core/src` and the
  canonical vocabulary in this document; wire validators remain protocol-owned.
