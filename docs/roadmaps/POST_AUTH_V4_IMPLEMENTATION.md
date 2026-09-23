# Post-Authentication Architecture v4 Conformance & Realtime Roadmap

**Status:** Implementation roadmap  
**Applies after:** AUTH-20  
**Architecture:** Architecture v4 — Host + Worker  
**Date:** 2026-09-23

This roadmap finishes the gap between the implemented v4 foundation and the intended product architecture after the long-term authentication migration.

## Product names to use from this point forward

### User-facing
- **Conclave AX** — the main web application users open and interact with.
- **Conclave Host** — the desktop application installed on a machine.
- **Worker** — an installable AI/tool integration.
- **Account** — the user-facing term for a Credential Profile.

### Internal/domain
- **Conclave Cloud** — backend/control plane.
- **CredentialProfile** — internal domain name for an Account.
- **WorkerAssignment**, **HostGateway**, **ResolvedExecutionTarget** — internal terms.

Do not use **Conclave AX Studio** as a product name after this roadmap.

## Connection topology

The target topology is:

```text
Conclave AX
Flutter Web
     |
     | HTTPS commands + authenticated realtime WebSocket
     v
Conclave Cloud
     |
     | authenticated Host WebSocket
     v
Conclave Host
     |
     | local structured Worker protocol
     v
Worker process
     |
     v
AI / CLI / API / tool
```

Workers do **not** connect directly to Conclave Cloud.

The Host remains the only machine-side Cloud security principal.

---

# PA-0 — Restore fully green post-authentication main

## Goal
Create a trustworthy baseline before realtime/naming refactors.

## Current known failures
At the AUTH-20 head:
- Prettier failures in several authentication/test files;
- Studio Flutter analyzer reports an unused settings view and a const lint;
- Host CI uses `dart pub get` although `apps/host` is now a Flutter application;
- macOS/Windows Host matrix jobs are cancelled after the first Host failure.

## Work
- run Prettier/write on all modified TS/JS files;
- resolve all Studio analyzer issues;
- change Host CI to use Flutter setup + `flutter pub get`, `flutter analyze`, and `flutter test`;
- run Host tests on Linux/macOS/Windows;
- preserve architecture/security/protocol checks;
- review the two moderate production dependency audit findings and either update or document why they are non-blocking.

## Tests
- `pnpm check`;
- Studio `flutter analyze && flutter test`;
- Host `flutter analyze && flutter test` on all target OSes;
- Wrangler startup checks;
- production preflight;
- v4 architecture guard.

## Exit criteria
All required CI jobs are green on main.

---

# PA-1 — Remove obsolete Cloudflare Access protection from the main application

## Goal
Remove the old application-authentication perimeter now that Better Auth is the production human authentication mechanism.

## Cloudflare dashboard cleanup

Delete the Cloudflare Access **application** that protects the normal public Conclave AX application hostname, for example `app.conclaveax.com`, once the Better Auth production login has been verified on that hostname.

Also remove:
- application-specific Allow/Block/Bypass policies used only by that application;
- reusable Access policies only if no other Access application uses them;
- obsolete Access service tokens used only by the previous human-auth path;
- obsolete IdP configuration only if it is no longer used by any other Access-protected service.

Do **not** delete Cloudflare Access globally if it is useful for:
- staging;
- internal admin tools;
- debug dashboards;
- private operational applications.

Cloudflare requires reusable policies to be detached from applications before deleting them.

## Repository verification
Confirm there are no active dependencies on:
- `CF_Authorization`;
- `Cf-Access-Jwt-Assertion`;
- `cf-access-authenticated-user-email`;
- `CONCLAVE_ACCESS_*`;
- Access-specific service-auth bypasses for human application traffic.

## Production acceptance
Test without Access in front:
1. open Conclave AX signed out;
2. Better Auth sign-in;
3. session refresh;
4. Workspace switch;
5. logout;
6. passkey/step-up flow where configured;
7. Host pairing;
8. protected API denial while signed out.

