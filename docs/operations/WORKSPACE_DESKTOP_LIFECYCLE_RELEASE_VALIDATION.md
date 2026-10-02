# Workspace Desktop Lifecycle Release Validation

**Status:** Release gate; production-device scenarios not yet recorded  
**Applies to:** Conclave Workspace macOS release and the deployed Cloud API  
**Design authority:** [ADR-013](../decisions/ADR-013-desktop-auth-and-dual-transport.md), [ADR-014](../decisions/ADR-014-workspace-desktop-lifecycle.md)

## Purpose

Use this runbook to verify that the packaged desktop, Cloud ownership rules,
runtime transport, and management UX implement one lifecycle. The automated
Cloud WebSocket and forced-fallback acceptance tests are necessary, but do not
replace native install, login-item, lock, or account-transition validation.

Do not mark a scenario passed from source inspection or a unit test. Run against
the candidate signed/notarized macOS package and the intended production
Cloud deployment. Record the app version/build, macOS version, Cloud deployment
identifier, date, operator, scenario result, and safe evidence. Never record
bearer credentials, provider secrets, cookies, authorization headers, or raw
long-poll cursors. Redact user email and machine names from artifacts shared
outside the release team.

## Preconditions and evidence

- Have two controlled Conclave accounts, User A and User B, and a dedicated
  test Mac. Confirm User B has not previously owned the test installation.
- Deploy the candidate Cloud API and verify its WebSocket smoke and forced
  HTTPS-fallback CI gates are green.
- Install the candidate macOS package with its production signing and update
  metadata. Keep the same stable installation ID and local data directory
  throughout the release-upgrade and ownership scenarios.
- Prepare a harmless test assignment with a deterministic result. Confirm no
  unrelated production assignment will be affected by Disconnect or Release.
- For each scenario record pass/fail, timestamps, app/Cloud versions, relevant
  Workspace and assignment IDs, redacted diagnostics, and Cloud audit/correlation
  IDs where available. Store logs in the approved release evidence location.
- Stop and investigate on an ownership mismatch, unexpected credential
  replacement, duplicate assignment, lost Work Root data, or secret in logs.

## Required production scenarios

