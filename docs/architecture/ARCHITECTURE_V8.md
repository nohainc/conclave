# Conclave AX Architecture v8 — Generic Worker Engine and Tool Profiles

**Status:** Accepted architecture and implementation target  
**Release declaration:** Withheld; acceptance gates remain open

**Date:** 2026-10-01  
**Builds on:** Architecture v7, Worker Runtime v2, Work v1  
**Primary decision:** [ADR-018](../decisions/ADR-018-generic-cli-worker-engine-and-tool-profiles.md)

## 1. Executive decision

Architecture v8 keeps the v7 product model and Work v1 orchestration, but
simplifies the local AI execution layer.

The historical Worker Runtime v2 implementation used one first-party Worker
executable per provider:

~~~text
Workspace
├── ChatGPT Worker -> Codex CLI
└── Gemini Worker  -> agy
~~~

v8 replaces that implementation with one generic isolated CLI Worker Engine and
signed Cloud-managed Tool Profiles:

~~~text
Conclave AX
    |
    v
Conclave Cloud
    |
    v
Conclave Workspace
    |
    | Local Worker Protocol 4.0
    v
Conclave CLI Worker Engine
    |
    | signed Tool Profile
    v
provider CLI
~~~

### 1.1 Canonical v8 terminology and migration boundary

Use these terms for v8 architecture, implementation, tests, and operations:

- **Logical Worker** — stable product identity selected by Workstreams and Work;
- **CLI Worker Engine** — generic isolated executable supervised by Workspace;
- **Tool Profile Definition** — stable official provider integration identity;
- **Tool Profile Release** — immutable signed payload for a definition;
- **Profile lifecycle/channel** — Cloud-managed release state and promotion;
- **Provider CLI** — locally installed tool such as `codex` or `agy`;
- **Local Worker Protocol 4.0** — Workspace-to-Engine contract.

Workspace, Worker, Worker Type, Workstream, Work Request, and Work v1 Workflow
remain canonical product/domain terms. “ChatGPT Worker executable,” “Gemini
Worker executable,” “provider-specific Worker release,” and “per-provider
native Worker package” describe the superseded v2 implementation only. Existing
v2 provider binaries and their release machinery are migration-only references
until the v8 acceptance gates pass and Phase 31 removes them. Do not extend that
runtime for new provider integrations.

Examples:

~~~text
ChatGPT
-> CLI Worker Engine
-> chatgpt-codex profile
-> codex

Gemini
-> CLI Worker Engine
-> gemini-antigravity profile
-> agy
~~~

The logical Worker identity remains stable. Workflows, Workstream bindings,
scheduling, collaboration history, and AX UX continue to target ChatGPT,
Gemini, and future approved logical Workers rather than implementation details.

## 2. Product mental model

Users should understand only:

> **Project** = collaboration boundary.  
> **Workstream** = persistent unit of work.  
> **Workspace** = machine where AI can execute.  
> **Worker** = AI/tool choice available on that Workspace.  
> **Workflow** = Conclave-defined way to perform work.

Users do not need to understand:
- Worker Engine;
- Tool Profiles;
- profile releases/channels;
- engine/profile compatibility;
- Local Worker Protocol.

Normal Workspace UI remains Worker-centric.

## 3. Product topology

~~~text
                         CONCLAVE AX
                             |
                             v
                       CONCLAVE CLOUD
                             |
                   Workspace Runtime Protocol
                             |
                             v
                    CONCLAVE WORKSPACE
                             |
                   Local Worker Protocol 4.0
                             |
                             v
                    CLI WORKER ENGINE
                             |
               +-------------+--------------+
               |                            |
      chatgpt-codex profile       gemini-antigravity profile
               |                            |
               v                            v
             codex                         agy
~~~

At runtime, each assignment/probe starts its own engine child process by
default. Multiple assignments may run concurrently according to Worker and
Workspace concurrency limits.

## 4. Application boundaries

### 4.1 Conclave AX

AX remains the human web application.

It owns:
- Projects and Workstreams;
- Discuss;
- Work;
- built-in Workflow selection;
- Workstream logical Worker bindings;
- model selection where supported;
- Work history/results;
- read-only Workspace/Worker operational visibility.

