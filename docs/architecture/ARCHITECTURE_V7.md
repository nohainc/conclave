# Conclave AX Architecture v7 — Workspace Runtime and Worker Executables

**Status:** Current architecture and active implementation target. V7 ownership, scheduler, E2E path, V6 compatibility retirement, and public-key release trust are implemented; production runtime gates remain open.
**Date:** 2026-09-26  
**Builds on:** Architecture v6 Workstreams + ADR-011 filesystem model  
**Primary decision:** [ADR-012](../decisions/ADR-012-workspace-owned-local-workers.md)

**Current first-party product catalog:** [ADR-015](../decisions/ADR-015-first-party-worker-v1-contract.md)  
**Accepted local runtime target:** [ADR-017](../decisions/ADR-017-standalone-dart-worker-executables.md) / [Worker Runtime v2](WORKER_RUNTIME_V2.md)

> **Runtime convergence status:** Worker Runtime v2 is the normative first-party
> architecture: signed standalone Dart console executables, Local Worker
> Protocol 3.0, and provider CLI ownership inside each Worker. All Worker
> Package/adapter-specific implementation detail and Protocol 2.x flows below
> describe historical Node migration machinery, not instructions for new
> runtime work. The assignment path still uses legacy V7 adapter machinery;
> end-to-end acceptance remains open. Workspace does not probe provider CLIs.

## 1. Executive decision

V7 is the sole current Worker ownership architecture. It is not yet the
implemented baseline: Phase 5 production Worker acceptance, Phase 6 full
failure/security acceptance, and Phase 7 native macOS `.app` updater recovery
remain open. See the [current implementation audit](V7_IMPLEMENTATION_AUDIT.md)
and [release gates](../roadmaps/ARCHITECTURE_V7_COMPLETION.md).

v7 keeps the product model already established by the current application:

```text
Conclave AX
  -> Projects
       -> Workstreams
            -> Discuss
            -> Work
  -> Workspaces
       -> Workspace
            -> Workers
```

The execution implementation becomes simpler and more machine-native:

> **Workers are configured locally on exactly one Conclave Workspace and synchronized to Cloud as safe execution inventory.**

The user installs one machine-side product:

> **Conclave Workspace**

There are no separately installed Worker applications.

Conclave Workspace manages signed Worker releases and launches them as isolated child processes for readiness and assignments. Worker Runtime v2 keeps Architecture v7 and defines independently versioned standalone Dart console executables for ChatGPT and Gemini. Workspace manages installation, activation, update and rollback; each Worker owns provider CLI discovery, probing, and execution.

## 2. Product mental model

The complete mental model should fit in four lines:

> **Project** = collaboration boundary.  
> **Workstream** = persistent unit of work and local working directory.  
> **Workspace** = machine where AI can execute.  
> **Worker** = locally configured AI/tool identity on that machine.

For the first-party v1 product, each Workspace has exactly one stable ChatGPT
slot implemented by a Codex-backed ChatGPT Worker and one stable Gemini slot
implemented by an agy-backed Gemini Worker. Provider authentication and
billing mode belong to the local CLI and all interaction with it belongs to its Worker. This
catalog does not include direct provider API Workers or other integrations.
The broader V7 integration list below documents implementation and
compatibility scope, not the supported v1 product catalog.

The user does not need to understand:

- Worker Packages;
- Local Worker Protocol;
- credential profiles;
- AI Accounts;
- package desired state;
- Worker Workspace bindings.

AX presents Workspaces as the single top-level execution-capacity page.
Workers remain visible as children of their owning Workspace and have no
independent top-level page. The canonical page composition, view model, data
ownership, and route compatibility contract are defined in the
[Workspaces UX contract](WORKSPACES_UX_CONTRACT.md).

## 2.1 Desktop ownership and transport update

ADR-013 extends v7 without changing Worker ownership. Conclave Workspace now
has two independent Cloud identity planes:

~~~text
human desktop session -> Workspace/account management and recovery APIs
runtime credential     -> machine execution APIs
~~~

The runtime protocol is transport-independent. WebSocket/WSS remains preferred,
but HTTPS long-poll provides a functional fallback when WebSocket cannot reach
Ready. Scheduler/assignment logic targets one logical Gateway session rather
than a specific transport.

Normal Workspace registration/recovery moves into the desktop application after
human sign-in. Conclave AX Workspaces becomes read-only for machine/runtime and
Worker operational state; Project/Workstream authorization remains in AX.

See [ADR-013](../decisions/ADR-013-desktop-auth-and-dual-transport.md) and the
[Workspace auth/transport implementation plan](../roadmaps/WORKSPACE_AUTH_TRANSPORT_IMPLEMENTATION.md).

