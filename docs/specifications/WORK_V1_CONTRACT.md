# Work v1 Contract

**Contract ID:** `work:v1`
**Status:** Frozen
**Scope:** Work composer and built-in Workflow semantics in Conclave AX

This is the single authoritative catalog and semantic definition for Work v1.
Architecture v8 preserves Workspace ownership, Workstream isolation, Cloud/Workspace transport, AX-owned Worker usage policy, and the Workspace desktop lifecycle. Work v1 binds logical Workers and is intentionally independent from the underlying Engine/Profile implementation. A Work v1 Workflow describes the user-visible shape of a
Work Request; it does not select a Worker, provider, model, Workspace, or
execution permission.

The product flow is:

~~~text
Conclave defines canonical Steps
      ↓
Conclave defines valid built-in Workflows
      ↓
Workstream assigns Workers to Steps
      ↓
User selects a Workflow and enters a request
      ↓
Cloud snapshots the request and composes Step prompts
      ↓
Workers execute
~~~

AX reads Workflow names and descriptions from the built-in catalog endpoint,
which projects the shared core definitions. The composer selects the current
Workstream default on load; it does not maintain its own Workflow name list.

## Step kinds

`StepKind` is the closed set below. These meanings are provider-independent and
must be used consistently in Work UI, persisted Workflow snapshots, APIs, and
tests.

| `StepKind` | Meaning |
| --- | --- |
| `research` | Gather and summarize relevant evidence from the request and authorized context, including findings, available sources/references, constraints, uncertainties, and recommended next actions. Do not make requested changes. |
| `plan` | Turn the request and available evidence into an ordered implementation plan and clear completion criteria. Do not make requested changes. |
| `implement` | Make the requested changes in the Workstream execution context. |
| `test` | Run relevant tests or validation against the implementation and report commands/results. Do not intentionally change product source as part of the test step. |
| `verify` | Independently compare the result and available evidence with the request and completion criteria; report confirmed outcomes, gaps, and risks. Do not implement fixes. |

`review` is not a v1 `StepKind`; review and acceptance checking are represented
by `verify`. Step kinds are semantic labels, not provider roles or Worker IDs.

## Workflow identities and versions

`WorkflowId` is the closed set of stable identifiers:

```text
direct
research
plan_implement
implement_verify
full_cycle
```

Each definition has an immutable version. The v1 reference is written
`<WorkflowId>:v1`, for example `full_cycle:v1`. Display names are labels and
are not persisted identity keys. An existing version's ordered steps and
semantics never change; a future contract change requires a new version.

The core domain uses `BuiltinWorkflowDefinition` and `BuiltinWorkflowStep`:

```ts
type StepKind = "research" | "plan" | "implement" | "test" | "verify";
type WorkflowId =
  | "direct"
  | "research"
  | "plan_implement"
  | "implement_verify"
  | "full_cycle";

interface BuiltinWorkflowDefinition {
  id: WorkflowId;
  version: number;
  name: string;
  description: string;
  steps: BuiltinWorkflowStep[];
}

interface BuiltinWorkflowStep {
  kind: StepKind;
  order: number;
  executionMode: "stateless_read" | "stateful_workstream";
  executionClass: "analysis" | "workspace_action";
  requiredCapabilities: WorkflowCapability[];
  readWritePolicy: "read_only" | "write_workstream";
  timeoutMs: number;
  promptProfileVersion: string;
  dependsOn: StepKind[]; // fixed by the built-in definition
  inputsFrom: StepKind[]; // fixed upstream step results
  resultSemantics: WorkflowResultSemantics;
}
```

`WorkflowCapability` is a closed, provider-neutral set: `authorized_context_read`,
`workstream_write`, `test_execution`, and `independent_verification`.
`WorkflowResultSemantics` is likewise closed: `evidence_summary`,
`implementation_plan`, `workstream_changes`, `test_report`, and
`verification_report`. Step definitions set their required capabilities,
read/write policy, execution class, timeout, internal prompt profile, fixed
upstream inputs, and result semantics. These values are owned by Conclave and
are part of the immutable Workflow version.

## Before submission

Before creating a Work Request, Cloud resolves every required Step binding and
checks that each Worker exists, belongs to an active Project Workspace grant,
is enabled locally and for Cloud scheduling, and is Ready. Cloud also checks
that the Worker and grant provide every required Step capability and the grant
allows the permissions needed by the Step. Any explicitly configured model must
be permitted by the Workstream execution policy; if that policy has an explicit
model allowlist, a model must be selected from it.

