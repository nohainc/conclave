# Conclave Workspace Desktop Lifecycle Implementation

**Status:** Proposed implementation plan  
**Baseline:** `main@d268546ce9ced72eeaa9c10233d934182e05d353`  
**Architecture decisions:** [ADR-013](../decisions/ADR-013-desktop-auth-and-dual-transport.md), [ADR-014](../decisions/ADR-014-workspace-desktop-lifecycle.md)

## Goal

Refine the first ADR-013 implementation so Conclave Workspace has a clear and
secure lifecycle:

~~~text
SIGNED OUT
  -> Sign in

SIGNED IN / DISCONNECTED
  -> Connect Workspace

CONNECTED / UNLOCKED
  -> Workspace + Workers

CONNECTED / LOCKED
  -> runtime continues; management UI protected

CONNECTED / REAUTH REQUIRED
  -> runtime continues; same-owner sign-in required for management
~~~

Runtime transport remains independent:

~~~text
WebSocket preferred
HTTPS long-poll fallback
~~~

The core rule is:

> Human authentication, Workspace runtime participation, local UI locking, and
> transport health are separate state dimensions.

---

# Phase 0 — Freeze lifecycle semantics

## Goal

Define explicit lifecycle state before changing UI or native integrations.

Introduce shared concepts such as:

~~~text
HumanAuthState
  signedOut
  signedIn
  reauthRequired

WorkspaceParticipationState
  disconnected
  connecting
  connected
  disconnecting

ManagementLockState
  unlocked
  locked

DesiredRuntimeState
  connected
  disconnected
~~~

Transport state remains the existing runtime projection:

~~~text
websocket
http_long_poll
reconnecting
offline
authentication_required
~~~

Do not derive one state from another unless the contract explicitly allows it.

## Required invariants

- signed-in does not imply connected;
- connected does not imply a currently valid human management session;
- locked does not imply disconnected;
- transport fallback does not imply management reauthentication;
- a different User cannot replace the owner of a connected installation;
- disconnect does not automatically release account ownership;
- sign-out does not silently leave a user-initiated account switch while
  connected.

## Shared state ownership

Persist locally, without secrets:

~~~text
desiredRuntimeState
launchAtLogin
managementLockPreference
optionalAutoLockTimeout
ownerUserId/display metadata as non-authoritative cache
~~~

Keep secrets in secure storage:

~~~text
DesktopHumanSessionCredential
WorkspaceRuntimeCredential
Worker/provider credentials
~~~

## Exit

Tests can construct every lifecycle state without relying on UI widget state.

---

# Phase 1 — Separate Sign In from Connect Workspace

## Goal

Remove the current behavior where successful desktop sign-in immediately
registers/recovers the Workspace and starts the runtime.

## Current behavior to change

The current desktop flow is approximately:

~~~text
_signInDesktopHuman()
-> create/approve desktop auth intent
-> store human session
-> registerWithDesktopSession()
-> issue runtime credential
-> rebuild runtime
~~~

Split it.

## New sign-in behavior

Successful sign-in:

1. creates/claims desktop auth intent;
2. validates the desktop human session;
3. stores it securely;
4. loads account identity;
5. transitions to `SIGNED IN / DISCONNECTED` when no active runtime exists;
6. does **not** call Workspace registration/recovery automatically.

## Connect Workspace behavior

Add explicit:

~~~text
[ Connect Workspace ]
~~~

Connect performs:

1. require valid human session;
2. resolve persistent installation ID;
3. collect safe machine facts;
4. show/confirm editable friendly Workspace name when needed;
5. call authenticated register/recover endpoint;
6. verify returned Workspace owner equals signed-in user;
7. store runtime credential securely;
8. persist `desiredRuntimeState = connected`;
9. start/rebuild runtime;
10. wait for WebSocket or HTTP fallback to become Ready;
11. expose Workspace/Workers UI.

## UX

Signed-in/disconnected surface:

~~~text
Conclave Workspace

Signed in as
Vitalii Noha
vitalii@example.com

This computer is not connected as a Workspace.

Computer
Vitalii's MacBook Pro

[ Connect Workspace ]
~~~

## Exit

Unit/UI tests prove clicking Sign in alone never creates/reconnects a runtime.

---

# Phase 2 — Create a true signed-out shell

## Goal