## 3. Product topology

```text
                         CONCLAVE AX
                             |
                             v
                       CONCLAVE CLOUD
                             |
                    secure Workspace Gateway
                             |
               +-------------+-------------+
               |                           |
               v                           v
       Conclave Workspace A        Conclave Workspace B
          MacBook Pro                    Mac Mini
               |                           |
       +-------+--------+              +---+---+
       |                |              |       |
     ChatGPT          Gemini         ChatGPT  Gemini
   (Codex CLI)         (agy)       (Codex CLI) (agy)
```

Each configured Worker exists on one Workspace only.

## 4. Application boundaries

The three protocol boundaries are frozen by the
[Protocol Boundaries contract](PROTOCOL_BOUNDARIES.md): AX ↔ Cloud Human
Product Protocol, Workspace ↔ Cloud Workspace Runtime Protocol, and Workspace
↔ Worker Package Local Worker Protocol. The protocols share canonical domain
IDs and types only; their wire schemas and credentials remain separate. AX
MUST NOT speak the Workspace Runtime Protocol, and Worker Packages MUST NOT
communicate directly with Cloud.

### 4.1 Conclave AX

Conclave AX is the **web application** and human orchestration/control surface. It is not the machine executor and it does not configure provider credentials locally.

It owns UX for:

- authentication;
- Home summary for Projects, Workspaces, and Ready Workers;
- Projects;
- Workstreams;
- Discuss;
- Work;
- execution inventory;
- Project/Workspace Grants;
- Worker eligibility/selection;
- remote enable/disable/drain controls;
- results/audit/artifacts;
- Workspace downloads/onboarding.

Home presents Workspaces and Ready Workers as links to the same `/workspaces`
page. Getting Started orders setup as: add a Workspace, configure Workers in
the Conclave Workspace desktop runtime, then create a Project. AX does not
provide a detached global Worker page or Worker tab. A Workspace card contains
only Workers from that Workspace's V7 inventory; local authentication and
prerequisite remediation happen in the desktop runtime.

It does not own provider secrets.

### 4.2 Conclave Cloud

Cloud is the authoritative collaboration/orchestration control plane.

It owns:

- users and Project membership;
- Workstreams;
- Work Requests/Workflows/Runs;
- Workspace registrations/grants;
- synchronized Worker inventory projection;
- Worker authorization and scheduler eligibility;
- assignment snapshots;
- durable coordination;
- audit/artifacts;
- Workspace Gateway.

Cloud does not execute an external AI/tool directly.

### 4.3 Conclave Workspace

Conclave Workspace is the **desktop application/runtime** installed on the execution computer. It is the persistent local execution/security boundary. Worker slots are created and managed here; provider authentication flows are mediated by their Worker Packages and remain owned by their provider CLIs.

It owns:

- pairing;
- one machine runtime identity;
- local Work Root;
- Workstream directory resolution;
- configured Worker local registry;
- Conclave desktop-session and Workspace-runtime credentials;
- Worker executable release lifecycle, signature and integrity admission;
- package-reported local readiness;
- local permissions;
- child-process execution/supervision;
- cancellation/process-tree termination;
- local logs/diagnostics;
- runtime and Worker executable updates/rollback;
- sync of safe Worker metadata/readiness to Cloud.

Workspace MUST NOT discover, version, authenticate with, or execute a provider
CLI or other provider tool directly. Provider-specific executable discovery,
version checks, authentication/readiness interpretation, environment needs,
command construction, output parsing, and diagnostics belong to the Worker
Package. Workspace validates and admits the package, grants only permitted
local resources, launches it through the Local Worker Protocol, supervises its
process tree, and applies its safe readiness result to local dispatch policy.

### 4.4 Worker Package

A Worker Package is signed integration code managed and admitted by Conclave
Workspace. It is the complete provider/tool integration boundary.

It owns translation between the Local Worker Protocol and one external
execution technology, including all provider-specific CLI/API interaction.

For the first-party v1 catalog, the supported mappings are ChatGPT to the
Codex-backed Worker Package and Gemini to the Antigravity-backed Worker
Package. Other package implementations remain outside the supported v1 catalog
during migration.

Worker Packages are infrastructure, not separately installed product apps.

## 5. Workspace lifecycle

### 5.1 Legacy pairing compatibility flow

This subsection documents the compatibility path retained for older supported
desktop releases. Current AX and desktop builds do not expose this flow. Cloud
pairing endpoints and `workspace_pairing_intents` remain until the published
desktop compatibility window has elapsed; the removal gate is tracked in
`docs/roadmaps/WORKSPACE_AUTH_TRANSPORT_IMPLEMENTATION.md`.