## Exit criteria
The main Conclave AX hostname works correctly without Cloudflare Access, while optional internal/staging Access applications remain independent.

---

# PA-2 — Freeze product naming and terminology

## Goal
Make the product understandable with a minimal vocabulary.

## Canonical names

### User-facing
- Conclave AX
- Conclave Host
- Worker
- Account
- Workspace
- Project
- Chat
- Run

### Internal only
- Conclave Cloud
- Credential Profile
- Assignment
- Attempt
- Host Gateway
- Worker protocol

## Remove/replace user-facing terminology
Replace:
- Conclave AX Studio -> Conclave AX;
- Studio -> app/application where a generic term is needed;
- Credential Profile -> Account in UI;
- Plugin -> Worker;
- Agent -> Host.

## Documentation
Update:
- README;
- architecture;
- applications;
- auth docs;
- deployment docs;
- screenshots/copy;
- onboarding text.

## Code naming
Do not blindly rename every class immediately. Rename code when it represents the public/application concept and the rename improves maintainability.

Examples:
- `StudioApp` -> `ConclaveApp`;
- `StudioDataSource` -> `AppDataSource` or feature-specific repositories;
- `StudioSession` -> `AppSession`;
- `studio_navigation` -> application/router naming.

Avoid churn for purely historical filenames that will be removed by later feature decomposition.

## Tests
- repository search for user-visible "Studio";
- widget/text tests;
- docs check.

## Exit criteria
A user sees only Conclave AX, Host, Worker and Account terminology.

---

# PA-3 — Align repository/application names

## Goal
Make the repository mirror the product architecture.

## Target layout

```text
apps/
  app/       # Conclave AX Flutter Web
  cloud/     # Conclave Cloud TypeScript/Cloudflare
  host/      # Conclave Host Flutter/Dart

workers/
  codex/
  claude_code/
  openai/
  anthropic/
  echo/
  forge/
```

## Migrations
- `apps/studio` -> `apps/app` (complete);
- `apps/worker` -> `apps/cloud` (complete);
- `packages/agent-protocol` -> `packages/host-protocol` (complete);
- rename agent-named install/package scripts to Host equivalents;
- rename architecture retirement checks from Agent terminology where they now guard Host architecture.

## Important
This phase is a rename/refactor only. Do not mix realtime behavior changes into it.

## Update
- CI working directories;
- Wrangler paths;
- package names;
- imports;
- docs;
- deployment scripts;
- source maps/coverage config;
- protocol generation scripts.

## Tests
Full CI and clean-room build.

## Exit criteria
Repository top-level names directly correspond to App / Cloud / Host / Workers.

---

# PA-4 — Define the realtime event contract

**Status: Complete.** The canonical schema, generated TypeScript/Dart bindings,
parsers, and cross-language contract tests are in place. Browser WebSocket
transport remains deferred to PA-5.

## Goal
Create one canonical event model before adding a browser WebSocket.

## Event classes

### Durable domain events
Persist because they matter to history/recovery:
- chat.message.created;
- run.started/paused/resumed/completed/failed;
- task.started/completed/failed;
- attempt.started/completed/failed;
- assignment.accepted/completed/failed/cancelled;
- artifact.created;
- finding.created/resolved;
- verification.completed;
- host.enrolled/revoked;
- account.sharing.changed.

### Ephemeral realtime events
Usually do not persist:
- assignment.progress;
- Worker status text;
- streaming output delta;
- current tool invocation status;
- typing/thinking indicator;
- heartbeat;
- transient Host load.

## Envelope

Define a schema-first event envelope:
- eventId;
- type;
- version;
- timestamp;
- workspaceId;
- optional projectId/chatId/runId/taskId/attemptId/assignmentId/hostId;
- sequence;
- payload.

## Rules
- events are facts, not commands;
- browser never trusts event payload as authorization;
- events contain no raw credentials;
- large artifact bodies never travel as event payloads;
- high-frequency token streams are bounded/coalesced.