AX never sees provider credentials, local tool paths, provider session IDs, or
raw Tool Profile configuration.

### 4.2 Conclave Cloud

Cloud remains the collaboration/orchestration control plane.

It owns:
- human accounts and Project membership;
- Workstreams and Work Requests;
- built-in Work v1 definitions;
- safe Workspace/Worker inventory;
- scheduling and assignment snapshots;
- Workspace Gateway;
- logical Worker catalog;
- official Tool Profile definitions/releases/channels;
- profile release audit/revocation;
- release trust metadata.

Cloud does not execute provider CLIs.

### 4.3 Conclave Workspace

Workspace remains the persistent machine-side trust and execution supervisor.

It owns:
- human/runtime identity;
- local Work Root;
- Workstream directory resolution;
- logical Worker local state;
- local permissions;
- engine installation/version selection;
- signed Tool Profile synchronization/cache;
- profile signature/digest/schema validation;
- profile eligibility/resolution;
- engine child-process supervision;
- outer deadlines/cancellation;
- logs/diagnostics aggregation;
- safe Worker readiness synchronization to Cloud.

Signed Profile releases are materialized under Workspace-managed
`Profiles/<profileDefinitionId>/<releaseVersion>/profile.json` directories,
with signed release metadata beside each immutable payload and active/LKG
pointers in `release-state.json`. Workspace refreshes Cloud revocations before
release sync and validates the shared Profile v1 schema and trust envelope
before writing. Cache updates are independent of Engine and Workspace
application versions.

Workspace does **not** know provider-specific commands or event formats.

### 4.4 CLI Worker Engine

The CLI Worker Engine is one generic standalone Dart console executable.

It owns:
- bounded Tool Profile runtime parsing and identity/digest checks;
- provider CLI discovery from Profile candidates and approved locations;
- verified cached executable paths, generic OS search locations, bounded PATH
  search, and executable validation;
- provider environment construction within engine policy;
- passive/live probe execution;
- command/argument construction;
- prompt transport;
- provider event parsing;
- provider session integrity/storage;
- progress/result/error normalization;
- process cleanup for the provider child;
- engine-side logs/diagnostics.

It has no Cloud credentials and never connects directly to Cloud.

Workspace verifies official release signatures and performs canonical Tool
Profile v1 schema admission before launching the Engine. The Engine rechecks
the loaded payload digest, identity, compatibility, and execution bounds before
accepting Protocol 4.0 requests.

### 4.5 Tool Profile

A Tool Profile is an immutable signed declarative provider integration release.

It describes provider behavior only through the finite v8 profile schema.

A profile may not contain arbitrary code or shell commands.

Official profile release lifecycle:

~~~text
draft -> testing -> beta -> stable -> retired
                              |
                              +-> revoked
~~~

The actual lifecycle may skip beta for urgent fixes, but stable promotion is
always explicit and audited.

Cloud selects the Profile channel for each Workspace. A Workspace without an
explicit internal override receives `stable`; platform-admin development
operations may opt a Workspace into `testing` or `beta`. The Workspace runtime
authenticates its catalog request with its runtime credential, and Cloud derives
the allowed channel from that identity. The catalog API rejects caller-supplied
channel selection. Normal users do not choose Profile channels in AX or
Workspace settings. Each selected release is still signature-checked and
passively validated locally before activation; real provider acceptance is an
explicit test action.

## 5. Protocol boundaries

Architecture v8 keeps three wire/trust boundaries:

~~~text
AX <-> Cloud
Human Product Protocol

Cloud <-> Workspace
Workspace Runtime Protocol

Workspace <-> CLI Worker Engine
Local Worker Protocol 4.0
~~~

Provider CLI communication exists below the Local Worker Protocol and is private
to Engine + Tool Profile.

The boundaries share canonical IDs only. They do not share credentials.

## 6. Local Worker Protocol 4.0

Protocol 4.0 retains the provider-neutral operations proven by Runtime v2:

~~~text
initialize
probe(passive|live)
execute
progress
result
error
~~~

Identity now contains:

~~~text
workerTypeId
engineVersion
profileDefinitionId
profileReleaseVersion
profileSchemaVersion
providerToolName
providerToolVersion
capabilities
~~~