Conclave AX creates a short-lived, owner-scoped pairing intent. No permanent
Workspace exists yet, and Cloud stores only a hash of the one-time code. The
desktop generates a stable installation ID and proposes a display name from
the computer's friendly OS name; the user may edit it before pairing.

The desktop claims the code through:

```text
POST /api/workspace-runtime/enroll
```

For a pairing intent, Cloud atomically consumes the intent, creates the
Workspace and runtime identity, and returns the runtime credential once. The
credential is stored on the desktop. A claimed installation cannot silently
pair to another identity; it must be explicitly unpaired first. Existing
Workspace enrollment codes remain supported for already-created Workspaces.
Claim validation checks the intent state and active owner, validates the stable
installation ID and bounded machine facts, and rejects an installation already
bound to a live Workspace. The transaction records the installation binding,
initial runtime facts, credential hash, and audit events together. Repeating a
successful claim returns `409 pairing_already_claimed` with the existing
Workspace ID and does not mint a second Workspace or credential; the desktop
must retain the credential from the successful response.

The installation ID is a random persisted desktop identifier, never a hostname
or hardware fingerprint. An active installation uses its saved runtime
credential to reconnect; another pairing claim is rejected, including a copied
code. After explicit local unpair, a recovery marker authorizes a new claim
against revoked installation history. A revoked installation without that
marker cannot be re-paired. Workspace revocation also revokes its active
runtime binding.

The runtime credential is returned only during a successful claim and cannot
be recovered from Cloud, which stores only its hash. If the desktop loses its
OS secure-store item, the owner must revoke the stale Workspace in AX before
using the desktop's **Prepare to pair again** action and claiming a new pairing
intent. That recovery keeps the stable installation ID and local Worker
configuration, credentials, and Work Root; the new claim creates a new Cloud
Workspace/runtime identity, so Project grants must be applied again.

### 5.2 Runtime reports machine facts

After pairing, Workspace reports:

- OS;
- architecture;
- hostname;
- Conclave Workspace version;
- runtime capabilities;
- connection/readiness.

Machine facts are observed runtime state, not user configuration.

### 5.3 Downloads

The canonical download surface remains a dedicated Downloads page.

Contextual links may appear:

- Workspaces empty state;
- Connect machine flow;
- global app menu;
- Workspace update prompt.

### 5.4 Pairing intent API

> **Lifecycle update:** This section records the compatibility API, not the
> current onboarding UX. ADR-013 and its lifecycle refinement in ADR-014 make
> browser-based desktop sign-in followed by explicit Connect Workspace the
> normal path. AX does not create pairing intents in its normal Workspaces
> UI. Keep this API only for clients inside the published compatibility
> window; see the [desktop lifecycle contract](../decisions/ADR-014-workspace-desktop-lifecycle.md).

AX creates, checks, cancels, or regenerates temporary pairing intents through
`/api/workspace-pairing-intents`. Status reads never return the raw code. The
first successful desktop claim creates the permanent Workspace; expiry,
cancellation, and a successful claim make the code unusable.

- one runtime bearer token.

The desktop app stores the bearer token only in the OS secure credential store
and writes only non-secret registration metadata to disk. On macOS, the native
Security framework reads and writes Keychain items directly; credentials are
never passed as command-line arguments. It then opens:

```text
/api/workspace-gateway/connect?workspaceRuntimeId=<runtime-id>
```

and authenticates with the bearer token.

The first successful `workspace.hello` establishes the live session and publishes real machine facts and Worker inventory.

### 5.6 macOS distribution

macOS is the first desktop release target.

The supported repository build entrypoint is:

```text
bash scripts/build-workspace-macos.sh
```

The script:

- resolves Flutter dependencies;
- runs analyze/tests unless explicitly skipped;
- builds the native release app;
- injects the Workspace version;
- optionally signs with a Developer ID identity and hardened runtime;
- optionally notarizes with Apple;
- produces a ZIP under `dist/conclave-workspace/macos`.

Conclave Workspace is distributed directly rather than through Mac App Store sandboxing because it must launch and supervise Worker Packages and operate in persistent Workstream directories.

A real Cloud smoke procedure is available through:

```text
CONCLAVE_ENROLLMENT_TOKEN=... bash scripts/test-workspace-cloud-connection.sh
```

Use a disposable Workspace because the test consumes a real one-time enrollment and establishes a real runtime identity.

## 6. Conclave Workspace UI

Conclave Workspace is background-first with a minimal GUI.

### 6.1 Before pairing

```text
Conclave Workspace

Connect to Conclave AX
Pairing code: [________]

[Connect]
```

### 6.2 Main local view