Hide all management surfaces until human authentication succeeds.

Do not render the existing HostDashboard as the primary signed-out UI.

Introduce a root shell/state router conceptually:

~~~text
SignedOutShell
SignedInDisconnectedShell
WorkspaceManagementShell
LockedShell
ReauthRequiredShell
~~~

## SignedOutShell

Allow only:

- Sign in;
- app version;
- About;
- safe logs/diagnostic entry if desired;
- Quit.

Do not expose:

- Workspace tab;
- Workers tab;
- Worker identities;
- Work Root;
- local credentials;
- adapter state;
- disconnect/reset;
- runtime recovery;
- permission settings.

## Startup behavior

At app-window open:

- if a valid human session is available and management is allowed, route to
  signed-in/management state;
- if runtime is connected but human session requires reauthentication, show
  ReauthRequiredShell;
- background runtime can start before the management shell is unlocked.

## Exit

Signed-out UI contains no Worker or Workspace management controls.

---

# Phase 3 — Define Connect, Disconnect, Release, Sign Out, and Reset precisely

## Goal

Eliminate ambiguous/destructive lifecycle actions.

## Connect Workspace

Requires:

~~~text
human session valid
installation ownership compatible
no active runtime
~~~

Effects:

- register/recover existing Workspace;
- issue/rotate runtime credential;
- set desired runtime state to connected;
- start runtime;
- enable launch-at-login by default or present explicit opt-in;
- preserve one installation identity.

## Disconnect Workspace

Requires local confirmation and local reauthentication.

Effects:

- stop accepting new work;
- drain active assignments;
- close logical runtime transport;
- revoke active runtime credential;
- set desired runtime state to disconnected;
- keep installation identity;
- keep owner binding;
- keep human desktop session;
- keep Workers/provider credentials/adapters/Work Root.

Returns to:

~~~text
SIGNED IN / DISCONNECTED
~~~

## Release / Remove Workspace from account

Advanced and separate from Disconnect.

Effects:

- require no active assignments;
- require fresh local authentication;
- revoke runtime credential/session;
- release Cloud ownership/binding according to server policy;
- leave local data untouched only with explicit confirmation;
- make installation eligible for another Conclave account.

Use clear warning about local Worker/provider credentials.

## Sign Out

### When disconnected

Revoke/remove desktop human session.

### When connected

Do not perform directly.

Prompt:

~~~text
This Workspace is connected.

[ Cancel ]
[ Disconnect and sign out ]
~~~

Do not silently keep a deliberately signed-out UI while changing owner/account.

## Reset local Workspace

Advanced destructive operation.

Must be distinct from Disconnect and Release.

Define exactly which of the following it removes:

- local Workspace registration;
- runtime credential;
- desktop human session;
- configured Workers;
- provider credentials;
- adapter state;
- local non-work state;
- Work Root metadata/content.

Prefer selectable/published semantics rather than one opaque "reset everything".

## Exit

Every lifecycle action has deterministic Cloud/local effects and tests.

---

# Phase 4 — Account ownership and account-switch protection

## Goal

Prevent another account from managing a connected/owned installation.

## Cloud

For all management/recovery APIs verify:

~~~text
desktop human user ID
==
Workspace/installation owner user ID
~~~

Return a stable ownership-conflict error when not equal.

Do not mutate runtime or local ownership on failed account authentication.

## Desktop

When connected/owned:

- do not offer "Switch account";
- if human session expires, reauthentication must return the same owner;
- if browser approval belongs to a different User, show:

~~~text
This Workspace belongs to another Conclave account.

Disconnect and release it from the current account before switching users.
~~~

Do not overwrite the stored owner/session.

## Migration

For already-connected installations from the first ADR-013 implementation:

- infer/verify the owner using Cloud registration data;
- cache owner identity locally only as convenience;
- Cloud remains authoritative.

## Exit

Tests prove User B cannot manage, recover, release, or connect User A's
installation without explicit prior release.

---

# Phase 5 — Human-session restore, expiry, and reauthentication

## Goal

Make management authentication durable without coupling it to runtime uptime.

## Startup

Load desktop human session from secure storage.

Validate/refresh it asynchronously.

Do not block runtime startup while validating a human management session.

## Session valid

Allow management UI.

## Session expired/revoked

If runtime is disconnected:

~~~text
Sign in required
~~~