Workspace supplies the admitted profile payload/reference and expected logical
Worker identity. Engine initialization must prove the resolved identity matches
the Workspace-selected release.

The protocol never carries:
- provider credentials;
- provider session IDs;
- arbitrary executable paths from Cloud;
- arbitrary shell command text.

## 7. Process architecture

Default execution:

~~~text
Workspace
└── CLI Worker Engine
    └── provider CLI
~~~

Concurrent example:

~~~text
Workspace
├── CLI Worker Engine [ChatGPT]
│   └── codex
├── CLI Worker Engine [ChatGPT]
│   └── codex
└── CLI Worker Engine [Gemini]
    └── agy
~~~

Workspace is the ultimate kill authority over the Engine process tree.

The Engine is separate from the Flutter Workspace process to preserve crash,
memory, parser, and provider isolation.

## 8. Engine deployment/versioning

There is one CLI Worker Engine release per supported platform/architecture.

Example:

~~~text
conclave-cli-worker 1.3.0

macos-arm64
macos-x64
linux-arm64
linux-x64
windows-x64
...
~~~

Initially, the signed/notarized Workspace application release is the Engine
trust boundary. Each Workspace build bundles one known-good Engine executable
for its platform. The executable is not fetched from Cloud and has no mutable
database lifecycle. Its version is compiled into the Workspace supervisor and
is independently reported by Engine initialization and diagnostics.

At startup, Workspace bounds and hashes the bundled asset, then materializes it
into the managed application-support directory:

~~~text
<WorkspaceData>/
  Engines/
    cli_worker/
      1.0.0-<sha256>/
        conclave_cli_worker_engine[.exe]
~~~

The version and digest make each materialized artifact immutable and
content-specific. Workspace restricts directory/executable permissions and
rechecks an existing artifact against the bundled bytes on startup; altered or
incomplete cached bytes are replaced from that trusted bundle. A missing,
oversized, or unmaterializable Engine fails closed and leaves the Worker
runtime unavailable.

The active Engine is exactly the one bundled by the installed Workspace
release. There is no independent Engine active/LKG pointer and no Engine
selection from Profile lifecycle metadata. Engine changes therefore ship with
a Workspace release. Until the Workspace application update transaction has
verified drain, staging, restart, health check, and rollback, recovery from a
bad Engine release means reinstalling the previous verified signed/notarized
Workspace release as a whole. The Engine is not silently replaced by an older
cached executable. Independent signed Engine delivery may later add its own
immutable platform artifacts, trust/revocation checks, candidate admission,
health check, and atomic active/LKG rollback; that mechanism is not required
for v8 acceptance.

## 9. Tool Profile domain model

### 9.1 Profile definition

Stable integration identity:

~~~text
profileDefinitionId = chatgpt-codex
logicalWorkerTypeId = chatgpt
engineFamily = cli
~~~

### 9.2 Profile release

Immutable configuration:

~~~text
definition = chatgpt-codex
releaseVersion = 9
schemaVersion = 1
channel/status = stable
engineCompatibility = >=1.2 <2.0
providerToolCompatibility = >=0.176 <0.190
signedPayload = ...
~~~

### 9.3 Channel pointer

Cloud records which eligible release is currently:
- testing;
- beta;
- stable.

Promotion changes pointers/state, never release payload contents.

## 10. Tool Profile schema

The normative schema is defined in
[Tool Profile v1](../specifications/TOOL_PROFILE_V1.md).

At a high level it contains:

~~~text
identity
engineCompatibility
providerTool
discovery
versionProbe
compatibility
authProbe
environment
execution
stdin
output
events
session
model
progress
errors
sandboxPolicy
limits
~~~

The schema uses typed enums and bounded placeholders rather than executable
expressions.

## 11. Profile resolution

Workspace/Engine resolution inputs:

~~~text
logical Worker
Engine version
platform
provider tool name
provider tool version
profile channel/policy
revocation state
~~~

Resolution returns one signed eligible profile release.

Workspace resolves locally cached, signature-verified releases in this order:

1. locally active verified release if still eligible;
2. current compatible stable release;
3. last-known-good compatible stable release where permitted;
4. otherwise Worker becomes Setup required / Needs attention.

