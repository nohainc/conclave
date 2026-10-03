# Operator Runbook: Creating a New Worker

**Role:** System Administrator / Engineering Maintainer  
**Surface:** Conclave Profile Lab (`apps/profile_lab`)  
**Scope:** Creating a new Logical Worker, Tool Profile Definition, testing initial Draft payload, publishing a signed release, and promoting through release channels.

Before publication, complete the local Test Ladder for the exact draft. Profile Lab submits the resulting qualification to Cloud, and Cloud requires its returned ID to publish. Stable promotion separately requires post-publication Cloud acceptance evidence.

---

## Prerequisites

1. **Profile Lab Access:** `profiles:admin` for catalog and draft work, plus `profiles:release:manage` for publication and rollout. Stable promotion, Stable channel assignment, rollback, and revocation also require a recent passkey step-up in the Profile Lab session.
2. **Provider CLI Binary:** Target provider CLI binary installed on the maintainer's workstation (e.g. `claude`, `codex`, or `agy`).
3. **Environment:** macOS environment with local provider CLI authenticated via vendor login flow (e.g., `claude login`).

---

## Step 1: Create Logical Worker & Profile Definition

1. Open **Conclave Profile Lab**.
2. Navigate to the **Workers Catalog** view.
3. Click **Add New Worker**.
4. Fill in the logical catalog fields:
   - **Worker Type ID:** `claude` (lowercase, alphanumeric identifier)
   - **Display Name:** `Claude`
   - **Description:** `Anthropic Claude CLI Worker`
   - **Engine Family:** `cli`
   - **Sort Order:** `3`
5. Click **Create Logical Worker**. Cloud creates the `worker_catalog` record.
6. In the resulting details screen, click **Create Profile Definition**:
   - **Profile Definition ID:** `claude-code`
   - **Provider Tool Name:** `claude`
   - **Supported CLI Versions:** `>=0.1.0 <2.0.0`
7. Confirm creation. Cloud binds `claude-code` as the active Profile Definition for `chatgpt`.

---

## Step 2: Author Initial Draft Profile

1. Navigate to the **Drafts** tab in Profile Lab.
2. Select **Create Draft** for Profile Definition `claude-code`.
3. Configure the initial JSON payload parameters:
   - `schemaVersion`: `1`
   - `providerTool`: Executable name `claude`, probe arguments `["--version"]`.
   - `execution`: Argument template `["--non-interactive", "--prompt", "{{prompt}}"]`.
   - `session`: Resume mechanics (`--session-id`, `{{sessionId}}`).
   - `timeout`: Default execution deadline (e.g. 300s).
   - `errors`: Exit code mapping rules (e.g. exit code 1 -> authentication required).
4. Click **Save Draft**. Profile Lab saves the draft locally in `DraftProfileStore`.

---

## Step 3: Local Sandbox Testing

1. In Profile Lab, select the newly saved Draft.
2. Click **Run Passive Probe**:
   - Profile Lab invokes `claude --version` out-of-process via `PlatformProcessSupervisor`.
   - Verify that status returns `PASS` and provider CLI version is captured.
3. Click **Run Live Probe**:
   - Enter a test prompt (e.g., `"Respond with OK"`).
   - Profile Lab executes the CLI in sandbox mode and validates event streaming and stdout parsing.
4. Click **Run Session Diagnostic Test**:
   - Verifies multi-turn session creation and resumption.
5. Run the complete **Test Ladder**. Schema, Engine compatibility, discovery, version, passive/live probes, applicable model/write/session scenarios, cancellation, and timeout must pass; only capability-inapplicable scenarios may be marked not applicable.

---

## Step 4: Request Signed Release Publication

1. Review the Draft payload and matching local qualification, then click **Qualify, Publish & Sign**.
2. Profile Lab submits the exact qualification contract to Cloud and receives an immutable `qualificationEvidenceId`.
3. Cloud revalidates the stored qualification against the current draft and requires its ID on the publish request before signing and writing the immutable release row (e.g., `Version 1`).

---

## Step 5: Promote Release to Testing Channel

1. Navigate to the **Releases & Channels** view in Profile Lab.
2. Select `claude-code` Version 1.
3. Click **Promote to Testing Channel**.
4. Cloud updates `workspace_tool_profile_channels` for `testing` to point to Version 1.

---

## Step 6: Verify Dynamic Discovery in Workspace & AX

1. Launch a **Conclave Workspace** desktop app configured for the `testing` channel.
2. Observe that `Claude` automatically appears in the Workspace Workers inventory without updating the Workspace application binary.
3. Click **Configure Worker** -> verify CLI executable path and green readiness indicator.
4. Open **Conclave AX** web app -> navigate to `/workspaces`.
5. Verify `Claude` is visible in the Workspace Worker inventory and can be selected as a Worker binding in Workstreams.
6. Dispatch a test Workstream step to `Claude` and confirm successful execution.

---

## Step 7: Promote to Beta

1. After successful operational verification in the `testing` channel:
   - Return to Profile Lab -> **Releases & Channels**.
   - Promote Version 1 to **Beta Channel**.
2. Stable promotion requires a separate post-publication acceptance evidence record stored in Cloud. Profile Lab submits the qualifying evidence separately and promotes using only the returned evidence ID.
