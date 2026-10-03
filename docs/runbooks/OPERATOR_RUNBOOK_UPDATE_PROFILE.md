# Operator Runbook: Updating an Existing Profile

**Role:** System Administrator / Engineering Maintainer  
**Surface:** Conclave Profile Lab (`apps/profile_lab`)  
**Scope:** Editing an existing Tool Profile, running local sandbox verification, AI-assisted repair, publishing a new immutable release version, rollout promotion, rollback, and emergency revocation.

Before publication, complete the local Test Ladder for the exact draft. Profile Lab submits the resulting qualification to Cloud, and Cloud requires its returned ID to publish. Stable promotion separately requires post-publication Cloud acceptance evidence. The Draft Assistant can request a model-backed proposal through a trusted Stable Worker Profile and the local generic Engine. Review its diff and apply it to the local Draft explicitly; it is never qualification or acceptance evidence. The Repair Loop remains an experimental local heuristic.

---

## Prerequisites

1. **Profile Lab Access:** `profiles:admin` for catalog and draft work, plus `profiles:release:manage` for publication and rollout. Stable promotion, Stable channel assignment, rollback, and revocation also require a recent passkey step-up in the Profile Lab session.
2. **Trigger Event:** Vendor CLI updated flags/behavior (e.g. Codex CLI `v0.188.0` added new flags or error output patterns), or bug fix required in existing profile.

---

## Step 1: Create a New Draft from Published Parent

1. Open **Conclave Profile Lab**.
2. Navigate to **Profiles & Definitions** -> Select target profile (e.g. `chatgpt-codex`).
3. View active releases (e.g. `Stable: Version 12`).
4. Click **Create Draft from Release v12**.
5. Profile Lab initializes a new Draft (targeting `Draft v13`) with parent release pointer `parentReleaseVersion: 12` and parent payload digest.

---

## Step 2: Edit Draft Payload (Manual, Model Proposal, or Experimental Repair Loop)

### Option A: Manual Authoring
1. Edit JSON fields in Profile Lab's code editor:
   - e.g., update `providerTool.supportedVersions` to `>=0.188.0`.
   - e.g., update `execution.arguments` to reflect new CLI flags.
2. Click **Save Draft**.

### Option B: Model-backed Draft Proposal
1. Sign in to Profile Lab and open **AI Draft Proposal**.
2. Select a trusted Stable Worker Profile and confirm that the current Draft and bounded test diagnostics may be sent through its provider CLI.
3. Request a proposal, review the domain diff, then choose **Review & Apply to Draft**. The proposal changes only the local editor; save the Draft separately.
4. If no trusted Stable Worker Profile appears, check the Cloud catalog and the `CONCLAVE_RELEASE_TRUST_KEYS_JSON` build configuration.

### Option C: Experimental Heuristic Repair Loop
1. Click **Experimental Repair**.
2. Specify the target issue or vendor CLI release note (e.g., *"Adapt profile to Codex CLI v0.188.0 streaming JSON output format"*).
3. Profile Lab executes the local heuristic repair workflow:
   - Generates candidate JSON revision.
   - Validates JSON schema against `TOOL_PROFILE_LIMITS`.
   - Runs local sandbox probes.
   - Parses stdout/stderr logs and normalizes errors.
   - Applies experimental local heuristic rules to the failed stages.
4. Review the generated **Diff View**:
   - Compare `Draft v13` against parent `Release v12`.
   - Review the proposed local repair diff; this heuristic output is not model-generated evidence.
5. Click **Apply & Confirm Revision**.

---

## Step 3: Run Sandbox Verification

1. Click **Run Full Test Ladder**. It must pass schema, Engine compatibility, discovery, version, passive/live probes, applicable model/write/session scenarios, cancellation, and timeout. Only capability-inapplicable scenarios may be marked not applicable.
2. Confirm the qualification evidence matches the current `payloadDigest`; any edit requires a new Test Ladder run.

---

## Step 4: Publish New Immutable Release

1. Click **Qualify, Publish & Sign**.
2. Profile Lab submits the complete local qualification to Cloud and receives an immutable qualification ID.
3. Cloud revalidates the stored evidence against `Draft v13`, requires its ID on the publish request, signs the payload with Ed25519, and creates the immutable release.

---

## Step 5: Controlled Channel Rollout

1. **Promote to Testing:**
   - In Profile Lab, select Version 13 -> click **Promote to Testing**.
   - Test Workspaces on `testing` channel automatically receive Version 13.
   - Validate live Workstream execution in testing Workspaces.
2. **Promote to Beta:**
   - Click **Promote to Beta**. Beta Workspaces update to Version 13.
3. **Stable promotion:** Submit qualifying post-publication acceptance evidence to Cloud, then promote using only the returned immutable evidence ID.

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
