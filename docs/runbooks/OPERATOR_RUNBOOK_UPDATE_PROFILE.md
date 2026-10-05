# Operator Runbook: Updating an Existing Profile

**Surface:** Conclave Profile Lab (`apps/profile_lab`)  
**Scope:** Edit and qualify a Worker’s Draft, sync Cloud state, publish an immutable release, and control rollout.

## Prerequisites and context

Sign in with `profiles:admin` for catalog/Draft work and `profiles:release:manage` for signed publication and rollout. Stable promotion/assignment, rollback, and revocation require a recent passkey verification in the Profile Lab session. Provider credentials remain local. Cloud must enable publishing and report a ready signer before publication is available.

Open **Workers**, select the logical Worker, and keep it selected throughout **Overview**, **Draft & Test**, and **Releases**. Catalog stage is catalog maturity; the Testing/Beta/Stable cards show actual Profile channel pointers.

## Create the next Draft

If a local Draft exists, open **Draft & Test**. Otherwise, open **Releases**, inspect the appropriate published parent, and choose **Create next Draft** from **Release actions**. Profile Lab creates the next local version and retains parent lineage. The Worker already determines the definition; no separate Draft selector is used.

Review version, local save state, and Cloud sync state in the workbench header. The structured Inspector and either Editor/Test pane can collapse; wide windows provide a resizable split.

## Edit and test

Edit the schema-aware JSON, then choose **Save** or `⌘S`. Advanced operations—Format JSON, Compare, Duplicate, Revert, AI Proposal, and Experimental Repair—are in **More draft actions**.

For an AI Proposal, select a trusted Stable Worker Profile and explicitly consent to sending the Draft and bounded diagnostics through its provider CLI. Review the diff before applying it. Experimental Repair is a local heuristic; after a failed test, **Repair Profile** offers the existing review workflow. Neither path produces qualification evidence.

Choose **Run Full Test**. The Test pane first shows Provider CLI, Version, and Authentication; stages appear during execution. Review final counts, skipped capability-inapplicable stages, provider/version, duration, qualification, and expandable local evidence/logs. Failed stages offer contextual actions. Every substantive payload edit requires a fresh run matching the saved version and digest.

Choose **Sync to Cloud** once local edits are saved. Confirm **Synced to Cloud**. Sync creates or updates the mutable Cloud Draft with optimistic concurrency. Compare and resolve a Cloud conflict explicitly; never treat an unsynced local Draft as published.

## Publish and promote

Development follows the same complete lifecycle as customer environments. Desktop signing does not restrict publication; use a separate development Profile signer and build Workspace with its matching public roots.

1. Choose **Publish to Testing** for the saved, qualified, synced Draft. Profile Lab submits the exact local qualification; Cloud stores it and requires its immutable ID to sign the matching payload. Publication produces a Testing release.
2. Open **Releases**. Testing, Beta, and Stable cards show Cloud’s channel assignments; published history appears below. Inspect status, publication time, provider compatibility, release-scoped Cloud evidence, and differences from the previous published version. Signing metadata and canonical JSON remain in **Technical details**.
3. Validate the signed release in Testing Workspaces and retain live runtime acceptance evidence. Use **Promote to Beta** for the selected Testing release.
4. For **Promote to Stable**, submit qualifying post-publication acceptance evidence in the promotion dialog and reference its immutable Cloud evidence ID. Cloud rechecks qualification and passkey authorization. Local sandbox evidence alone cannot authorize Stable promotion.

## Assign Workspaces

Open **Workspaces**. Review Testing/Beta/Stable counts and the Workspace, Host, App version, Connection, and Channel table. Connection is Cloud’s latest reported status.

Select a new Channel, review the old/new assignment and runtime effect, then choose **Change channel**. Cancel preserves the assignment. Stable may require passkey verification. The assignment changes subsequent Profile resolution; running sessions retain their pinned release. Channel assignment does not update Workspace binaries or publish a Profile.

## Rollback or revoke

Open the selected Worker’s **Releases** and use **Release actions**:

- **Rollback channel…** requires a target channel, eligible prior release, and reason. It shifts the Cloud pointer without editing release payloads. Verify the channel card after refresh and validate subsequent Workspace assignments; do not assume a running session has switched versions.
- **Revoke release…** requires a reason, the exact `REVOKE-vN` confirmation, and recent passkey authorization. Revocation is irreversible. Verify Cloud lifecycle and runtime rejection using the [release trust contract](../security/RELEASE_TRUST_AND_ROTATION.md).

## Review Activity

**Activity** defaults to all events; optionally filter to the current Worker. Read the human-readable event summary and expand raw details for operational evidence. Actor and Worker names are current display labels, while immutable IDs remain in the record. `⌘R` refreshes the active resource, including release/channel assignments or Activity’s selected filter.

Retain the required evidence from the [Profile lifecycle specification](../specifications/TOOL_PROFILE_LIFECYCLE.md) and [Profile update operator contract](../specifications/PROFILE_LAB.md). Fixture acceptance tests establish the UI/Engine workflow but do not certify live provider behavior, Cloud signing infrastructure, or production rollout.

Operational messages have a copy icon. Use **Copy all messages** in the title bar to share current resource errors and active Draft test logs, or **Copy execution details** for the full test log. Secret values are redacted from copied text.

For a published Beta release, assign the test Workspace to Beta in **Workspaces**, then refresh **Workers** in Workspace. Profile download requires the public `/api/release-trust` endpoint to return valid revocation data and the Workspace build to trust the release signing key. Workspace Worker diagnostics show download failures when no verified cached Profile is available. A verified cached Profile remains usable during a temporary Cloud failure. Start a new AX Work session to use the newly resolved release; existing sessions keep their pinned Profile.

The downloaded release's provider name comes from its signed Profile payload. Catalog executable labels such as `codex` may differ from Profile display names such as `Codex CLI`; the catalog label must not overwrite signed release metadata. Workspace continues to reject any disagreement between the release envelope and payload.

Workspace readiness must use the same Worker catalog coordinator as Profile downloads. A downloaded Profile without provider version information does not establish that the CLI is missing; inspect the readiness issue first. Refresh runs a passive Engine probe, while **Test** also exercises live provider execution.

Readiness checks resolve the currently downloaded Profiles without waiting for an in-progress catalog refresh. Catalog refresh downloads each Worker's Profile and then reruns readiness. A Worker with no release in the selected channel must not block another Worker's readiness or leave the refresh stuck on “Checking…”.

Unsigned desktop builds reuse the saved hosted development public trust in `.development/hosted-profile-trust.json` when no explicit trust configuration is provided. Build scripts reject missing, empty, or invalid trust instead of producing an app unable to verify Profiles. Explicit public trust overrides this default; Developer ID signed builds always require explicit trust and never automatically adopt development keys. Profile signatures remain required regardless of desktop application signing.