Compatibility uses semantic-version ranges with an inclusive minimum and
exclusive maximum. The current stable candidate is the version selected by
the latest successful stable catalog sync; it is tracked separately from the
active pointer so a local rollback cannot make an older release appear current.
Every candidate must match the requested logical Worker, definition, channel,
Engine range, provider CLI range, and current revocation policy. An unsupported
provider CLI version returns unavailable and never selects an incompatible
profile.

## 12. Profile update/rollback

Profile updates are lightweight and independent from Workspace/Engine binaries.

Workspace rollback selects a locally cached, signature-verified, compatible
last-known-good release. It initializes the Engine and runs a passive probe
against that candidate before atomically switching the active Profile pointer.
The previous active release becomes last-known-good. A failed validation leaves
the current pointers unchanged; rollback never sends a model request.

Revocation makes a release ineligible as soon as the refreshed revocation state
is applied. If it was active, Workspace clears that active pointer first, then
resolves and passively probes another eligible release before activation. A
cached release is never promoted solely because it remains trusted. If no
eligible release passes, the Worker is marked Needs attention. Provider
authentication, quota, and service outages do not trigger Profile rollback;
they remain readiness failures for the current release.

~~~text
Cloud stable pointer -> new release
        |
        v
Workspace fetches signed release
        |
        v
verify signature/digest/schema
        |
        v
verify Engine/provider compatibility
        |
        v
candidate initialize + passive probe
        |
        v
activate
~~~

No live model request is required for every automatic stable update.

Workspace first caches a validated release as an inactive candidate. The
candidate Engine performs initialize and a passive provider probe before one
atomic release-state update changes the active/stable pointers and records the
previous active release as last-known-good. If the Engine or a matching local
Worker is unavailable, or the candidate probe fails, the candidate remains
cached and the previous active/LKG pointers stay unchanged.

Testing/beta promotion should run fixture and real provider acceptance.

Workspace retains active and last-known-good profile releases locally.

## 13. Trust model

Profile configuration is treated as executable behavior policy.

Trust chain:

~~~text
Cloud metadata
-> signed immutable profile payload
-> Workspace signature/digest verification
-> schema validation
-> engine compatibility validation
-> provider compatibility validation
-> candidate probe
-> activation
~~~

The Engine rejects schema constructs that would weaken runtime invariants.

Workspace continues to own publisher trust/revocation.

## 14. Profile security invariants

A Profile cannot:
- invoke a shell;
- construct one free-form shell command;
- disable output/deadline limits;
- inherit unrestricted environment;
- select arbitrary helper programs;
- escape Workstream/state boundaries;
- turn off session consistency validation;
- override Workspace local permissions;
- redefine Local Worker Protocol behavior.

Executable discovery is bounded to profile-declared provider tool candidates and
engine-approved discovery mechanisms.

Arguments are arrays, not shell strings.

## 15. Profile version compatibility

Profile releases explicitly support provider CLI versions.

Prefer new releases for material behavior changes.

Example:

~~~text
chatgpt-codex@9
codex >=0.160 <0.176

chatgpt-codex@10
codex >=0.176 <0.190
~~~

Small compatible variations may use bounded overrides inside one profile if the
schema can express them clearly and test fixtures cover them.

Do not accumulate large behavior branches in one profile.

## 16. Official Worker catalog

The logical Worker catalog is Cloud/product data, not compiled provider code.

Initial v8 product remains:

~~~text
ChatGPT -> chatgpt-codex
Gemini  -> gemini-antigravity
~~~

A future approved CLI Worker may be added without changing Workspace if:
- existing Engine capabilities are sufficient;
- a valid signed profile exists;
- product catalog policy enables it.

The user cannot add arbitrary catalog/profile entries in v8.

## 17. Workspace UI

Keep current UX.

Normal row:

~~~text
ChatGPT                  Ready
Codex 0.177
[Test] [Enabled]
~~~

Advanced diagnostics:

~~~text
Worker              ChatGPT
Engine              1.3.0
Integration Profile chatgpt-codex@10
Profile channel     Stable
Provider tool       Codex 0.177
Last passive probe  Passed
Last live test      Passed
~~~

Do not expose:
- profile JSON;
- profile editing;
- arbitrary executable selection;
- profile release channel selection to normal users.

## 18. Worker readiness

Readiness remains logical-Worker based.