The composer requests this eligibility check before submission and presents
issues grouped by Step. Cloud repeats the checks when creating the Work Request,
so a changed grant or Worker state cannot slip through after the composer
check. An ineligible Workflow does not create a Work Request or Run.

The v1 step policy is:

| Step | Execution class | Required capabilities | Read/write policy | Result |
| --- | --- | --- | --- | --- |
| `research` | `analysis` | `authorized_context_read` | `read_only` | `evidence_summary` |
| `plan` | `analysis` | `authorized_context_read` | `read_only` | `implementation_plan` |
| `implement` | `workspace_action` | `workstream_write` | `write_workstream` | `workstream_changes` |
| `test` | `workspace_action` | `authorized_context_read`, `test_execution` | `read_only` | `test_report` |
| `verify` | `workspace_action` | `authorized_context_read`, `independent_verification` | `read_only` | `verification_report` |

Each step currently has a 15 minute default timeout. `inputsFrom` names the
exact fixed upstream results supplied to the step; it is intentionally
different from task dependencies when an earlier result is relevant. The
provider-neutral capability names describe what the step needs from an
execution environment without selecting a Worker or tool.

## Internal Step Prompt Profiles

Cloud renders prompts through the single Work v1 prompt renderer. Its fixed
profiles are `research:v1`, `plan:v1`, `implement:v1`, `test:v1`, and
`verify:v1`. A Workflow step's `promptProfileVersion` selects exactly one
matching profile. The renderer consumes structured request text, attachments,
Project and Workstream instructions, step-specific instructions, authorized
upstream step results, and current Workstream context. It applies bounded input
limits. Direct is the one-step fast path: it preserves the submitted request
as the first prompt content, then adds only configured Project, Workstream, and
Direct instructions plus a short hidden instruction to act in the authorized
Workstream and return the result. Other Workflows begin with their fixed
StepKind instructions and include only the authorized handoff data for that
Step.
Profiles are internal, versioned Conclave instructions used by Cloud's prompt
renderer. They are not a user-facing template language: users cannot edit the
Conclave instructions, insert macros, or control handoff composition. Users
can specialize a run only through the bounded Project, Workstream, and
Step-specific additional-instruction fields defined below.

## Team collaboration and authorization

Work belongs to the shared Project and Workstream. A Project owner or
collaborator may submit a Work Request only when the member also passes the
Workstream's execute-access policy and the Project permission check. Viewers
cannot submit Work. Cloud enforces these checks when creating the request; the
composer's eligibility check is informational and is not an authorization
boundary.

Project members who have Workstream view access may inspect its Work timeline
and Run Details, including Work submitted by another member. Workstream access
policy still controls visibility. Read access does not grant execution or
configuration rights.

Changing the Workstream's default Workflow, Step bindings, or Workstream
instructions requires Workstream configuration access (`projects:write` plus
the Workstream manage rule). In the current model, that means a Project owner
or the collaborator assigned as Workstream lead. Cloud enforces this on every
configuration write, and the UI uses the server-projected `canConfigureWork`
capability to disable unavailable controls.

Every Work Request stores the authenticated submitter as
`requestedByUserId`; clients cannot choose or override this identity. Work
history and Run Details resolve the member's display name and show who
requested the Run. The immutable requester identity remains attached to the
Work Request even if membership or display-name data later changes.

## Step handoff semantics

The renderer passes only these inputs for each step. It does not append prior
Worker messages or conversational sessions.

Direct uses one durable logical session scope per Workstream's Direct binding:
`workstream:<workstreamId>:direct:work-conversation`. This lets later Direct
requests continue the same Work conversation. Multi-step Workflows use a
separate durable scope for each Work Request and Step:
`work-request:<workRequestId>:<stepKind>`. Retries resume only their own
Step's session; Verify never resumes Implement's session, even when both use
the same Worker. The provider's actual session identifier remains local to the
Worker; downstream prompt handoff is always the bounded upstream
`StepResult.text` rendered by Conclave.

Every completed Step uses the same Conclave-owned `StepResult` wrapper:

```ts
interface StepResult {
  text: string;
  status: "completed" | "failed" | "cancelled";
  startedAt: string;
  completedAt: string;
  workerId: string | null;
  workerRuntimeVersion: string | null;
  providerToolVersion: string | null;
  artifacts?: string[];
  changedFiles?: string[];
  testStatus?: "passed" | "failed" | "blocked" | "not_run";
}
```

The Worker final answer is plain text in `text`; Workers do not produce an
arbitrary JSON schema for Step-specific results. Conclave supplies attribution
and optional structured metadata only when it can derive them reliably. A
following Step receives the upstream result text (conceptually
`previousStep.text`) along with its other fixed inputs; result metadata and
provider conversation history are not appended to the prompt.

