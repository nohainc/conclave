# Worker Activity Protocol V1

Worker Activity is the provider-neutral live execution event contract carried
by the Local Worker Protocol. It supplements, rather than replaces, the
existing `progress` frame while consumers migrate. A Worker Engine may emit
both frames for the same provider output.

## Frame

An activity frame is one JSON object per protocol line with `type: "activity"`.
It contains `requestId`, `assignmentId`, `executionId`, `workerId`, `eventId`,
positive `sequence`, an ISO-8601 `timestamp`, normalized `eventType`,
`status`, and a safe bounded `title`. It may contain `activityId`,
`percentage`, and bounded `details`.

Normalized event types are `execution.started`, `model.started`,
`message.updated`, `tool.started`, `tool.completed`, `tool.failed`,
`model.status`, `execution.completed`, `execution.failed` and
`execution.cancelled`. Status values are `running`, `updated`, `completed`,
`failed` and `cancelled`.

The protocol enforces a 1 MiB frame limit. Activity details are limited to
16 KiB, four nested levels and 32 fields/items per object or array. Detail
keys are safe ASCII names and values are bounded JSON scalars, arrays or
objects only. Content-bearing selectors such as prompts, text, output,
commands, arguments, stdout/stderr and environment values are rejected for
activity details. Executable values, provider credentials and arbitrary
transformation code are not permitted.

## Ordering and terminal behavior

The Engine assigns a new sequence to every emitted activity, including
repeated tool calls that have the same type or percentage. Consumers should
deduplicate by `eventId`, ignore duplicate or late events, and buffer or mark
out-of-order events using `sequence`; they must not manufacture a new activity
from an old sequence. Every admitted execution emits `execution.started` and
exactly one terminal activity before its result/error frame. A terminal event
is not inferred from percentage.

## Profile mapping

Profiles may contain an optional `activity.mappings` array. Each mapping has a
bounded declarative `when` condition list, normalized `type`, `status`, static
`title`, and optional selectors for `activityId`, message and safe detail
fields. A mapping may include an optional percentage. Selectors use the same
bounded JSON selector grammar as existing Profile mappings. Unknown provider
events simply match no rule and are ignored; no provider-specific Engine branch
or executable Profile script is allowed.

The Codex and agy fixtures use the same mapping shape and produce equivalent
`tool.started`/`tool.completed` activity pairs even though their native event
names and nesting differ.

Profile Lab replays a bounded, sanitized Codex or agy JSONL fixture against the
candidate mapping before publication evidence is eligible for Cloud. The replay
is bound to the candidate digest and verifies normalized event types, statuses,
activity identifiers, safe scalar details, and repeated tool lifecycle pairs.
Unknown provider events are ignored. JSONL Profiles with declared activity
mappings and no passing fixture replay cannot publish; plain-text Profiles are
explicitly not applicable. Arbitrary transforms, scripts, prompts, model
content, terminal output, environment values, and credentials are rejected by
Profile validation.

Existing percentage progress mappings remain temporarily for older Workspace
binaries. They are compatibility output only and are not the V9 activity
qualification signal.

Existing `progress` frames remain available for milestone consumers. Activity
frames are the authoritative repeated-event stream for live timelines. The
Workspace relay forwards activity as `assignment.activity` over the existing
runtime transport. Its bounded queue coalesces replaceable model/status
updates, applies backpressure to important lifecycle events, and records
forwarding failures as Workspace diagnostics without converting a lost
cosmetic event into Worker failure.

## Cloud delivery and recovery

Cloud validates the runtime origin against the current assignment, Workspace
runtime, Worker, run, task and attempt before publishing an activity. The
payload is normalized and size-limited; provider JSON, terminal output,
reasoning and arbitrary tool output are not stored.

Lifecycle and tool events are replayable. Cloud persists their sanitized
envelopes in the existing realtime event stream and a bounded
assignment-scoped history projection. `model.status` and `message.updated`
remain ephemeral. The event identity is derived from assignment, attempt and
source event identity, so retries are idempotent.

Realtime clients acknowledge durable stream positions through their existing
cursor hello. On subscription or reconnect, the realtime Gateway replays
events after the acknowledged sequence, suppresses duplicates, and emits a
gap signal when retained history cannot fill a sequence gap. The assignment
result/error remains the authoritative completion record; activity is
diagnostic and timeline state only.

## AX Work presentation

Conclave AX renders activity inside the existing Work execution card. The
operational panel identifies the logical Worker and provider CLI, shows elapsed
time, keeps active tool rows visible, and moves completed rows behind a compact
summary. A tool completion with the same activity identifier updates its
started row; it does not create a second timeline entry.

AX keeps activity state separate from Work messages and result text. It accepts
only normalized safe fields, never renders raw provider JSON, chain of thought,
terminal output or unrestricted tool output, and bounds the local assignment
projection. Replayed events are deduplicated by event identity and attempt,
while the bounded activity list uses a virtualized scroll surface for long
executions.
