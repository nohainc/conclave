# Operator Runbook: Updating an Existing Profile

**Role:** System Administrator / Engineering Maintainer  
**Surface:** Conclave Profile Lab (`apps/profile_lab`)  
**Scope:** Editing an existing Tool Profile, running local sandbox verification, AI-assisted repair, publishing a new immutable release version, rollout promotion, rollback, and emergency revocation.

---

## Prerequisites

1. **Profile Lab Access:** Authenticated maintainer session with `profiles:admin` scope in Profile Lab (`apps/profile_lab`).
2. **Trigger Event:** Vendor CLI updated flags/behavior (e.g. Codex CLI `v0.188.0` added new flags or error output patterns), or bug fix required in existing profile.

---

## Step 1: Create a New Draft from Published Parent

1. Open **Conclave Profile Lab**.
2. Navigate to **Profiles & Definitions** -> Select target profile (e.g. `chatgpt-codex`).
3. View active releases (e.g. `Stable: Version 12`).
4. Click **Create Draft from Release v12**.
5. Profile Lab initializes a new Draft (targeting `Draft v13`) with parent release pointer `parentReleaseVersion: 12` and parent payload digest.

---

## Step 2: Edit Draft Payload (Manual or AI Repair Loop)

### Option A: Manual Authoring
1. Edit JSON fields in Profile Lab's code editor:
   - e.g., update `providerTool.supportedVersions` to `>=0.188.0`.
   - e.g., update `execution.arguments` to reflect new CLI flags.
2. Click **Save Draft**.

### Option B: AI Repair Loop
1. Click **Start AI Repair Loop**.
2. Specify the target issue or vendor CLI release note (e.g., *"Adapt profile to Codex CLI v0.188.0 streaming JSON output format"*).
3. Profile Lab executes the AI repair workflow:
   - Generates candidate JSON revision.
   - Validates JSON schema against `TOOL_PROFILE_LIMITS`.
   - Runs local sandbox probes.
   - Parses stdout/stderr logs and normalizes errors.
   - Prompts AI for necessary adjustments.
4. Review the generated **Diff View**:
   - Compare `Draft v13` against parent `Release v12`.
   - Verify AI provenance metadata (`creatorOrigin: ai`, `modelIdentifier`, `promptId`, `diffDigest`).
5. Click **Apply & Confirm Revision**.

---

## Step 3: Run Sandbox Verification

1. Click **Run Full Test Bench**:
   - Executes Passive Probe (`codex --version`).
   - Executes Live Probe (test prompt execution).
   - Executes Session Diagnostics (start and resume session).
2. Verify evidence completeness in **Evidence Checklist**:
   - Schema validation: PASS
   - Passive probe: PASS
   - Live probe: PASS
   - Session test: PASS

---

## Step 4: Publish New Immutable Release

1. Click **Publish Release v13**.
2. Profile Lab submits payload and test evidence to Cloud (`POST /api/admin/workers/definitions/chatgpt-codex/releases`).
3. Cloud signs `Draft v13` with Ed25519, freezes its payload digest, and creates `tool_profile_releases` Version 13.

---

## Step 5: Controlled Channel Rollout

1. **Promote to Testing:**
   - In Profile Lab, select Version 13 -> click **Promote to Testing**.
   - Test Workspaces on `testing` channel automatically receive Version 13.
   - Validate live Workstream execution in testing Workspaces.
2. **Promote to Beta:**
   - Click **Promote to Beta**. Beta Workspaces update to Version 13.
3. **Promote to Stable:**
   - Click **Promote to Stable**.
   - All production Workspaces on `stable` channel seamlessly update to Version 13 upon next catalog sync.

---

## Step 6: Rollback Procedure (If Issue Discovered)

If an unexpected regression is reported in Version 13:

1. Open Profile Lab -> **Releases & Channels**.
2. Select target profile (`chatgpt-codex`).
3. Select **Stable Channel** pointer.
4. Click **Rollback to Version 12**.
5. Cloud updates the channel pointer back to Version 12 instantly.
6. Workspaces immediately revert to executing signed Version 12 on their next periodic sync (or WebSocket update).

---

## Step 7: Emergency Revocation Procedure (Critical Vulnerability)

If a published profile release contains a severe defect or security hazard:

1. In Profile Lab -> **Releases & Channels**, select defective release (e.g. Version 13).
2. Click **Revoke Release**.
3. Confirm administrative step-up re-authentication.
4. Cloud sets `revoked_at` timestamp on `tool_profile_releases` Version 13.
5. Cloud and Workspaces permanently invalidate Version 13 across all channels. Any Workspace attempting to execute Version 13 immediately halts and rejects execution.