When a Workflow completes, its final Work answer is the terminal Step's text;
for `full_cycle:v1` this is Verify's report. The timeline keeps the ordered
Step states and selected Worker attribution as Conclave's execution summary.
When the Test report contains recognizable pass/fail/skip counts, Conclave
surfaces those counts separately as a short Test summary.

## Run details and observability

The Work timeline stays concise and links to a separately loaded Run details
view. Details use the immutable Work Request and Step records and show the
Workflow ID/version, original request, and each Step's status, assigned Worker,
Worker Runtime version, provider tool version when known, start/end/duration,
and bounded final result text. A queued Step may have no start time; a running
Step has elapsed time through the time details are loaded and no end time.

Advanced details may show the latest assignment ID, session policy, and stable
error code. Raw provider error strings, provider secrets, credential
environment, prompts/files by default, and local Worker logs are not included
in Run details. Results are truncated to a fixed safe display bound. Logs stay
local to Workspace and require an explicit diagnostic workflow to retrieve.

Cloud persists Step start and finish timestamps so duration reflects execution
rather than queue time. Older in-development records without these timestamps
fall back to available Step output or assignment timestamps.

| Step | Handoff |
| --- | --- |
| `research` | Original request, attachment contents, Project and Workstream instructions, Research-specific instructions. |
| `plan` | Original request, attachment metadata, Research result if present, Project and Workstream instructions, Plan-specific instructions. |
| `implement` | Original request, relevant Research result, Plan result if present, Project and Workstream instructions, Implementation-specific instructions, and access to the writable Workstream filesystem. |
| `test` | Original request, Plan result, Implementation result, Project and Workstream instructions, Test-specific instructions, and current Workstream filesystem. Test may run existing tests, builds, lint, and typecheck commands, but cannot edit application, test, configuration, or dependency files or fix failures. Requests to add tests are implemented in the Implement step, then checked by Test. |
| `verify` | Original request, relevant Research and Plan results, Implementation result, Test result if present, Project and Workstream instructions, Verify-specific instructions, and the current Workstream filesystem. Verify holds the active Workstream lease for filesystem identity, but its effective permissions and provider execution are read-only; it uses a fresh Work Request-scoped Verify session. |

These result selections are recorded in each built-in step's `inputsFrom`.
Research receives attachment contents; Plan receives attachment metadata only;
later steps receive neither. Current filesystem context is supplied only to
Test and Verify. Missing optional results are omitted. Selection is controlled
by the immutable Workflow definition and StepKind.

## Manual retry semantics

Retry is a user action on one failed Step in a failed Work Request. The retry
reuses the exact stored Work Request input, Workflow version, bindings, model
selections, instructions, attachment references, and prompt profile versions.
Completed upstream Steps are reused from their stored `StepResult`; only the
selected failed Step and its remaining downstream Steps execute again. A retry
creates a new Run record and retains prior assignment records for diagnostics.
There is no automatic Verify-to-Implement feedback loop.

An Implement retry requires an explicit session choice. Known pre-execution
failures such as provider unavailability, authentication, quota, missing CLI,
unsupported model/version, and permission denial recommend resuming the previous
session. Timeouts and internal/unknown failures recommend a fresh session
because the provider may have partially processed the turn. The user can
choose either option. A fresh retry gets a new logical session key; resume uses
the original Work Request and Step key. Other Step retries reuse only their own
Work Request-scoped session.

Retry admission rechecks the selected Worker's current readiness, Project grant,
capabilities, and permissions against the immutable binding snapshot. A failed
Run can be cancelled to close it without retrying. Repeated retries happen only
after another explicit user action.

Step identity and task role are the canonical `StepKind`; there is no separate
free-form `role`. A step's `executionMode`, read/write policy, timeout, prompt
profile, order, and dependencies are product-owned values. The current fixed
execution modes are `stateless_read` for `research` and `plan`, and
`stateful_workstream` for `implement`, `test`, and `verify`. A stateful
read-only step keeps the active Workstream lease to inspect the exact current
filesystem, while its effective permissions exclude repository write. Shell
execution is withheld except for Test, which needs it for validation commands;
Test's provider still runs in its read-only sandbox. Workspace passes the
explicit read-only constraint to its provider integration; the
provider-specific Worker maps that constraint to its CLI's read-only mode.
Verify always uses its own Work Request-scoped provider session, including when
the same Worker performed Implement.

## Built-in catalog