If runtime is connected:

~~~text
Workspace is still running.

Sign in as the Workspace owner to manage it.

[ Sign in ]
~~~

Runtime continues.

## Reauthentication

Require same owner.

After success:

- replace/rotate desktop human session;
- unlock management shell if local lock also passes;
- do not re-register/restart runtime unnecessarily.

## Sign-out semantics

Explicit sign-out and passive expiry remain different.

Passive expiry never means runtime disconnect.

## Exit

A connected runtime survives human-session expiry and recovers management access
without assignment interruption.

---

# Phase 6 — Implement local Workspace lock

## Goal

Protect local management controls while leaving the runtime operational.

## Native authentication abstraction

Create a platform abstraction such as:

~~~text
LocalManagementAuthenticator
  isAvailable()
  authenticate(reason)
~~~

macOS implementation uses LocalAuthentication:

- Touch ID where available;
- device/user password fallback according to platform policy.

Do not create a Conclave-specific PIN.

Windows/Linux implementations can follow later with platform-appropriate
mechanisms.

## Lock behavior

Lock:

- hides Workspace and Workers tabs;
- hides local paths, Worker/provider names, configuration and diagnostics that
  may be sensitive;
- keeps runtime transports active;
- keeps Workers executing;
- keeps active assignments running;
- keeps menu-bar safe status.

Locked shell:

~~~text
Conclave Workspace

Workspace is locked.
Runtime is still connected.

[ Unlock ]
~~~

## Auto-lock

Initial recommended behavior:

- manual Lock available;
- lock when OS screen/session is locked;
- optional idle timeout;
- do not automatically stop runtime;
- closing the main window does not mean disconnect;
- reopening after a protected/locked state requires local auth.

## Unlock

Native local-auth success -> restore management UI.

Failure/cancel -> remain locked.

## Exit

Tests prove locking does not alter runtime/Gateway/assignment state.

---

# Phase 7 — Protect sensitive actions with step-up local authentication

## Goal

Avoid relying only on whether the window is currently unlocked.

Require recent native local authentication for:

- Disconnect Workspace;
- Release/remove ownership;
- Reset local Workspace;
- remove Worker;
- replace Worker/provider credentials;
- change Worker local execution permissions;
- destructive Work Root migration/change;
- account ownership transition.

Use a short "recently authenticated" window if needed to avoid repeated prompts
during one deliberate management task.

Do not prompt for ordinary reads or benign navigation.

## Exit

High-impact local actions cannot be triggered by someone who merely encounters
an unlocked window after the owner leaves.

---

# Phase 8 — Launch at login and background auto-connect

## Goal

Make Conclave Workspace operate like a reliable machine runtime.

## macOS

Use supported Service Management API (`SMAppService`) for main-app login-item
registration.

Add setting:

~~~text
Start Conclave Workspace when I log in   [on/off]
~~~

Recommended default:

- enable when user first connects the Workspace, with clear UI;
- allow opt-out.

Do not register startup merely because the app was installed.

## Background startup

At OS-user login:

1. launch application without opening main window;
2. initialize local state/secure stores;
3. inspect `desiredRuntimeState`;
4. if connected:
   - load registration/runtime credential;
   - start Workspace runtime;
   - try WebSocket;
   - fallback to HTTPS long-poll;
   - publish menu-bar status;
5. if deliberately disconnected:
   - do not create runtime connection;
6. do not require interactive human sign-in for runtime reconnection.

## Window behavior

Background launch should normally leave the main window closed.

Opening from Dock/menu bar presents:

- LockedShell if lock policy says locked;
- ReauthRequiredShell if management session expired;
- normal management UI otherwise.

## Exit

A connected Workspace becomes available after a normal restart/login without
manual app launch or human sign-in.

---

# Phase 9 — Persist desired runtime and startup state safely

## Goal

Avoid accidental auto-connect after the user deliberately disconnects.

Persist non-secret local lifecycle state, e.g.:

~~~text
desiredRuntimeState
launchAtLogin
lockEnabled
autoLockTimeout
lastOwnerUserId (cache only)
~~~

Requirements:

- atomic writes;
- schema/versioning;
- safe defaults;
- reset semantics;
- no bearer/provider credentials;
- migration from existing installs.

### Migration rule

Existing installation with a valid registration + runtime credential should
normally migrate to:

~~~text
desiredRuntimeState = connected
~~~

unless an explicit previous disconnected marker exists.

Do not make users manually reconnect after upgrade.

## Exit

Restart behavior is deterministic and testable.

---

# Phase 10 — Gate Workers UI by lifecycle state

## Goal

Make onboarding linear and remove controls from unauthorized/disconnected
states.

### Signed out

No tabs.

### Signed in / disconnected

Workspace setup only.

No Workers tab.

Copy:

~~~text
Connect this computer before configuring Workers.
~~~

### Connected / unlocked

Show:

~~~text
[ Workspace ] [ Workers ]
~~~

### Connected / locked

No tabs.

### Reauth required

No Worker management until same-owner management auth succeeds.

Runtime inventory/execution may continue in background.

## Worker security

Do not destroy or disable local Workers merely because management UI is hidden.

## Exit

UI visibility exactly follows the lifecycle contract.

---

# Phase 11 — Refine Workspace tab around the lifecycle

## Connected Workspace surface

Suggested hierarchy:

~~~text
Workspace

Account
Vitalii Noha
vitali...@...
[ Lock ]

Connection
Connected · WebSocket
or
Connected · HTTPS fallback

Startup
Start at login          On

Current work
0 assignments

Workers
3 configured · 3 ready
[ View Workers ]

Work Root
~/Library/Application Support/Conclave/Workspace/Work

Application
Version ...
Update ...

Advanced & Diagnostics >
~~~

## Signed-in/disconnected surface

~~~text
Workspace

Account
Vitalii Noha

Computer
Vitalii's MacBook Pro

Not connected as a Workspace.

[ Connect Workspace ]
~~~

## Actions placement

Keep Disconnect in a clearly separated management/destructive section, not next
to routine status.

Put Release/Reset under Advanced with warnings.

## Exit

Users can distinguish account state, runtime participation, transport health,
and local lock state without reading diagnostics.

---

# Phase 12 — Menu-bar lifecycle

## Goal

Make the background runtime understandable without opening the full app.

When connected:

~~~text
Conclave Workspace
Connected · WebSocket
0 assignments

Open Conclave Workspace
Lock Workspace
Pause new work
Diagnostics
----------------
Quit
~~~

Fallback:

~~~text
Connected · HTTPS fallback
~~~

Reauth required:

~~~text
Workspace running
Sign in required to manage
~~~

Disconnected:

~~~text
Workspace disconnected
Open Conclave Workspace
~~~

Do not expose destructive Reset/Release in the menu bar.

## Lock interaction

Lock action immediately protects the full UI.

Opening a locked app triggers the locked shell, not a transient flash of
management data.

## Exit

Menu-bar status agrees with the full application's lifecycle/transport state.

---

# Phase 13 — Runtime and quit semantics

## Goal

Define background process behavior independently from account UI.

### Close window

Keeps runtime running.

### Quit app

If no active assignments:
- close runtime cleanly;
- terminate app.

If active assignments:
offer a clear policy such as:

~~~text
[ Cancel ]
[ Drain and quit ]
~~~

Do not claim "safe reconciliation" without explicit behavior.

### Pause new work

Optional runtime operation distinct from Disconnect:

- runtime stays connected;
- no new assignments;
- current work continues.

Do not use Disconnect as Pause.

## Exit

Close, lock, pause, disconnect, sign out, and quit each have distinct behavior.

---

# Phase 14 — Cloud API adjustments

## Goal

Support the lifecycle without misusing registration or runtime APIs.

Audit/add explicit management endpoints for:

- inspect installation/Workspace ownership;
- connect/register/recover;
- disconnect runtime;
- release Workspace ownership;
- desktop human session validation/rotation/revoke.

Do not overload one endpoint with all lifecycle semantics.

### Disconnect endpoint

Must:

- verify owning human session;
- stop/revoke runtime participation;
- invalidate active runtime credential/session;
- keep installation owner binding;
- preserve Workspace identity/history according to product policy.

### Release endpoint

Must:

- verify owner;
- require disconnected runtime;
- remove/release installation owner binding;
- audit transition;
- never expose/delete local provider secrets because Cloud never has them.

### Runtime auto-reconnect

No human API call should be required when a still-valid runtime credential
reconnects after reboot.

## Exit