## Generated bindings
Generate TS/Dart models from canonical protocol schemas.

## Tests
- TS/Dart roundtrip;
- unknown compatible event;
- malformed payload;
- ordering/sequence;
- secret-redaction fixtures.

## Exit criteria
Cloud, App and Host share one typed event vocabulary.

---

# PA-5 — Add authenticated Conclave AX <-> Cloud realtime gateway

**Status: Complete.** Conclave Cloud now routes authenticated browser WebSocket
connections through the `RealtimeGateway` Durable Object. Workspace, Project,
Chat, and Run subscriptions are checked against D1 membership and ownership;
the App reconnects with a durable sequence cursor and refreshes its read model
from events. HTTPS remains the mutation boundary.

## Goal
Provide immediate UI updates after Better Auth is stable.

## Architecture

Use a dedicated Cloud realtime gateway backed by Durable Objects.

Recommended scope:
- one realtime connection per browser tab;
- authenticated using the Better Auth session cookie;
- server authorizes Workspace subscriptions;
- connection may subscribe/unsubscribe to Workspace/Project/Chat/Run scopes.

## Command/event split

Keep mutations over HTTPS:
- send message;
- create Run;
- cancel Run;
- update Host configuration.

Use WebSocket primarily for events.

This keeps commands idempotent and easy to retry while realtime remains a delivery channel.

## Authentication
During WebSocket upgrade:
- resolve Better Auth session;
- reject signed-out/expired/suspended users;
- never accept a Workspace ID solely because the browser requested it;
- verify membership before subscription.

## Messages
Client:
- realtime.hello;
- subscribe;
- unsubscribe;
- ping.

Cloud:
- realtime.ready;
- event;
- subscription.confirmed;
- subscription.denied;
- reconnect.required.

## Reconnect
Use:
- exponential backoff + jitter;
- last durable event sequence/cursor;
- HTTP resync after reconnect when gaps are detected.

## Tests
- valid/expired session;
- user removed from Workspace while connected;
- Workspace switch;
- multiple browser tabs;
- reconnect;
- unauthorized subscription;
- session revocation.

## Exit criteria
Conclave AX receives authenticated realtime events without polling for normal active-session updates.

---

# PA-6 — Build a Cloud event publication pipeline

## Goal
Avoid every Cloud service knowing how to push WebSocket messages.

## Pattern

Domain/application code records an event through one event publisher port:

```text
Application Service
    -> EventPublisher
        -> durable persistence when required
        -> realtime fanout when appropriate
```

## Requirements
- persistence and realtime delivery are separate concerns;
- failure to push an ephemeral event must not roll back a durable domain transaction;
- durable event creation should be transactionally consistent where practical;
- realtime payloads derive from authorized domain data;
- publishers do not depend on Flutter/browser concepts.

## Fanout
Prefer Workspace/Run-scoped Durable Object fanout rather than one global broadcast object.

## Tests
- durable + realtime event;
- realtime-only event;
- disconnected client;
- multiple subscribers;
- duplicate publish idempotency;
- event gap recovery.

## Exit criteria
Cloud features emit events through one reusable pipeline.

## Status

Complete. Cloud chat-message and run-start application paths publish through
the shared `EventPublisher`; durable history uses per-Workspace cursors and
idempotency keys, while realtime fanout is best-effort and isolated from
domain writes. Tests cover durable and ephemeral publication, disconnected
subscribers, duplicate publication, multiple members, and sequence-gap
recovery.

---

# PA-7 — Stream Worker progress through Host immediately

## Goal
Make Worker -> Host -> Cloud -> App realtime without giving Workers Cloud credentials.

## Worker -> Host
Extend/standardize Worker protocol notifications:
- progress;
- status;
- output_delta;
- tool.started;
- tool.completed;
- usage;
- artifact;
- result;
- error.

## Host behavior
Host:
- validates Worker message;
- applies size/rate limits;
- redacts secrets;
- enriches correlation IDs from the trusted Assignment;
- forwards allowed events over the existing Host WebSocket.