This table is the only authoritative v1 built-in Workflow set. Steps run in the
listed order; each step depends on the immediately preceding step. `direct`
means one direct implementation step, not a separate `StepKind`.

| Workflow reference | Display name | Fixed steps |
| --- | --- | --- |
| `direct:v1` | Direct | `implement` |
| `research:v1` | Research | `research` |
| `plan_implement:v1` | Plan & Implement | `plan` → `implement` |
| `implement_verify:v1` | Implement & Verify | `implement` → `verify` |
| `full_cycle:v1` | Full Cycle | `research` → `plan` → `implement` → `test` → `verify` |

Canonical definition shape:

```yaml
contract: work:v1
workflows:
  - id: direct
    version: 1
    steps: [implement]
  - id: research
    version: 1
    steps: [research]
  - id: plan_implement
    version: 1
    steps: [plan, implement]
  - id: implement_verify
    version: 1
    steps: [implement, verify]
  - id: full_cycle
    version: 1
    steps: [research, plan, implement, test, verify]
```

This catalog fixes the complete step sequence for each reference. The
Workstream may choose a default built-in, and an authorized Work Request may
select one of the same built-ins. A submitted request snapshots its exact
Workflow reference and resolved steps so later releases cannot reinterpret a
run already created.

## Persistence

The built-in catalog is code/versioned product data. Cloud does not look up a
Workflow definition in a database. Each Work Request stores `workflow_id`,
`workflow_version`, and the complete immutable `workflow_snapshot_json`.
Execution records refer to the Work Request; the snapshot is the source for
their Workflow semantics. When a built-in gets a new version, retain the old
catalog entry so existing snapshots remain verifiable and reproducible.
Cloud serves the authoritative definitions at `GET /api/workflows/catalog` as
`{ workflows: BuiltinWorkflowDefinition[] }`. AX loads this response for
display and selection rather than maintaining a second Workflow list. Backend
validation and tests use the same shared core catalog.

Submission also captures a versioned execution snapshot in `snapshot_json`:

```ts
interface WorkRequestSnapshot {
  schemaVersion: 1;
  originalRequest: string;
  attachmentReferences: WorkRequestAttachmentReference[];
  workflowId: WorkflowId;
  workflowVersion: number;
  workflowSnapshot: BuiltinWorkflowDefinition;
  resolvedBindings: Partial<Record<"direct" | StepKind, WorkstreamStepBinding>>;
  projectInstructions: string;
  workstreamInstructions: string;
  stepAdditionalInstructions: Partial<Record<StepKind, string>>;
  promptProfileVersions: Partial<Record<StepKind, string>>;
}
```

## Work Request attachments

Attachments are inputs to a Work Request, not Workflow definitions. A request
may include local files and `http`/`https` references. The v1 composer accepts
up to 10 attachments and at most 1 MiB of local file content in total; each
file is also limited to 1 MiB. Links are limited to 2,048 characters and may
not embed URL credentials. Cloud stores bounded file bytes in the Work Request
input and stores only safe metadata/URL references in the immutable snapshot.

The safe Worker inventory exposes the closed input capability set `text`,
`image`, `audio`, `video`, and `local_file`, derived from each Worker release's
declared capabilities. The composer eligibility check verifies text support
for every selected Step, then checks attachment modalities for the bound
Research and Implement Workers (Direct uses the Implement binding). Local
files require `local_file` plus the matching text/image/audio/video capability
when their MIME type identifies one. The Workspace grant must allow each
required input capability. Incompatibility is reported before submission with
the affected Step, Worker, and input type. URL references are ordinary text
references and do not request provider fetching by Workspace. Direct,
Research, and Implement receive safe relative file references; Plan receives
attachment metadata, and Test/Verify use their defined handoff inputs.
Workstream-local execution materializes file bytes under
`.conclave/inputs/<work-request-id>/file-NNN`; paths are derived from
server-generated request identity and attachment order, never accepted from
the client. The same materialized files are immutable across retries. This
does not add media-specific Workflows or imply that every provider understands
every file format. The current ChatGPT and Gemini releases declare `text` and
`local_file`; until a release explicitly declares more, image, audio, and video
attachments are rejected during eligibility validation.

```ts
interface WorkRequestAttachmentReference {
  kind: "file" | "url";
  name: string;
  mediaType: string;
  sizeBytes: number;
  url?: string;
}
```