A Worker is effectively ready when:

~~~text
Engine available
AND official Profile resolved/verified
AND provider CLI discovered
AND supported provider CLI version
AND passive auth/config checks pass
AND local permissions permit required behavior
AND optional setup live test has passed when product policy requires it
~~~

Disabled remains independent from readiness.

Testing a disabled Worker does not enable it.

## 19. Sessions

Conclave session keys remain provider-neutral.

~~~text
Work/Workflow
-> logical sessionKey
-> Engine/Profile
-> provider session ID
~~~

Provider session IDs remain local.

Profile describes extraction/resume mapping; Engine enforces identity continuity.
Workspace session state is partitioned by logical Worker, Profile definition,
provider tool identity, and logical `sessionKey`. A Profile Release may resume
an older provider session format only when its signed compatibility list names
that format; otherwise Engine starts a fresh provider session.

Separate sessions remain mandatory for independent verification steps.

## 20. Work v1

Architecture v8 keeps Work v1 unchanged above Worker resolution.

Canonical Steps:

~~~text
Research
Plan
Implement
Test
Verify
~~~

Built-in Workflows:

~~~text
Direct
Research
Plan & Implement
Implement & Verify
Full Cycle
~~~

Workstream configuration binds Steps to logical Workers, not profiles:

~~~text
Research  -> Gemini
Plan      -> Gemini
Implement -> ChatGPT
Test      -> ChatGPT
Verify    -> Gemini
~~~

When Cloud schedules ChatGPT, Workspace resolves ChatGPT to Engine + official
compatible profile locally.

## 21. Database target

### 21.1 Logical Worker catalog

Cloud product catalog:

~~~text
worker_catalog
  worker_type_id
  display_name
  description
  engine_family
  visibility_state
  release_stage
  capabilities_json
  sort_order
~~~

Each active catalog entry is joined to its active Tool Profile definition.
Workspace receives visible entries eligible for its Cloud-selected channel;
it cannot request a different channel. Profile release resolution is separate,
so a Worker can still render while its Profile is unavailable and must remain
unrunnable until a trusted compatible release is selected. A catalog entry can be created only by a platform
administrator through the approved catalog operation, which creates its
logical Worker and Profile definition together. Workspace users cannot create
catalog entries. Each release remains signed, immutable, and independently
validated before local activation.

The v8 product-capability list is closed and validated by Cloud and Workspace.
Workspace maps declared capabilities through fixed permission policy; a Tool
Profile cannot grant itself filesystem or general shell access. A new catalog
entry can use the existing Workspace UI and generic Engine once its approved
Profile release is available.

### 21.2 Tool Profile definitions

~~~text
tool_profile_definitions
  id
  logical_worker_type_id
  engine_family
  display_name
  created_at
~~~

### 21.3 Tool Profile releases

~~~text
tool_profile_releases
  profile_definition_id
  release_version
  schema_version
  lifecycle_state
  engine_min
  engine_max
  provider_tool_name
  provider_version_min
  provider_version_max
  payload_digest
  signed_payload / storage_key
  signing_key_id
  signature
  created_at
  promoted_at
  revoked_at
~~~

### 21.4 Audit/channel state

Store:
- lifecycle transitions;
- promotion actor/time;
- revocation reason;
- stable/testing/beta pointers where pointers are used;
- rollout metadata if gradual rollout is introduced later.

The exact normalized schema may differ, but releases remain immutable.

## 22. Safe Worker inventory

Cloud inventory should expose logical state plus safe runtime evidence:

~~~text
worker_id
workspace_id
worker_type_id
activation_state
readiness_state
readiness_issue_code

engine_version
profile_definition_id
profile_release_version
provider_tool_name
provider_tool_version

capabilities
concurrency
last_seen
~~~

Cloud does not receive:
- local provider executable path;
- provider session ID;
- local profile files;
- provider credentials.

The v8 inventory contract replaces the provider-native
`worker_runtime_version` field with the Engine and Profile evidence above.
New assignment snapshots and `worker_assignments` rows record Engine/Profile
identity. Each assignment stores that snapshot at dispatch, including the
provider tool version and explicit model, so later Profile promotions cannot
rewrite the evidence. Run history reads the stored snapshot instead of current
inventory. The migration renames the v7 assignment version column; no local
path or secret is included.