A Worker cannot choose another Workspace/Run/Task identity.

## Backpressure
- bound output buffers;
- coalesce very frequent progress;
- rate-limit streaming deltas;
- drop nonessential ephemeral events before affecting execution;
- never drop terminal result/error.

## Tests
- malformed Worker event;
- forged assignment ID;
- secret in output;
- huge stream;
- cancellation while streaming;
- Worker crash.

## Exit criteria
Worker progress appears in Conclave AX in near real time through Host, with no Worker Cloud credentials.

## Status

Complete. Worker notifications are validated at the Host process boundary,
bounded and redacted before relay, correlated only with the trusted immutable
Assignment context, rate-limited for ephemeral traffic, and forwarded over the
existing Host WebSocket. Terminal result and error notifications are always
forwarded. Cloud converts Host progress into the existing realtime publication
pipeline; Workers receive no Cloud credentials.

---

# PA-8 — Harden Host <-> Cloud WebSocket lifecycle

## Goal
Make the existing Host Gateway production-grade.

## Review
- machine credential validation;
- Host/Workspace binding;
- duplicate Host connections;
- reconnect;
- heartbeat;
- hibernation behavior;
- assignment replay;
- cancellation;
- desired-state sync;
- protocol upgrades.

## Multi-Workspace
The current Host connection carries a Workspace context. Review whether v4 should:
- maintain one physical socket with authorized multiple Workspace bindings, or
- use logical Workspace subscriptions over one Host socket.

Prefer one physical Host connection per Host installation if protocol complexity remains reasonable.

The Host should not reconnect merely because work comes from another authorized Workspace.

## Session recovery
Cloud/Host exchange:
- active assignment IDs;
- terminal results pending upload;
- Worker installation state;
- account readiness metadata.

## Tests
- network flap;
- Cloud restart;
- Host sleep/wake;
- stale socket replaced;
- two Workspace assignments;
- credential revoke;
- protocol mismatch.

## Exit criteria
One Host connection reliably services all authorized work for that machine.

## Status

Complete. Host Gateway authentication remains machine-credential based, stale
sockets are fenced by session identity, heartbeat and close handling preserve
the current session during replacement, and one physical Host connection can
serve every active Workspace binding returned by Cloud. Reconnect sync now
reconciles assignments by Host identity, including terminal journal replay and
installation/credential metadata pathways.

---

# PA-9 — Finalize multi-Workspace Host sharing

## Goal
Make one Host truly shareable without tying it to the installer.

## Rules
- installer only authorizes initial enrollment;
- Host has machine identity;
- Host may bind to multiple Workspaces;
- Cloud decides which users may use/manage it;
- no user session is stored by Host.

## Permissions
At minimum:
- host.view;
- host.use;
- host.manage;
- host.bind_workspace;
- host.revoke;
- worker.manage_on_host.

## UI
Host details in Conclave AX show:
- machine name;
- bindings;
- users/roles allowed through Workspace membership;
- load;
- Workers;
- Accounts available to requester;
- last seen.

## Tests
- A enrolls Host;
- B in same Workspace uses it;
- B without manage permission cannot revoke/configure it;
- second Workspace binding;
- user removed from Workspace loses access immediately;
- Host itself remains enrolled.

## Exit criteria
Host ownership is machine/Workspace-based, never installer-session-based.

## Status

Complete. Enrollment is limited to the initial machine exchange. Subsequent
Host use, management, revocation, Worker management, and Workspace binding
are evaluated from current Workspace membership and explicit role permissions.
Host details expose active bindings, Workspace members, installed Workers,
requester-authorized Accounts, current load, and last-seen presence without
returning secrets. Removing a member immediately removes access while the
machine enrollment and binding remain intact.

---

# PA-10 — Finalize Worker desired-state management

## Goal
Make Worker installation fully automatic from Conclave AX.

## User experience
User should not manage packages manually.