Cloud copies the selected binding and its Worker ID, model, fallback, and
additional instructions for each Step in the selected Workflow. Assignment
selection and prompt construction read these snapshots for a Work Request;
they do not consult later Workstream bindings or Project/Workstream
instructions. The submitted input and attachment contents are also retained
in `input_json`. Status and execution records may change, but the Workflow and
execution snapshots do not. Pre-snapshot Work Requests cannot be reconstructed
reliably and must be resubmitted in development environments.
The development baseline omits the former project-owned Workflow tables;
existing local databases created from that unreleased schema must be reset and
rebootstrapped rather than upgraded through a compatibility layer.

## Workstream Work configuration

### Direct execution path

Direct Work Requests use the configured `direct` Worker binding and are
serialized by a Workstream runtime lease. Cloud dispatches the assignment to
the selected Worker's Workspace; the Workspace starts the native Worker
executable. Work Requests, step progress, Worker/provider version attribution,
timing, and final results are available to AX through the Workstream history
API. The timeline reconstructs from Cloud after page reload or browser restart,
and each Run retains its original request text. Direct requests do not pass
through the legacy multi-role Forge runner.

Work lifecycle changes publish durable Cloud realtime events: `work_request`
creation/start/completion/failure/cancellation and Step
queued/running/completion/failure/cancellation.
AX subscribes to the current Workstream and refreshes the persisted timeline on
each matching event. Reconnect gaps trigger a full history refresh. The Run card
shows product Step names and states such as `running`, `done`, and `waiting`;
assignment identifiers and lease details remain out of the user-facing card.

Cancellation is available for queued and running Work Requests. For an active
assignment, Cloud waits for the Workspace runtime to acknowledge cancellation
after terminating the Worker and its provider process tree. If the Workspace
does not confirm termination, cancellation fails and the Run remains active so
the user can retry. On confirmation, the current Step and queued downstream
Steps become cancelled; completed earlier Step results remain available in Run
details. The timeline identifies the interrupted Step (for example, `Cancelled
during Implement`). A Work Request is not marked cancelled while its active
Worker process may still be running.

Each Workstream stores one constrained `WorkstreamWorkConfig`:

```ts
interface WorkstreamWorkConfig {
  defaultWorkflowId: WorkflowId;
  workstreamInstructions?: string;
  bindings: Partial<Record<
    "direct" | StepKind,
    {
      workerId?: string;
      model?: string;
      fallbackWorkerId?: string;
      additionalInstructions?: string;
    }
  >>;
}
```

The binding IDs are fixed to `direct`, `research`, `plan`, `implement`, `test`,
and `verify`. `direct` configures the one-step Direct Workflow; the remaining
IDs configure the corresponding canonical Step across built-in Workflows. A
missing binding fails closed when that Step is scheduled. Cloud considers the
configured Worker and, if present, its one fallback Worker. Model and
additional instructions are optional and remain attached to the selected
binding. No arbitrary role names, role-specific concurrency values, or
fallback-to-any policy are part of this contract.

`workstreamInstructions` is an optional Workstream-wide text field, bounded to
4,000 characters. Project instructions remain in Project settings, and each
Step may have additional instructions in its Worker binding. These three
user-editable instruction levels are appended after Conclave's immutable
StepKind guidance. The run-specific request remains a separate labeled input;
handoff data continues to be selected and supplied by Conclave.

AX may offer a one-click suggested setup using Ready Workers available through
Project Workspace grants. The mixed ChatGPT/Gemini suggestion and single-Worker
suggestions are UI conveniences only: they do not constrain the catalog or
execution model, and users may edit every binding afterward.

## Explicit non-goals for v1

- custom Workflow creation;
- drag-and-drop Workflow design;
- arbitrary step ordering;
- arbitrary macros or user-composed Workflow definitions;
- user-defined step dependencies;
- user-editable Conclave system prompts;
- custom conditional branches.

Workflow selection does not override AX-owned Step binding/model/fallback
policy, Cloud authorization, Workspace readiness, local permissions, or
Workstream execution rules. The Work request text remains user input; Conclave
system prompts and the meaning of each `StepKind` remain product-owned.

## Migration note

The earlier V6 Workflow presets and runner model are historical implementation
details, not the Work v1 catalog. In particular, old names such as
`Implementation`, `Review`, and `Implementation + Test + Review` must not be
added to new Work v1 UI or APIs. AX obtains current definitions from the shared
built-in catalog and must not maintain a duplicate Workflow list.


## Architecture v8 runtime note

Work v1 continues to resolve `chatgpt`, `gemini`, and future logical Worker IDs only. Workspace resolves the selected logical Worker to an admitted generic CLI Worker Engine plus official compatible Tool Profile locally. Workflow definitions and Step prompt semantics never depend on Profile IDs or provider CLI command formats.