```text
Conclave Workspace

MacBook Pro
● Connected

Workers
ChatGPT               Ready
Gemini                Setup required

Current work
Authentication · ChatGPT · Running

Machine
Work Root   ...
Version     ...
```

The Workers list uses only `Ready`, `Setup required`, `Not installed`, `Needs
attention`, and `Disabled` as row states. Rows also show the package-reported
CLI version and last Test result. Package identity, admission, signature, and
provider-neutral diagnostic details stay in Advanced Diagnostics.

### 6.3 Local-only areas

Recommended:

- Overview;
- Workers;
- Permissions;
- Diagnostics;
- Settings/Updates.

Do not replicate Projects/Workstreams/Work UI.

### 6.4 Background/tray behavior

Desktop builds should continue execution when the main window is closed.

Tray/menu-bar controls may include:

- connection status;
- current work;
- pause accepting new work;
- open Conclave Workspace;
- open Conclave AX;
- logs;
- quit.

## 7. Worker resource model

### 7.1 Configured Worker

A configured Worker contains safe logical/local fields:

```text
id
workspaceId
name
workerTypeId
authStrategy
credentialRef (local only)
defaultModel
allowedModels
capabilities
localPermissions
localConcurrencyLimit
status
adapterVersion
createdAt
updatedAt
```

Cloud stores only the safe projection.

### 7.2 Cardinality

```text
Workspace 1 -> N Workers
Worker N -> 1 Workspace
Worker Type 1 -> N Workers
```

No configured Worker Workspace-binding table is needed in the target model.

### 7.3 Duplicate names

Worker name need not be globally unique.

Recommended uniqueness:

- unique within one Workspace, case-insensitive where practical.

Cloud always uses immutable Worker ID.

## 8. Worker Type / Worker Package model

The Worker Type is the stable product integration identity; the Worker Package
is its admitted local implementation. The supported first-party v1 catalog is
narrowed by ADR-015 to ChatGPT via the Codex-backed Worker Package and Gemini
via the Antigravity-backed Worker Package. Package IDs remain separate from
product Worker Type IDs.

The Workspace-visible package manifest contains only generic admission and
compatibility metadata, such as:

Suggested metadata:

```text
packageId
workerTypeIds
localWorkerProtocolVersion
releaseVersion
supportedPlatforms
requestedPermissions
publisher
packageDigest
signature
releaseChannel
```

Provider-specific executable candidates, version rules, authentication
semantics, environment variables, command lines, output formats, and provider
error mappings are package implementation details. They MUST NOT be interpreted
or duplicated by Workspace. Package-declared environment access and local
resource permissions are admitted by Workspace as generic policy inputs.

The signed manifest's `environmentPolicy.environmentPassthrough` lists parent
variables Workspace may copy into that package. Package launches use
`includeParentEnvironment: false` and a bounded generic base environment.
The Workspace builds a GUI-safe `PATH` centrally from absolute entries in the
launching environment plus standard OS and generic per-user executable
locations. This baseline is runtime behavior and is not repeated in package
manifests. Workspace treats signed passthrough names as opaque keys. The
package consumes its signed `providerCliPassthrough` list when constructing the
provider CLI's environment; names and values marked sensitive are redacted from
package output.

### 8.1 Worker Type naming rule

The product-facing v1 names are **ChatGPT** and **Gemini**. Their Worker
Packages use Codex CLI and Google Antigravity CLI (`agy`) respectively. These
names denote supported product slots, not direct provider API integrations.
Provider login and billing mode are owned by the corresponding CLI and handled
by its Worker Package; Conclave does not ask the user to select subscription
versus API-key use. See [ADR-015](../decisions/ADR-015-first-party-worker-v1-contract.md).

## 9. Model selection

Model is not Worker Type.

For the first-party v1 catalog, model selection belongs to the Work or
Assignment. Workspace does not collect a Worker Name, local default model, or
allowed-model list. Schema 6 clears previously stored local model defaults and
allow-lists during migration. The Worker Package validates whether it can run
the requested model; local permissions and concurrency remain Workspace policy.

Older generic Worker contracts supported local model defaults and allow-lists;
that behavior is retained only for historical compatibility and is not part of
the v1 first-party catalog.

## 10. Local Worker creation

### 10.1 First-party v1 Workspace configuration

The current v1 UI presents fixed ChatGPT and Gemini catalog slots rather than
the earlier generic Add Worker flow. Configuration covers Worker
Package-reported readiness, local permissions, local concurrency, and safe
diagnostics. It does not collect a Worker Name or local model defaults/allow-lists.
See
[ADR-015](../decisions/ADR-015-first-party-worker-v1-contract.md).

Current flow:

