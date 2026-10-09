# Conclave AX Workspaces UX and Data Contract

**Status:** Current AX read model. Workspace ownership and desktop lifecycle follow [ADR-013](../decisions/ADR-013-desktop-auth-and-dual-transport.md) and [ADR-014](../decisions/ADR-014-workspace-desktop-lifecycle.md).

**Architecture:** v8, Workspace-owned logical Workers with the generic CLI Worker Engine and signed Tool Profiles.

## Product contract

The top-level execution-capacity page is **Workspaces**. Each Workspace card groups its machine status, locally owned Workers, Space grants, and recent execution activity. AX reads safe Cloud projections; it does not manage local Worker setup or machine process state.

- Workspace represents one registered machine runtime and has one Cloud owner.
- Each logical Worker belongs to exactly one Workspace.
- Worker inventory and readiness are reported by Workspace. AX does not probe provider CLIs or start assignments directly.
- Space owners grant Workspaces access to Spaces. Threads bind logical Worker IDs under Cloud authorization.
- Stateful Threads use their configured Workspace. Stateless execution may use another authorized Workspace when the Work policy permits it.
- Workspace registration and local recovery are managed by the Conclave Workspace desktop application.

Filesystem terminology is explicit: a Workspace is the execution environment,
the Application Data Root is private application-managed state, the Work Root
is user-owned working data, and each Space Work Directory is a directory under
the Work Root. The Workspace UI never asks users to choose the Application
Data Root. On macOS the family root is `~/Library/Application Support/Conclave/`
and the default Work Root is `~/Documents/Conclave`.
Space directories are bound to immutable Space IDs through private registry
metadata and an identity marker. Threads share their Space directory and do
not receive directories by default.

## Workspace overview model

AX may assemble a `WorkspaceOverview` from focused Cloud responses. The UI
contract is independent of the physical endpoint layout.

~~~text
WorkspaceOverview {
  workspace: WorkspaceSummary
  runtime: WorkspaceRuntimeSummary
  workers: List<WorkspaceWorkerSummary>
  spaceGrants: List<WorkspaceSpaceGrantSummary>
  activity: WorkspaceActivitySummary
}
~~~

`WorkspaceSummary` contains the ID, name, lifecycle state, current user's owner role, and timestamps. IDs and timestamps support routing and diagnostics; the card leads with the Workspace name.

`WorkspaceRuntimeSummary` contains connection state, safe machine facts, app version, capabilities where appropriate, and last-seen timestamps. Missing facts remain unknown; AX does not fabricate machine state.

`WorkspaceWorkerSummary` contains the logical Worker ID and type, owning Workspace ID, activation and readiness states, a safe attention code, Engine/Profile/provider CLI version facts, capabilities, local concurrency ceiling, and last-seen time. The projection excludes executable paths, credentials, local permission names, tokens, model defaults, raw command output, and authentication files.

Activation and readiness are independent. Disabling a Worker does not erase its readiness result. Cloud scheduling state and limits are separate Cloud-owned controls.

The Cloud Worker API is versionless. `GET /api/workers` returns safe inventory; scheduling controls remain Cloud-owned. Thread Work configuration binds `direct` and the five Work v1 Steps to logical Worker IDs.

## Workspace page behavior

- `/workspaces` is the canonical collection route.
- `/workspaces/:workspaceId` opens the collection with the selected Workspace expanded and focused.
- Workers appear only within their owning Workspace card.
- The page may show connection state, safe machine facts, Worker readiness, Space access, and activity counts.
- Empty state directs the user to install and sign in to Conclave Workspace, which registers the machine.
- An offline registered Workspace remains visible as offline. Reconnection and ownership recovery are handled by the desktop app.
- AX does not expose local Worker setup, credentials, process controls, local paths, or machine repair actions.

## Thread execution configuration

Thread configuration is Cloud-owned and constrained by the [Work v1 Contract](../specifications/WORK_V1_CONTRACT.md). A binding names a local Worker ID. It may also retain a display-name snapshot for explaining a binding whose Worker is no longer available; that snapshot is presentation-only and never affects authorization or scheduling. It does not contain an Engine version, Profile release, provider executable path, or secret.

~~~json
{
  "defaultWorkflowId": "full_cycle",
  "bindings": {
    "direct": {
      "workerId": "stable-worker-id",
      "workerLabel": {
        "displayName": "Claude",
        "workspaceName": "Vitalii's MacBook Pro"
      }
    },
    "implement": { "workerId": "stable-worker-id" },
    "verify": {
      "workerId": "stable-worker-id",
      "model": "provider-model-id",
      "additionalInstructions": "Check the migration path."
    }
  }
}
~~~

Cloud checks a Thread's Space access and Workspace grants before scheduling. Workspace enforces its local readiness, permissions, concurrency limit, and process lifecycle. AX displays the effective Space Workflow bindings from ready logical Workers; execution configuration is edited in the Workflows surface rather than on a Thread.

## Ownership boundaries

| Concern | Owner | AX treatment |
| --- | --- | --- |
| Workspace identity, owner, lifecycle | Cloud | Show current safe summary |
| Runtime credential and connection | Workspace and Cloud | Show connected/offline state |
| Machine facts | Workspace reports; Cloud stores safe facts | Show concise, non-secret details |
| Worker setup, activation, and readiness | Workspace | Show safe inventory and status |
| Provider CLI authentication | Provider CLI on the Workspace machine | Never read or write credentials in AX |
| Space membership and Workspace grants | Cloud | Provide authorized Space controls |
| Space Workflow bindings and scheduling | Cloud | Provide Space Workflows configuration; Threads display the effective choices |
| Work Root, local files, processes, and logs | Workspace | Do not expose local paths or secrets in ordinary AX UI |

## Connection display

Connection mode is informational. The UI may distinguish WebSocket from HTTPS fallback while work remains available. It does not offer transport selection or imply that a human management session is valid.