## 23. Observability

Every assignment/probe diagnostic correlates:

~~~text
Workspace version
Engine version
Profile definition/release
Provider tool/version
logical Worker
assignment/work request/task IDs
stable error code
duration
~~~

Workspace persists bounded local Engine/Profile probe records with the
resolution source, probe stage, stable error code, and failure layer
(`engine`, `profile`, or `provider_tool`). Engine records also include the
request/assignment identity where available. Advanced Diagnostics may show
Workspace and Engine versions, the official integration definition/release,
and provider CLI name/version. Diagnostics omit signed Profile payloads,
credential values, prompts, and free-form provider output.

This allows Conclave to distinguish:
- Engine regression;
- Profile regression;
- provider CLI incompatibility;
- auth/config issue;
- provider service failure;
- Work orchestration failure.

## 24. Profile fixture testing

Each official Profile release should ship or reference test fixtures covering:

~~~text
version output
auth success/failure
normal execution
tool-use progress
terminal success
terminal provider failure
invalid output
session start
session resume
version-specific variation
~~~

The generic Engine test harness runs profiles against fixtures without consuming
provider quota.

Real opt-in acceptance remains required before stable promotion for first-party
profiles.

## 25. Rollout channels

Recommended release process:

~~~text
Draft
-> static/schema validation
-> fixture tests
-> Testing
-> real provider acceptance
-> Beta (optional)
-> Stable
~~~

A critical stable regression may be handled by:
- immediate stable pointer rollback;
- revocation of the broken release if unsafe;
- new fixed release.

Existing active assignments keep their immutable resolved profile snapshot.

## 26. Assignment immutability

An assignment/run should record the effective local execution identity used:

~~~text
logical Worker ID
Engine version
Profile definition/release
provider tool version
model, if selected
~~~

The profile payload itself need not be copied into Cloud assignment data if the
release is immutable and addressable, but sufficient evidence must remain for
audit/reproducibility.

## 27. Compatibility with v7/v2

v8 preserves:
- Workspace-owned local execution;
- separate execution process;
- provider credentials staying local;
- Local Worker Protocol abstraction;
- process-tree supervision;
- local provider session storage;
- logical ChatGPT/Gemini Worker IDs;
- Work v1 orchestration.

v8 supersedes:
- one native Worker binary per provider;
- provider-specific Worker release catalog;
- Workspace-managed independent ChatGPT/Gemini executable versions;
- provider integration behavior compiled into separate Worker executables.

Worker Runtime v2 and its provider-specific binaries remain historical
design/evidence for the process boundary and migration fixtures only. They are
not the v8 runtime target.

## 28. Migration posture

Conclave is still in development.

Prefer convergence to permanent dual runtime.

Temporary migration may support:
- existing ChatGPT/Gemini v2 provider binaries as migration-only fallbacks;
- new generic Engine + profiles.

Release gate:

~~~text
ChatGPT generic Engine/profile real acceptance
AND
Gemini generic Engine/profile real acceptance
AND
profile update/rollback acceptance
AND
Cloud -> Workspace -> Engine -> provider acceptance
THEN
remove provider-specific Worker binaries
~~~

Do not ship indefinite per-provider-binary and profile-driven modes together.

## 29. Future engine families

Architecture v8 deliberately names this component CLI Worker Engine.

If future integrations are not CLI based, introduce another constrained engine
family rather than expanding the CLI Profile schema unnaturally.

Possible future examples:

~~~text
API Worker Engine
MCP Worker Engine
Local Model Server Engine
~~~

All may still expose the same logical Worker/Work orchestration abstraction.

## 30. Final v8 topology

~~~text
                         CONCLAVE AX
                             |
                       Work / Discuss
                             |
                             v
                       CONCLAVE CLOUD
                   scheduling + profiles
                             |
                             v
                    CONCLAVE WORKSPACE
                             |
                    logical Worker slot
                             |
                             v
                    CLI WORKER ENGINE
                     one generic binary
                             |
                    signed Tool Profile
                             |
                             v
                       provider CLI
~~~

Architecture v8 succeeds when adding or fixing a normal supported CLI
integration usually means publishing a tested signed Profile release rather
than rebuilding a native Worker executable.