```text
Workers
-> choose Configure on ChatGPT or Gemini slot
-> ensure mapped Worker Package is installed and admitted
-> save fixed catalog slot with Workspace policy defaults
-> ask package for readiness
-> run the package's live test only on explicit user action
-> sync safe projection
```

### 10.2 Authentication

Provider authentication is CLI-defined and Worker Package-mediated. Workspace
does not inspect provider credentials or execute authentication-status CLI
commands directly.

Provider-specific setup remains inside the package. Its Local Worker Protocol
result exposes only safe readiness states and bounded diagnostics;
authentication mode is not a Cloud inventory field.

Examples of provider-owned strategies include:

- provider browser login;
- cached subscription session;
- API key;
- local session token;
- no credential/local endpoint.

Cloud receives only the provider-neutral readiness projection and safe
attention reason required for scheduling; it does not receive auth strategy,
provider/account hints, or credential references.

### 10.3 Permission approval

Local user approves machine-sensitive permissions.

Cloud cannot broaden them.

## 11. Cloud Worker projection

Cloud stores enough Worker data to schedule safely without owning secret configuration.

Suggested projection:

```text
workerId
workspaceId
workerTypeId
status
readinessState / attentionReasonCode
capabilities
localConcurrencyLimit
adapterVersion
lastSeenAt
```

Workspace sends idempotent upsert/tombstone events.

The synchronized and AX-facing projection excludes Worker names, auth strategy,
credential status or references, local permission names, model defaults and
allow-lists, tokens, API keys, auth files, and local paths. Workspace forwards
only the package's validated, bounded, provider-neutral readiness result; raw
provider output remains inside the Worker Package. Discovered model or
capability metadata may be added only when it is non-sensitive and does not
reveal local credentials or paths.

Cloud rejects inventory updates from any runtime other than the Worker's owning Workspace.

## 12. Synchronization model

### 12.1 Local -> Cloud inventory

Workspace is authoritative for Worker slot existence, package admission,
local permissions, and dispatch eligibility. The Worker Package is
authoritative for provider/tool-specific readiness and reports it through the
Local Worker Protocol.

Sync triggers:

- Worker created;
- Worker edited;
- package-reported readiness changed;
- Worker Package updated;
- permissions changed;
- Worker removed;
- package readiness probe at runtime startup, after app resume, and on explicit
  setup recheck (any periodic probe is package-defined and must not run a
  quota-consuming live execution test);
- reconnect.

Workspace persists Worker-reported readiness independently from local
activation. The local registry has an `activationState` (`enabled` or
`disabled`) and a separate package-reported `readinessState`; disabling a
Worker never overwrites its readiness. The wire `status` remains a compatibility
projection for dispatch (`disabled` when activation is off), while Cloud keeps
readiness separate from its coarse scheduling status. Only enabled Workers
whose effective local status is `ready` are eligible for dispatch; that status
also gates assignments while a startup probe is pending. The Worker performs
provider CLI presence/version/authentication checks and execution
prerequisites. Workspace never performs these provider-specific checks itself;
it validates and records the Worker response. This is the normative Worker
Runtime v2 boundary, although the current source assignment route has not yet
converged to it.
The local record retains the latest passive probe state and time, the latest
live-test result and time, and a stable actionable issue code. Workspace does
not infer provider authentication from historical `credentialStatus`. Gemini
passive probes may report `setup_required` when the CLI has no cheap supported
authentication check; the untested Worker is presented as setup-required, not
as a broken integration. A successful live test establishes local eligibility
until a later package result reports a blocking issue.
Workspace independently validates package signature/integrity and enforces
local permissions. No provider credential is copied into the package protocol.

### 12.2 Cloud -> local operational policy

Cloud owns and applies Workstream usage policy, including:

- role-to-Worker selection and ordered fallback;
- model selection;
- Workstream-specific Cloud concurrency ceiling;
- Project/Workstream authorization context.

The Workspace receives assignments and cancellations, not role/model policy as
local configuration. AX owns the settings UI and Cloud validates every
selection against active Project Workspace Grants.

Cloud policy may narrow local Worker ability, never broaden it.

Cloud persists a separate scheduling state (`enabled`, `disabled`, or
`draining`) for Cloud-side eligibility. Workstream policy can enable its
selected/fallback capacity but cannot change local readiness, credentials,
permissions, ownership, or local concurrency. Scheduling requires a local
`ready` status and Cloud `enabled`. Drain rejects new assignments, lets active
assignments finish, and transitions to disabled when a state read observes
that active count has reached zero. The request and completion are audited
with actor and time. A full inventory snapshot is authoritative:
omitted Workers become tombstones and are disabled; a later source revision (or
the same revision after an omission tombstone) may restore an omitted Worker.
Explicit Worker tombstones continue to use strictly increasing source
revisions. Worker IDs remain permanently bound to their first Workspace.