Conclave AX:
- Worker catalog;
- select Host availability;
- enable/disable Worker;
- see install/update/health state.

Cloud records desired state.

Host reconciles actual state:
- download;
- verify;
- install;
- health check;
- activate;
- update;
- rollback;
- remove after retention.

## States
Use explicit state machine:
- absent;
- requested;
- downloading;
- verifying;
- installing;
- ready;
- updating;
- degraded;
- failed;
- removing.

## Concurrency
One Worker binary/version installed once per Host regardless of number of users/Accounts.

## Tests
- two users enable same Worker;
- install once;
- update while assignments active;
- rollback;
- desired state removed;
- Host offline then reconnect.

## Exit criteria
Normal operation requires no manual Worker package installation.

## Status

Complete. Conclave AX can enable or disable a catalog Worker for a selected
Host (or all active Hosts in the Workspace), while Cloud stores one
deduplicated desired Worker set per Host. Hosts reconcile that set through an
explicit requested/downloading/verifying/installing/ready/updating/degraded/
failed/removing/absent state machine, report progress and health over the
machine connection, retain side-by-side versions for rollback, and remove
stale versions after reconciliation. Multiple users therefore converge on
one Host installation rather than downloading duplicate Worker binaries.

---

# PA-11 — Finalize Account / Credential Profile UX

## Goal
Make external AI identity understandable and safe.

## UI naming
Use **Accounts**.

Examples:
- My Codex;
- My Claude;
- Team OpenAI.

Internal model remains `CredentialProfile`.

## Account screens
Show:
- Worker;
- owner;
- Host/storage location;
- readiness;
- sharing;
- last used;
- usage;
- reconnect/re-authenticate;
- revoke.

Never display saved secret values.

## Setup flows
Based on Worker manifest:
- API key entry;
- browser OAuth;
- CLI/local login;
- no-auth/local model.

If setup requires Host-local action, Conclave AX creates setup intent and Host surfaces the local action.

## Sharing
- Private default;
- Selected users;
- Workspace;
- enforce Worker/provider sharing policy.

## Tests
- personal Account;
- Workspace Account;
- selected-user share;
- revoke;
- Host-local secret unavailable on another Host;
- account owner/consumer usage.

## Exit criteria
Users understand that Worker software is shared but Accounts/credentials are isolated.

## Status

Complete. Accounts are exposed with Worker, owner, Host-local storage,
readiness, sharing policy, last-used time, aggregate usage, and safe
re-authentication/revocation actions. Cloud responses never include secret
values or secret references. Personal and Workspace-owned Accounts are
authorized separately from Worker sharing; selected-user and Workspace grants
are checked at the database boundary. Host-local setup is represented by
metadata-only setup intents so the Host can surface the required local action.

---

# PA-12 — Replace large App snapshot refresh with feature read models

## Goal
Avoid scaling Conclave AX around one giant `/studio/snapshot` style response.

## Direction
Create focused read APIs/repositories:
- current session;
- Workspace list;
- Project/Chat summaries;
- active Chat;
- Run details;
- Hosts;
- Workers;
- Accounts;
- Usage.

Realtime events update local stores incrementally.

## Pattern
Initial load:
- HTTPS read model.

Live changes:
- WebSocket event.

Gap/reconnect:
- reload only affected read model.

## Flutter structure
Move away from `Studio*` monolithic models toward feature modules:
- app/auth;
- projects;
- chat;
- runs;
- hosts;
- workers;
- accounts;
- usage;
- settings.

## Tests
- large Workspace;
- partial read failure;
- realtime event update;
- refresh;
- reconnect gap.

## Exit criteria
Normal live operation does not repeatedly reload the whole application snapshot.

---

# PA-13 — Conclave AX chat/run realtime UX

## Goal
Use realtime for visible quality, not just infrastructure.

## Main chat
Show concise execution progress:
- Research 2/2;
- Planning complete;
- Implementation running;
- Review waiting;
- Verification.

## Streaming
Display useful Worker output selectively.

