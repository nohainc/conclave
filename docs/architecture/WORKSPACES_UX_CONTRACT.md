# Conclave AX Workspaces UX and Data Contract

**Status:** Current AX read model. Workspace ownership and desktop lifecycle follow [ADR-013](../decisions/ADR-013-desktop-auth-and-dual-transport.md) and [ADR-014](../decisions/ADR-014-workspace-desktop-lifecycle.md).

**Architecture:** v8, Workspace-owned logical Workers with the generic CLI Worker Engine and signed Tool Profiles.

## Product contract

The top-level execution-capacity page is **Workspaces**. Each Workspace card groups its machine status, locally owned Workers, Project grants, and recent execution activity. AX reads safe Cloud projections; it does not manage local Worker setup or machine process state.

- Workspace represents one enrolled machine runtime and has one Cloud owner.
- Each logical Worker belongs to exactly one Workspace.
- Worker inventory and readiness are reported by Workspace. AX does not probe provider CLIs or start assignments directly.
- Project owners grant Workspaces access to Projects. Workstreams bind logical Worker IDs under Cloud authorization.
- Stateful Workstreams use their configured Workspace. Stateless execution may use another authorized Workspace when the Work policy permits it.
- Workspace enrollment and local repair are managed by the Conclave Workspace desktop application.

## Workspace overview model

AX may assemble a `WorkspaceOverview` from focused Cloud responses. The UI
contract is independent of the physical endpoint layout.

~~~text
WorkspaceOverview {
  workspace: WorkspaceSummary
  runtime: WorkspaceRuntimeSummary
  workers: List<WorkspaceWorkerSummary>
  projectGrants: List<WorkspaceProjectGrantSummary>
  activity: WorkspaceActivitySummary
}
~~~

`WorkspaceSummary` contains the ID, name, lifecycle state, current user's owner role, and timestamps. IDs and timestamps support routing and diagnostics; the card leads with the Workspace name.

`WorkspaceRuntimeSummary` contains connection state, safe machine facts, app version, capabilities where appropriate, and last-seen timestamps. Missing facts remain unknown; AX does not fabricate machine state.

`WorkspaceWorkerSummary` contains the logical Worker ID and type, owning Workspace ID, activation and readiness states, a safe attention code, Engine/Profile/provider CLI version facts, capabilities, local concurrency ceiling, and last-seen time. The projection excludes executable paths, credentials, local permission names, tokens, model defaults, raw command output, and authentication files.

Activation and readiness are independent. Disabling a Worker does not erase its readiness result. Cloud scheduling state and limits are separate Cloud-owned controls.

The Cloud Worker API is versionless. `GET /api/workers` returns safe inventory; scheduling controls remain Cloud-owned. Workstream Work configuration binds `direct` and the five Work v1 Steps to logical Worker IDs.

## Workspace page behavior

- `/workspaces` is the canonical collection route.
- `/workspaces/:workspaceId` opens the collection with the selected Workspace expanded and focused.
- Workers appear only within their owning Workspace card.
- The page may show connection state, safe machine facts, Worker readiness, Project access, and activity counts.
- Empty state directs the user to install and sign in to Conclave Workspace, which registers the machine.
- An offline enrolled Workspace remains visible as offline. Reconnection and ownership recovery are handled by the desktop app.
- AX does not expose local Worker setup, credentials, process controls, local paths, or machine repair actions.

## Workstream execution configuration

Workstream configuration is Cloud-owned and constrained by the [Work v1 Contract](../specifications/WORK_V1_CONTRACT.md). A binding names a logical Worker ID; it does not contain an Engine version, Profile release, provider executable path, or secret.

~~~json
{
  "defaultWorkflowId": "full_cycle",
  "bindings": {
    "direct": { "workerId": "stable-worker-id" },
    "implement": { "workerId": "stable-worker-id" },
    "verify": {
      "workerId": "stable-worker-id",
      "model": "provider-model-id",
      "additionalInstructions": "Check the migration path."
    }
  }
}
~~~

Cloud checks a Workstream's Project access and Workspace grants before scheduling. Workspace enforces its local readiness, permissions, concurrency limit, and process lifecycle. AX may suggest bindings from ready logical Workers; suggestions are ordinary editable Workstream settings.

## Ownership boundaries

| Concern | Owner | AX treatment |
| --- | --- | --- |
| Workspace identity, owner, lifecycle | Cloud | Show current safe summary |
| Runtime credential and connection | Workspace and Cloud | Show connected/offline state |
| Machine facts | Workspace reports; Cloud stores safe facts | Show concise, non-secret details |
| Worker setup, activation, and readiness | Workspace | Show safe inventory and status |
| Provider CLI authentication | Provider CLI on the Workspace machine | Never read or write credentials in AX |
| Project membership and Workspace grants | Cloud | Provide authorized Project controls |
| Workstream Worker bindings and scheduling | Cloud | Provide Workstream execution settings |
| Work Root, local files, processes, and logs | Workspace | Do not expose local paths or secrets in ordinary AX UI |

## Connection display

Connection mode is informational. The UI may distinguish WebSocket from HTTPS fallback while work remains available. It does not offer transport selection or imply that a human management session is valid.