### 12.3 Conflict rule

Split ownership prevents generic last-write-wins.

Local owns local configuration fields.
Cloud owns remote scheduling/authorization fields.

## 13. Scheduler

Scheduler candidate becomes simpler:

```text
Configured Worker
-> owning Workspace
-> active Workspace Project Grant
-> Worker synced + ready
-> Workstream role mapping
-> selected model/capability compatible
-> local concurrency available
-> Cloud scheduling enabled
-> Workstream fallback policy allows Worker
```

There is no Workspace-binding search for a configured Worker because Worker already has exactly one Workspace.

For stateful Work:

- Workspace must equal Workstream Primary Workspace.

For stateless Work:

- eligible Worker/Workspace may be selected from granted Workspaces.

## 14. Assignment snapshot

Assignment snapshots include:

```text
projectId
workstreamId
workRequestId
runId
configuredWorkerId
workspaceId
workerTypeId
workerRuntimeVersion
requested/resolvedModel
capabilities/permissions snapshot
executionClass
lease/fencing data where stateful
```

Do not include:

- provider secret;
- arbitrary executable path;
- arbitrary local CWD.

## 15. Execution lifecycle

Default:

```text
Cloud assignment
-> Workspace validates
-> resolve Workstream CWD
-> resolve configured Worker
-> verify Worker release signature, integrity, platform and protocol compatibility
-> apply Worker permissions/environment boundary
-> launch standalone Worker executable through Local Worker Protocol
-> Worker discovers/probes and invokes its provider tool or API
-> stream progress
-> capture result
-> terminate/cleanup
-> report completion
```

Default process topology: the Workspace runtime stays resident; each
assignment starts one fresh Worker Package child process; that package starts
one fresh provider CLI process for the assignment. Workspace supervises and
cleans up the package process, and the package's shared runner supervises and
cleans up the CLI process. Durable sessions carry provider resume IDs between
these fresh CLI processes; they do not keep either child process alive.

## 16. Historical V7 Local Worker Protocol implementation (superseded)

The following Protocol 2.x details record the legacy Workspace-to-Node-adapter
implementation only. New first-party work uses Local Worker Protocol 3.0 as
defined in [Worker Runtime v2](WORKER_RUNTIME_V2.md).

The Node-backed migration implementation supports Local Worker Protocol 2.1 through 2.6. Protocol 2.x is not the target contract. In the legacy implementation, a `probe.request` explicitly selects
`passive` or `live`. Passive probes perform package-owned executable discovery,
version checks, and cheap authentication checks when the provider supports
them. Live probes run the small `OK` request. The response contains `mode`,
`ready`, package-reported `toolName`, nullable absolute `toolPath`, `toolVersion`,
and structured `checks[]` entries with a stable check
ID, status, optional stable issue code, and optional diagnostic bounded to
2,048 characters. Diagnostics remain local and are not synchronized to Cloud.
An `execute.request` in protocol 2.4 and later carries the remaining assignment
`timeoutMs`. The package derives the provider CLI deadline from that budget and
leaves a 1.5-second cleanup grace before the Workspace deadline. Live readiness
tests use a separate explicit 30-second test deadline. Protocol 2.5 adds
`sessionPolicy` (`stateless` or `durable_session`) and an opaque `sessionKey`
for durable turns. Packages keep provider session identifiers in package-local
storage; neither Cloud nor Workspace stores or interprets those identifiers.
Workspace provides each configured Worker Package a private
`Workspace/Workers/<worker-id>/state` directory through the generic
`CONCLAVE_WORKER_STATE_DIR` environment value. Packages may keep session
mappings and non-secret tool metadata there; Workspace treats its contents as
opaque.
Persistent provider processes and long-running Worker daemons are deferred
until the first-party Codex and Gemini Workers are proven stable. Protocol
versions 2.1 through 2.4 remain readable during package migration; packages
older than 2.4 do not receive the assignment deadline field. The protocol uses
these messages:

- `initialize.request` / `initialize.result`;
- `probe.request` / `probe.result`;
- `execute.request`;
- `progress`, `result`, and `error`.

Every request and response is correlated by `requestId`; progress and terminal
execution frames carry the originating execute request ID. The strict schema
rejects unknown fields, applies per-field and 1 MB frame limits, and contains no
provider token or account-secret fields. Workspace requests a passive package
probe during routine readiness checks and validates its bounded,
provider-neutral result; only the package decides which provider-specific
checks are needed. A live probe that may consume provider
quota is explicitly requested and is never implied by routine Workspace
supervision. Cancellation is enforced by the Workspace process supervisor.