Do not expose raw internal model chatter by default.

Provide Run details for:
- Worker;
- Account;
- Host;
- model;
- artifacts;
- findings;
- tests;
- detailed events/logs.

## Approvals/questions
If workflow needs user input:
- realtime prompt appears in Chat;
- response sent as HTTPS command;
- Run resumes through Cloud.

## UX rules
- optimistic UI only where safe;
- terminal state comes from Cloud;
- reconnect banner;
- offline stale-state indicator;
- accessible live regions, throttled to avoid screen-reader spam.

## Exit criteria
Users can understand active work without manually refreshing.

---

# PA-14 — Artifact and large-output transport

## Goal
Keep WebSockets focused on control/realtime metadata.

## Rules
Do not stream large artifacts through App/Host WebSockets.

For:
- diffs;
- screenshots;
- logs;
- build output archives;
- generated documents;
- large model results,

upload/store as artifacts (R2 where appropriate).

Realtime sends:
- artifact.created;
- metadata;
- preview;
- download/reference ID.

## Security
Artifact authorization always rechecked by Cloud on retrieval.

Do not expose raw R2 object keys as authorization.

## Tests
- large artifact;
- cancelled upload;
- cross-Workspace access;
- expired session;
- Host reconnect mid-upload.

## Exit criteria
Realtime channels remain bounded under large workloads.

---

# PA-15 — Realtime ordering, backpressure and performance

## Goal
Make realtime robust under many parallel Workers.

## Design
- sequence durable events;
- bounded per-connection queues;
- coalesce ephemeral progress;
- drop/replace stale status updates;
- never drop terminal/domain events;
- reconnect/resync rather than retaining unbounded queues.

## Load scenarios
Test:
- 1 Host / 10 concurrent assignments;
- multiple Hosts;
- multiple browser tabs;
- high-rate output Worker;
- slow browser client;
- disconnected browser reconnect.

## Metrics
Track:
- active App sockets;
- active Host sockets;
- event rate;
- dropped/coalesced ephemeral events;
- reconnects;
- queue depth;
- event-to-UI latency.

## Exit criteria
A noisy Worker cannot degrade Cloud or other users.

---

# PA-16 — Notifications and background UX

## Goal
Handle long-running work when Conclave AX is not the active tab.

## Web
Support:
- in-app unread indicators;
- browser notification integration later/optional;
- completion/failure notifications;
- approval-required notification.

Do not require browser notification permissions for normal operation.

## Future mobile
Define notification event semantics reusable by mobile push later.

Do not implement mobile now unless separately prioritized.

## Exit criteria
Users can leave a Run and reliably discover important completion/attention events later.

---

# PA-17 — Observability and correlation across App -> Cloud -> Host -> Worker

## Goal
Make distributed failures diagnosable.

## Correlation
Use:
- workspaceId;
- runId;
- taskId;
- attemptId;
- assignmentId;
- hostId;
- workerId;
- credentialProfileId where safe;
- requestId/eventId.

## Logs
Structured logs in Cloud and Host.

Worker logs are bounded/redacted.

## Tracing semantics
Even without adopting a full distributed tracing vendor, preserve correlation IDs across:
- HTTPS command;
- orchestration;
- assignment;
- Host;
- Worker;
- realtime event.

## UI support
Support diagnostics export from Host and Run details without secrets.

## Exit criteria
A failed assignment can be traced end-to-end from Chat request to Worker process.

---

# PA-18 — Security review of the final connection model

## Goal
Threat-model the final topology after Better Auth and realtime.

## Review boundaries

### App <-> Cloud
- Better Auth session;
- CSRF;
- WebSocket origin/session;
- subscription authorization;
- session revoke while connected.

### Cloud <-> Host
- machine credential;
- Workspace bindings;
- replay;
- protocol downgrade;
- stolen Host token.

### Host <-> Worker
- untrusted Worker output;
- process sandbox;
- secret scoping;
- filesystem/network permissions;
- forged correlation IDs.

