# Workspace Runtime Service: Reliability and Recovery

The Workspace installation lock is acquired before recovery begins. While the
lock is held, startup reconciles the local assignment journal and the Worker
Engine process registry before accepting new work.

## Assignment recovery

The durable journal is stored under Workspace Application Data, separately
from the Work Root. Terminal results are flushed to the journal before they are
sent to Cloud. The exact result payload is retained so a completed result can
be retransmitted after a lost acknowledgement without rerunning the Worker.

On restart, a journal entry in `received` is recorded as interrupted with
`recoveryState: not_started`. `accepted`, `running`, and `cancelling` entries
become `interrupted` with `recoveryState: outcome_unknown`. Neither state is
automatically executed again. The local management snapshot exposes these
records under `assignments.recoveryRequired`; the record includes identifiers
and status only, not prompts.

Cloud currently returns active assignment states during sync but has no
versioned `outcome_unknown` state or operator recovery action. Consequently,
an uncertain assignment remains visible locally for recovery and Cloud may
continue to show it as active. Do not resolve that state by sending a synthetic
success or failure. A future protocol change must define the Cloud transition
and user-facing recovery action together.

## Worker process ownership

The generic CLI Worker Engine writes a PID record under the Workspace runtime
directory while an Engine is active. On service startup, it checks that the
recorded PID still has the exact bundled Engine executable and the recorded
private Worker state directory in its command line before terminating that
process tree. Invalid, stale, or uninspectable records are not signaled. If
process inspection is unavailable, records are retained for a later recovery
attempt. Graceful service shutdown still terminates active Worker Engine
process trees through the normal supervisor.

PID recovery is defense in depth, not an operating-system process-group
guarantee. macOS sleep suspends normal user processes; Conclave does not promise
execution while the machine sleeps. The Cloud connection's bounded reconnect
backoff resumes synchronization when the process and network become available
again.

## Credentials, logs, and idle work

Workspace authentication remains in the platform secure credential store
(Keychain on macOS); runtime credentials are not written to the assignment
journal or structured logs. Local Worker credentials remain owned by their
provider CLI. Worker Engine processes receive a small base environment for
executable discovery and user configuration (`HOME`, `PATH`, locale, and temp
paths), not the full service environment. Provider CLI processes receive only
the environment keys explicitly allowed by their signed Tool Profile.

Structured service logs include timestamp, severity, event, service version,
and Workspace ID. The active log and one rotated log are each bounded by the
configured limit (1 MiB by default). Log rotation and service-state refresh
use 30-second intervals; the management snapshot comparison uses a 5-second
interval while the manager is running.

## Remaining platform validation

The macOS LaunchAgent still runs in the logged-in user's context and cannot
execute while the Mac is asleep. Documents-folder and custom Work Root TCC
permissions, Keychain access under the installed LaunchAgent, and signed /
notarized update recovery must be verified with a distributed macOS build.
These checks cannot be established by Dart unit tests alone.