Protocol must include:

- schema version;
- assignment ID;
- bounded payload sizes;
- explicit result contract.

Do not scrape interactive terminal UI when a supported machine-readable/headless mode exists.

## 17. Process isolation

Workspace runtime supervises Worker Package and descendant process trees. Only
the Worker Package may discover or launch its provider tool.

Requirements:

- explicit CWD;
- minimal environment;
- scoped secret injection;
- no inherited secret environment by default;
- stdout/stderr limits;
- package-owned provider CLI diagnostic capture and provider-neutral mapping;
- a bounded, redacted local package-stderr tail only when a package crashes
  before returning a protocol frame (never synchronized to Cloud);
- timeout;
- graceful cancel then forced kill;
- process-group/tree termination;
- temp-file cleanup;
- exit status normalization.

Each assignment owns one Workspace-launched Worker Package process and its complete
descendant tree, including provider CLI processes launched by the package. On
cancellation, timeout, output-limit failure, Worker removal, or Workspace
shutdown, Workspace first sends a graceful stop to the package and gives it a
brief cleanup window. The shared CLI runner uses that window to stop its
provider process and descendants. Workspace then force-kills the complete
assignment tree: a POSIX process group plus recursive descendant discovery as
a fallback, or the Windows process tree. Provider CLI processes stay in the
Workspace-owned process group so a package crash cannot orphan them. Shutdown
rejects new assignments and cancels operations that are active, starting, or
queued. Package/provider-tool exit or protocol failures stay scoped to that
assignment and do not stop the Workspace runtime.

A crashed Worker Package must not disconnect the Workspace runtime.

## 18. Workstream working directory

ADR-011 remains unchanged:

```text
<work-root>/<project-id>/<workstream-id>/
```

All Workers on one Workspace assigned to the same Workstream see the same directory.

Different Workstreams are isolated and may run in parallel.

Workers manage repositories inside the directory.

## 19. Concurrency

Two separate limits exist:

### Workspace capacity

Machine-wide total active executions.

### Worker local concurrency ceiling

Maximum simultaneous assignments for one configured Worker.

AX Workstream policy sets a Cloud-side limit per task role. The scheduler takes
the minimum of that limit, any Cloud Worker ceiling, and Workspace-reported
local concurrency; it never asks Workspace to exceed its local ceiling.

Stateful Workstream mutation lock is an additional independent constraint.

## 20. Remote controls in Conclave AX

### Workspace readiness inventory

Show:

- fixed Worker Type label;
- Worker Type;
- owning Workspace;
- readiness;
- safe adapter/readiness attention reason.

### Workstream Execution policy

AX owners/collaborators can:

- choose Workspace Workers per task role;
- choose a model per role;
- order a fallback Worker or allow any eligible Ready Worker;
- set a Cloud-side concurrency limit.

Workstream scheduling fails closed until a role mapping exists. The Workspace
app reports package readiness and offers provider setup through package-defined
flows, while Workspace owns local permissions and execution setup.

### Not allowed initially

- enter/change provider secret;
- approve new local permissions;
- silently remove local credential;
- silently change Worker Package installation.

Worker removal is local-first; Cloud may support a remote removal request later with explicit local confirmation.

## 21. Worker details in Conclave AX

Recommended sections:

- Overview;
- Workspace;
- Activity/Audit;
- Scheduling.

Remove multi-Workspace binding UX.

Connection/authentication details are informational:

- Ready;
- Needs authentication;
- Needs local attention.

Action copy should say:

> Complete in Conclave Workspace on MacBook Pro.

## 22. Project/Workstream authorization

Worker authorization remains Cloud-controlled.

Project grants authorize Workspaces; Workstream Execution settings select:

- role-to-Worker primary and fallback order;
- model;
- fallback behavior;
- Cloud-side concurrency.

Workstream policy can narrow Project policy.

Because a Worker has one Workspace, authorization is easier to reason about.

## 23. Security boundary

Conclave Workspace is the local authority.

Cloud can request execution but local runtime verifies:

- owning Worker;
- Workspace grant context;
- adapter signature/version;
- local readiness;
- permissions;
- CWD containment;
- Workstream lease/fencing;
- Conclave desktop/runtime credential state (provider credentials remain owned
  by the provider CLI and are not read by Workspace).

No Cloud instruction can override local trust boundaries.

## 24. Updates

Three update layers:

### Conclave Workspace app

Normal signed application update.

### Worker executable release

Managed inside Conclave Workspace with signature/digest verification, immutable version installation, independent update policy, and rollback.

The signature covers both the file-tree digest and the canonical manifest
without its signature field. Workspace checks downloaded catalog metadata
against the archived manifest, then verifies signature, permissions, platform,
and health before atomic activation. Cloud stores versioned release metadata
and archives but does not grant execution trust.