Cloud behavior maps one-to-one to lifecycle actions.

---

# Phase 15 — Security and failure acceptance

Test at minimum:

## UI authorization

- signed-out shell hides tabs;
- locked shell hides management content;
- reauth-required shell hides Worker controls.

## Authentication

- current browser/code flow still works;
- different-user reauth rejected on owned installation;
- human credential never accepted by runtime APIs;
- runtime credential never accepted by human management APIs.

## Connection lifecycle

- sign in does not connect;
- connect creates/recovers runtime;
- disconnect revokes runtime participation;
- same owner reconnects;
- release permits later ownership transition;
- account switch without release fails.

## Restart

- connected + launch-at-login -> auto-connect;
- disconnected -> remains disconnected;
- expired human session + valid runtime -> runtime starts, management requires
  reauth;
- WebSocket failure -> HTTP fallback works without management sign-in.

## Lock

- lock leaves assignments/runtime alive;
- unlock uses native local authentication;
- failed unlock exposes no Worker data;
- screen-lock event locks management UI where supported.

## Sensitive actions

- destructive actions require recent local authentication.

## Exit

Lifecycle security is enforced by backend/local state, not merely widget
visibility.

---

# Phase 16 — Migration and cleanup

## Goal

Move the first ADR-013 implementation to the refined lifecycle without breaking
existing users.

### Existing signed-in + connected installs

Preserve:

- installation identity;
- Workspace ID;
- runtime credential;
- Workers/provider credentials;
- Work Root.

Infer:

~~~text
desiredRuntimeState = connected
~~~

Do not require new pairing/connect.

### Existing signed-in but invalid runtime

Show Signed in / Disconnected or Reauth Required depending on ownership/session
state.

Do not automatically create a new Workspace.

### UI cleanup

Remove/deprecate logic where:

~~~text
sign-in callback directly calls registerWithDesktopSession()
~~~

Move registration exclusively behind Connect/recovery actions.

Remove management controls from signed-out shell.

### Legacy pairing

Continue the compatibility window already defined in ADR-013. Do not mix
pairing removal with this lifecycle migration unless release compatibility is
already satisfied.

## Exit

Upgrade does not disconnect valid existing Workspace runtimes and the code has
one explicit lifecycle state machine.

---

# Phase 17 — Documentation and release validation

Update after implementation:

- ADR-013 status/reference to ADR-014 refinement;
- application boundaries;
- desktop auth/transport contracts;
- Workspace UX contract;
- macOS deployment/startup docs;
- security docs;
- troubleshooting/runbooks.

Production validation should include:

1. fresh installation;
2. existing connected migration;
3. reboot/login auto-start;
4. human-session expiry;
5. WebSocket -> HTTPS fallback;
6. manual lock/unlock;
7. disconnect/reconnect same owner;
8. attempted account switch;
9. release + new owner flow;
10. Worker execution before/after background restart.

## Exit

Published docs and application behavior describe the same lifecycle.

---

# Recommended implementation PR sequence

Keep changes small enough to isolate lifecycle/security regressions:

1. **PR A — lifecycle state model + persisted desired runtime state**
2. **PR B — SignedOutShell + split Sign in from Connect**
3. **PR C — explicit Connect/Disconnect Cloud + desktop behavior**
4. **PR D — owner binding and account-switch protection**
5. **PR E — session expiry/reauth management flow**
6. **PR F — native Lock/Unlock + sensitive-action step-up auth**
7. **PR G — macOS Launch at Login + background auto-connect**
8. **PR H — lifecycle-gated Workers/Workspace UI**
9. **PR I — menu-bar/close/quit/pause lifecycle convergence**
10. **PR J — Release ownership + migration hardening**
11. **PR K — full acceptance/security tests**
12. **PR L — docs/cleanup after one production validation cycle**

## Critical implementation rules

- Do not make runtime startup wait for Better Auth if a valid runtime credential
  already exists.
- Do not let Sign in implicitly register/connect after this migration.
- Do not let Sign out silently transfer ownership.
- Do not stop runtime because management UI is locked.
- Do not use UI visibility as the only authorization control.
- Do not store runtime/human/provider credentials in lifecycle state files.
- Do not enable login-item auto-start for a deliberately disconnected
  Workspace.
- Do not allow a second Conclave user to claim an owned installation without
  explicit Release ownership.