### Accounts
- private default;
- sharing;
- secret leakage;
- provider session isolation.

## Penetration/negative tests
- subscribe to foreign Workspace;
- forge Run/Assignment event;
- Worker attempts to impersonate another Assignment;
- Host tries unrelated Workspace;
- revoked user socket;
- revoked Host socket;
- shared Account access after grant removal.

## Exit criteria
No high-severity unresolved issue in final topology.

---

# PA-19 — Remove remaining obsolete naming and compatibility source

## Goal
Finish the conceptual cleanup once new paths are proven.

## Remove/rename
Examples currently still visible in repository layout:
- `packages/host-protocol`;
- `scripts/install-agent-macos.sh`;
- `scripts/package-agent-macos.sh`;
- `scripts/uninstall-agent-macos.sh`;
- `verify-host-architecture.mjs`;
- historical runtime identifiers such as `AGENT_PROTOCOL_VERSION`.

Rename to Host equivalents or delete if obsolete.

## App internals
Remove unnecessary `studio_*` names after feature decomposition.

## Cloud
PA-3 completes the repository rename to `apps/cloud`.

## Guard
Update architecture guard to reject new:
- Agent domain terminology;
- Plugin domain terminology;
- Conclave AX Studio user-facing terminology;
- direct Worker -> Cloud networking.

## Exit criteria
Repository terminology mirrors the final product architecture.

---

# PA-20 — Clean-room end-to-end acceptance

## Goal
Verify the product exactly as a new customer would experience it.

## Scenario A — Personal
1. Open Conclave AX.
2. Sign in with Better Auth.
3. Create/use personal Workspace.
4. Download Conclave Host.
5. Pair Host.
6. Enable Codex Worker.
7. Worker installs automatically.
8. Connect personal Codex Account.
9. Send Chat request.
10. Observe realtime progress.
11. Receive result/artifacts.
12. Close/reopen browser and retain state.

## Scenario B — Shared Workspace
1. User A invites B.
2. A's Host remains one installation.
3. B sees/uses Host according to permission.
4. B connects private Account.
5. A and B execute concurrently.
6. Credentials and provider sessions remain isolated.

## Scenario C — Shared Account
1. A explicitly shares Account with B.
2. B uses it.
3. secret remains hidden;
4. usage identifies B as consumer and A/Workspace as owner.

## Recovery
- browser reconnect;
- Better Auth session expiration;
- Host sleep/reconnect;
- Worker crash;
- Cloud restart;
- Worker update rollback.

## Exit criteria
All scenarios pass from a fresh database/install with no manual backend intervention.

---

# PA-21 — Final product UX and release gate

## Goal
Treat the architecture as complete and judge the product experience.

## Naming acceptance
Users see:
- Conclave AX;
- Hosts;
- Workers;
- Accounts.

No Studio/Agent/Plugin language in normal UI.

## UX acceptance
Measure:
- time to first Host;
- time to first Worker;
- time to first connected Account;
- time to first successful request;
- clarity of errors;
- reconnect behavior;
- empty/loading states;
- responsive/narrow layout;
- accessibility.

## Technical release gate
- all CI green;
- Better Auth only human-auth path;
- main App hostname not dependent on Cloudflare Access;
- authenticated App realtime;
- authenticated Host realtime;
- no direct Worker -> Cloud connection;
- automatic Worker desired-state;
- private/shared Accounts;
- multi-Workspace Host authorization;
- realtime Run progress;
- bounded event system;
- clean-room tests;
- security review complete.

## Exit criteria
Architecture v4 is not only implemented but consistent in code, naming, connectivity and UX.

---

## PA-12 — Replace large App snapshot refresh with feature read models

The App now loads Workspace catalogs, Hosts, Workers, Accounts, and Usage through focused HTTPS read models in parallel. The active Project uses a project-scoped read model for Chats, Run details, Tasks, Findings, Events, Artifacts, and model activity. The legacy `/api/studio/snapshot` endpoint remains as a compatibility path for fixtures and migration tooling, but normal authenticated App reloads and realtime gap recovery no longer request it.

