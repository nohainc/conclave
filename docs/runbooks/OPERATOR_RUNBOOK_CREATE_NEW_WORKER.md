# Operator Runbook: Creating a Worker and Initial Profile

**Surface:** Conclave Profile Lab (`apps/profile_lab`)  
**Scope:** Register a logical Worker, create its first local Draft, test through the generic CLI Worker Engine, and sync the Cloud Draft.

## Prerequisites

Sign in with an account authorized for `profiles:admin`. Install the intended provider CLI on the test machine and authenticate locally using the vendor’s supported flow. Profile Lab does not collect provider credentials. Publication additionally requires `profiles:release:manage` and a ready Cloud signer. Stable rollout, rollback, and revocation require recent passkey verification.

## Register or select a Worker

Open **Workers** and select the Worker. ChatGPT and Gemini already have catalog identities; do not register them again.

For a new approved Worker, use the catalog’s **Create Worker + Definition** control. The **Create Worker** dialog registers the Worker and its Profile definition together. Enter its Worker ID, Profile definition ID, display name, description, provider executable identity, catalog stage, capabilities, and sort order. Use documented CLI behavior to author the Profile; catalog stage describes catalog maturity and never establishes a Stable Profile release.

## Create the initial Draft

Open the selected Worker’s **Draft & Test** view. With no local Draft or release, Profile Lab shows that the Worker does not have an implementation Profile yet.

- Choose **Create Initial Draft** when Cloud supplies a starter template. The payload is cloned into the local Draft store with the Worker’s configured identity. ChatGPT uses `chatgpt-codex`/`codex`; Gemini uses `gemini-antigravity`/`agy`.
- Choose **Create blank Profile** when no template exists. Profile Lab fills the known Worker, definition, and provider identities. Author the version range, probes, execution/event mapping, and applicable capabilities before testing. A blank Draft is not qualified or production ready.

There is no second Draft selector or identity-entry dialog. Cloud-managed starter templates are authoring aids; Workspace never reads them.

## Test, save, and sync

1. Review the schema-aware JSON editor and optional Inspector. Use **Save** (or `⌘S`) for local edits. Initial Draft creation already persists the first payload locally.
2. Review Provider CLI, Version, and Authentication in the Test pane. Discovery is dynamic from the selected Worker/Profile. Version and authentication remain unchecked until observed by the test run.
3. Choose **Run Full Test**. Review the progressive ladder and final passed/skipped counts, provider/version, duration, and qualification. Only capability-inapplicable scenarios may be skipped. Expand **Execution details** for logs and **Local acceptance evidence** for the recorded result.
4. For a failure, use the offered Retry, version-range, or Repair Profile action. Save any changed payload and rerun. Proposals and repairs are Draft edits, never evidence.
5. Choose **Sync to Cloud** after saving. Confirm the header reports **Synced to Cloud** for the exact version and digest. Sync creates a mutable Cloud Draft; it does not publish a signed release. Resolve conflicts explicitly using compare/reload controls.

## Publish and test in Workspace

After saving, qualifying, and syncing the exact Draft, choose **Publish to Testing** in Draft & Test. Cloud stores the local qualification, validates its ID against the Draft digest, and signs an immutable Testing release. Review **Releases**, assign a development Workspace to Testing through **Workspaces**, and run a real task. Promote to Beta and Stable after the required evidence gates pass.

Development and customer environments use the same lifecycle. Desktop app signing does not control these actions. Missing release permission or signer configuration is explained beside the publish action; development uses separate Profile signing keys and public trust roots. The retired `CONCLAVE_PROFILE_RELEASE_MODE` setting is no longer used.

For publication, Beta/Stable promotion, Workspace assignment, rollback, and revocation, follow [Updating an Existing Profile](OPERATOR_RUNBOOK_UPDATE_PROFILE.md).

## Activity and verification

Use **Activity** for all events, or filter to the current Worker. Expand an event for raw IDs, reasons, provenance, and details. Use `⌘R` to refresh the active resource. Before live rollout, retain real-provider and Workspace acceptance evidence as required by the [Profile lifecycle contract](../specifications/TOOL_PROFILE_LIFECYCLE.md); deterministic test fixtures do not replace it.