### Third-party tool

Provider-owned lifecycle unless Conclave intentionally takes ownership.

UI must distinguish these.

## 25. Failure behavior

### Cloud offline

Workspace does not accept new Cloud work; running assignment follows explicit connection-loss policy.

### Workspace offline

Cloud stops scheduling it.

### Worker executable crash

Assignment fails/retries according to Workflow; Workspace remains online. Repeated Worker-internal failures may mark that Worker release unhealthy and offer rollback without changing the Workspace app.

### Credential expiry

The Worker Package reports authentication unavailable; that Worker becomes
Needs authentication while other Workers remain eligible.

### Tool missing/outdated

The Worker Package reports a missing or unsupported tool; that Worker becomes
Needs attention.

### Worker update failure

Keep the previously verified active/last-known-good Worker version. Provider authentication/quota/outage failures do not by themselves trigger rollback.

## 26. Data ownership summary

| Data                                                  | Authority                    |
| ----------------------------------------------------- | ---------------------------- |
| Project/Workstream                                    | Cloud                        |
| Workspace registration                                | Cloud                        |
| Work Root/files                                       | local Workspace              |
| configured Worker existence/config                    | local Workspace              |
| Worker safe inventory projection                      | Cloud replica                |
| provider credentials                                  | provider CLI secure store    |
| Worker Package catalog/release metadata               | Cloud                        |
| Worker Package installed state                        | local Workspace              |
| scheduling enable/drain (target; controls incomplete) | Cloud                        |
| Project/Workstream Worker authorization               | Cloud                        |
| local permission ceiling                              | local Workspace              |
| Run/Assignment/audit                                  | Cloud                        |

## 27. Migration from v6 configured Workers

This section records the migration rationale and target mapping. The Phase 3
forward migration and runtime/API retirement are complete; it is not a
compatibility design for current runtime code. Current behavior is defined by
the sections above and ADR-012.

Current v6:

- configured Worker is Cloud-created;
- Worker may bind to multiple Workspaces;
- credential/readiness is per binding.

v7 target:

- configured Worker is local-created;
- Worker has exactly one Workspace;
- credential/readiness is direct local Worker state.

Pre-production migration preference:

- clean dev schema/reset where practical;
- do not preserve multi-Workspace binding complexity as permanent compatibility architecture.

Temporary migration may convert each current Worker/Workspace binding into one local-style Worker projection.

## 28. Non-goals for initial v7

Do not initially build:

- separate Worker desktop apps;
- persistent Worker daemons;
- hardware fingerprinting;
- Cloud secret vault for provider credentials;
- universal generic adapter for every provider;
- automatic third-party tool redistribution;
- Source/repository registry;
- usage/cost accounting;
- remote destructive credential removal;
- Kubernetes/container orchestration.

## 29. Acceptance mental model

A new user should be able to understand:

```text
Install Conclave Workspace on a computer.
Configure its ChatGPT and Gemini slots using the local CLIs.
Conclave AX discovers those Workers.
Use them from Projects and Workstreams.
```

No additional infrastructure vocabulary should be required.

## 30. Implementation audit and release gates

The current source-level convergence is tracked in [V7 Implementation Audit](V7_IMPLEMENTATION_AUDIT.md).

Do not declare v7 production-complete until:

- desktop pairing + Workspace Gateway smoke succeeds against the target Cloud;
- signed/notarized macOS build passes;
- at least one real ChatGPT (Codex CLI) and one real Gemini (Antigravity CLI)
  execution succeed from locally configured Workspace slots;
- legacy Cloud-created/multi-Workspace Worker execution is no longer required;
- Worker release verification does not ship signing secrets and uses asymmetric public-key trust.

## Completion plan

See [Architecture v7 Completion Plan](../roadmaps/ARCHITECTURE_V7_COMPLETION.md) for the remaining convergence and release gates.


## Worker Runtime v2 convergence

ADR-017 is the normative first-party runtime refinement inside Architecture v7. The first-party topology is `Workspace -> standalone Dart Worker executable -> provider CLI`. Worker versions are independent from Workspace and provider CLI versions, and Workspace may install multiple immutable Worker versions for update/rollback. Local Dart Worker acceptance has progressed, but the current Workspace assignment source still uses the legacy Node-backed V7 store/executor; the end-to-end Dart route and production acceptance are open. The implementation/migration order and phase evidence are defined by [Worker Runtime v2 Implementation](../roadmaps/WORKER_RUNTIME_V2_IMPLEMENTATION.md). The Node-backed Protocol 2.x implementation is migration-only, not the desired release baseline.