| # | Scenario and procedure | Pass criteria | Evidence |
| --- | --- | --- | --- |
| 1 | **Fresh installation.** Install on a clean test account, launch, sign in as User A, and inspect before selecting Connect. Then connect using the proposed computer name. | Sign-in alone creates no Workspace runtime. Connect registers one installation, Cloud owner matches User A, runtime reaches Ready, and Workers management appears only after connection. | Redacted before/after UI, one registration/audit record, runtime status and safe diagnostics. |
| 2 | **Current release upgrade and registry reset.** Upgrade a connected installation with configured provider CLIs and existing Work Root content. Verify the local Worker registry is rebuilt from the current logical Worker catalog, then reconfigure and check readiness. | Installation ID, Workspace/runtime identity, and Work Root survive. Logical Worker state is rebuilt from current Cloud catalog/Profile data. Provider CLI credentials remain in the provider's local configuration. The Work Root is never removed. | Before/after IDs and inventory; Work Root content manifest; catalog/Profile resolution and readiness; migration logs without secret values. |
| 3 | **Reboot/login auto-start.** Enable Start at login, connect, quit or reboot, then log in to macOS without opening Workspace from the Dock. | `SMAppService.mainApp` starts the app/runtime in background; runtime reconnects using its runtime credential and desired state, and reaches Ready without interactive human sign-in. Main window remains closed until opened. | Login-item setting, Cloud last-seen/runtime status timestamps, menu-bar state, and app logs. |
| 4 | **Human-session expiry.** With runtime connected and a test assignment running, expire/revoke the desktop human session through the approved test procedure. | Runtime and assignment continue. Management UI requires same-owner sign-in, and User A reauthentication restores management without recreating registration or interrupting work. | Assignment timeline, before/after runtime and Workspace IDs, reauth shell, redacted auth/runtime diagnostics. |
| 5 | **WebSocket to HTTPS fallback.** Make WSS unavailable for the test client/environment while HTTPS remains reachable; observe connection and execute a test assignment. | Desktop reports `Connected · HTTPS fallback` and says work can continue. Inventory sync, scheduler dispatch, execution, progress, result, and cancellation remain available. Diagnostics retain WSS failure details and healthy fallback state. | Redacted diagnostics, runtime status, inventory revision, assignment/result IDs and Cloud logs. |
| 6 | **Manual lock/unlock.** Lock a connected Workspace while workers are configured and work is active; then unlock with macOS local authentication. | Lock hides Worker/configuration/diagnostic management data without stopping transport, active assignment, or Worker processes. Successful native auth restores UI; cancel/failure remains locked. | Screen recording or screenshots with sensitive details redacted; assignment/transport continuity; unlock outcome. |
| 7 | **Disconnect/reconnect same owner.** Drain/finish active work, Disconnect as User A, then Connect again as User A. | Disconnect revokes runtime participation and records disconnected intent but preserves installation identity, owner binding, human session, Workers/provider credentials, and Work Root. Same-owner Connect recovers the same Workspace and starts a fresh runtime credential. | Before/after identity and inventory, disconnect/reconnect audit records, runtime readiness. |
| 8 | **Attempted account switch.** While the installation is owned by User A, sign out only through the allowed disconnected path or trigger same-owner reauth, then attempt browser authentication as User B without Release. | Cloud returns stable ownership conflict. User B cannot inspect/manage/recover/release/connect the installation. Stored owner/session and runtime identity are not overwritten; connected runtime is not mutated. | Ownership-conflict UI/API status, audit record, before/after owner/runtime IDs and safe diagnostics. |
| 9 | **Release and new owner.** As User A, disconnect and drain work, perform fresh local authentication, then explicitly Release. Sign in as User B and Connect. | Release is blocked while active work exists; after disconnect it records an audited ownership transition and clears Cloud binding. User B can then register the same stable installation ID. Release itself leaves local files and Worker/provider credentials untouched; any later destructive local reset requires its own explicit action. | Active-work denial then successful audit record; owner transition; local data/secret preservation check. |
| 10 | **Worker before/after background restart.** Execute the deterministic assignment, enable login startup, restart/login, then dispatch and execute a second assignment without opening the management window. | Both results return exactly once. Worker/provider configuration remains usable; background restart creates no duplicate or lost assignment and runtime returns to Ready. | Two assignment/result IDs and event timeline, runtime status, inventory, and redacted app/Cloud diagnostics. |

## Completion record

All ten rows must have a named operator, timestamp, build/deployment IDs,
result, and evidence location. Any failed or unrun row blocks the desktop
release. Attach the completed table or a release-system record that contains
the same fields. Automated CI links should be recorded alongside, not in place
of, the production-device evidence.

## Troubleshooting and recovery

- **Runtime offline after human expiry:** inspect runtime transport and
  credential validity separately from human-session status. Reauthenticate as
  the bound owner; do not force a new registration to clear the symptom.
- **HTTPS fallback not Ready:** capture the redacted WSS failure and fallback
  health, confirm HTTPS reachability and deployed Gateway support, then use the
  Cloud request/correlation ID to inspect Gateway logs. Never copy a credential
  or cursor into a ticket.
- **User B receives ownership conflict:** this is expected while User A's
  binding remains. Verify the owner using the authenticated ownership check;
  disconnect alone does not release ownership. The installation ID must match
  the current runtime binding; local Workspace/runtime IDs do not restore a
  missing Cloud binding.
- **Duplicate or missing assignment during handover:** stop further acceptance
  runs, preserve event IDs and Cloud correlations, and verify the Gateway
  logical outbound queue and hello/sync/inventory reconciliation before retry.
- **Login item or local authentication fails:** record macOS version, package
  signature, `SMAppService` state, and native error. Do not mark the native gate
  passed based on Flutter widget tests.