## PA-13 — Conclave AX chat/run realtime UX

The App now exposes concise live execution progress in Chat, a reconnect/stale-state banner, throttled accessible live-region announcements, and a safe Run input prompt. Selective progress summaries are shown while raw Worker/model chatter remains hidden by default. Run details include the resolved Worker, Account, Host, model, evidence, findings, artifacts, and ordered events. User responses to workflow prompts continue through HTTPS run events; terminal state remains Cloud-authoritative.

## PA-14 — Artifact and large-output transport

Large outputs now use an authenticated Cloud artifact service backed by R2. Uploads are bounded, digest-checked, retry-idempotent, and recorded in D1; realtime publishes only `artifact.created` metadata. Download references contain an opaque artifact ID, never an R2 object key, and Cloud rechecks Workspace/Project authorization on every retrieval. Artifact responses are private and non-cacheable.

## PA-15 — Realtime ordering, backpressure and performance

Realtime Gateway connections now use bounded per-connection queues. Ephemeral progress and status frames are coalesced or dropped when stale, while durable and domain events remain recoverable through durable sequence cursors. If a connection cannot retain durable delivery, it receives a reconnect/resync signal instead of causing unbounded queue growth. Gateway metrics expose active App sockets, event rate, ephemeral drops and coalescing, reconnects, queue depth, and event-to-UI latency.

## PA-16 — Notifications and background UX

Conclave AX now keeps an in-app notification center for important Run completion, failure, and approval-required events. Notifications are retained in the current App session, show an unread badge without requesting browser permission, and link back to the relevant Run when its project context is available. Ephemeral progress remains a live status signal rather than a notification, and the event semantics remain suitable for a future mobile delivery adapter.

## PA-17 — Observability and correlation across App -> Cloud -> Host -> Worker

Cloud requests receive bounded `x-request-id` correlation and structured JSON logs. Durable Run events expose event and persistence correlation IDs to Conclave AX, where Run diagnostics can be exported without secrets. Conclave Host writes bounded, redacted structured logs and can export a sanitized diagnostics bundle containing machine-safe connection state, assignment identity/status fields, and recent logs. Correlation fields remain workspace, Run, Task, Attempt, Assignment, Host, Worker, Account, request, and event identifiers; raw credentials and session tokens are excluded.

## PA-18 — Security review of the final connection model

The final App, Cloud, Host, Worker, and Account trust boundaries were reviewed and documented in `docs/security/PA-18-CONNECTION-MODEL-REVIEW.md`. Realtime now enforces trusted WebSocket Origins and revalidates connected user authorization before client handling and fanout. Host messages revalidate current Host revocation and Workspace bindings. Negative tests cover foreign subscriptions, revoked users and Hosts, forged Worker correlation, replay, protocol downgrade, and grant enforcement. No high-severity unresolved issue remains in the reviewed topology.

# Delegation guidance

For each phase, give the implementation AI this structure:

```text
Implement only phase PA-N from
docs/roadmaps/POST_AUTH_V4_IMPLEMENTATION.md.

Before coding:
1. inspect latest main;
2. read ARCHITECTURE_V4.md and the post-auth roadmap;
3. inspect existing implementation for reusable behavior;
4. identify obsolete code deleted by this phase;
5. produce a small internal implementation plan.

Rules:
- preserve Better Auth as the only human authentication path;
- preserve Cloud as authoritative control plane;
- Host is the only machine-side Cloud principal;
- Workers never authenticate directly to Conclave Cloud;
- raw credentials never appear in realtime events/logs;
- commands stay HTTPS unless there is a concrete reason otherwise;
- realtime WebSocket primarily delivers events;
- add tests for every exit criterion;
- remove replaced compatibility code;
- keep CI green.

At completion report:
- files changed/deleted;
- schema/protocol changes;
- tests and exact results;
- UX changes;
- security implications;
- remaining follow-ups.
```
