# Architecture v3 Implementation Roadmap

This roadmap supersedes Architecture v2 implementation phases where they conflict with the Flutter/Dart Agent design.

Architecture v3 principle:

> **Cloud orchestrates. Agent Engine executes. Worker Plugins integrate. Workers do the work. Flutter apps control and observe.**

Each phase should normally be implemented as one PR or a small set of tightly scoped PRs. Do not combine multiple major phases unless a dependency makes that unavoidable.

---

## P0 — Stabilize main

### Goal
Restore a trustworthy baseline before migration work.

### Scope
- fix all current Prettier failures;
- fix Flutter analyzer findings;
- run full TypeScript lint/typecheck/tests;
- run Flutter analyze/tests;
- run Wrangler startup checks;
- verify new Agent App and Agent Engine scaffolds also analyze cleanly.

### Deliverables
- green GitHub Actions;
- no ignored formatter/lint failures;
- no skipped tests caused by earlier failures;
- documented local commands matching CI.

### Exit criteria
- all CI jobs green;
- no known red checks carried into P1.

---

# P1 — Documentation and architecture freeze

### Goal
Make Architecture v3 the single source of truth for humans and AI development agents.

### Why
The repository has evolved through several architectures. If contradictory documents remain active, future coding agents can implement obsolete concepts such as direct provider execution, Local Runtime as a product, or TypeScript Agent-specific assumptions.

### Scope
1. Review all architecture/specification documents.
2. Mark conflicting v1/v2 documents as superseded.
3. Ensure top-level `README.md`, `ARCHITECTURE.md`, and `ROADMAP.md` link only to Architecture v3.
4. Ensure ADR-003 is normative.
5. Document the deployable applications:
   - Studio;
   - Cloud;
   - Agent App;
   - Agent Engine.
6. Document Worker Plugins as executable, language-independent integrations.
7. Document the process model:
   - Agent App process;
   - Agent Engine process;
   - Worker Plugin process;
   - external agent/tool process.
8. Document the technology split:
   - Flutter/Dart user-facing apps;
   - Dart Agent Engine;
   - TypeScript Cloud;
   - Cloudflare infrastructure.

### Deliverables
- `docs/architecture/ARCHITECTURE_V3.md`;
- `docs/architecture/TECH_STACK.md`;
- `docs/architecture/APPLICATIONS.md`;
- `docs/architecture/MIGRATION_TO_V3.md`;
- ADR-003;
- cleaned top-level documentation.

### Guardrails
- do not delete useful historical information from Git history;
- do not introduce implementation behavior during this phase;
- no new legacy `ConnectionResource` or direct-provider architecture.

### Tests
- documentation links resolve;
- repository search confirms no active normative docs instruct new work to use Local Runtime/direct-provider architecture.

### Dependencies
- P0.

### Exit criteria
A new developer or AI worker can understand the current architecture by reading the top-level documents without encountering contradictory active guidance.

---

# P2 — Schema-first cross-language protocols

### Goal
Create one canonical protocol definition shared by TypeScript Cloud, Dart Agent Engine, Flutter Agent App, and Worker Plugins.

### Why
Architecture v3 crosses language boundaries. Hand-maintaining similar TypeScript and Dart models will eventually drift and produce subtle compatibility failures.

### Protocol families
Define three explicit boundaries:

1. **Cloud ↔ Agent Engine**
   - enrollment;
   - hello/handshake;
   - heartbeat;
   - capability inventory;
   - desired state;
   - Worker configuration;
   - assignment start/progress/result/error/cancel;
   - artifact references;
   - update commands;
   - reconciliation.

2. **Agent App ↔ Agent Engine**
   - local status;
   - enrollment commands;
   - connection status;
   - plugin inventory;
   - Worker status;
   - active assignments;
   - logs;
   - settings;
   - update/restart actions.

3. **Agent Engine ↔ Worker Plugin**
   - initialize;
   - health;
   - configure;
   - execute;
   - progress;
   - artifact output;
   - result;
   - error;
   - cancel;
   - shutdown.

### Technical approach
Choose a canonical schema source.

Recommended candidates:
- JSON Schema for message payloads;
- OpenAPI for HTTP APIs;
- generated TypeScript and Dart models.

The canonical schema must define:
- required fields;
- enums;
- maximum payload sizes where relevant;
- protocol version;
- correlation IDs;
- idempotency keys;
- timestamps;
- optional/nullable semantics;
- structured error codes.

### Versioning
Implement protocol compatibility rules:
- major = incompatible;
- minor = backwards-compatible additions;
- patch = non-contract changes.

Handshake must reject unsupported major versions.

### Deliverables
- schema directory;
- generated TS models;
- generated Dart models;
- shared fixture messages;
- protocol compatibility documentation;
- code generation scripts;
- CI step verifying generated files are up to date.

### Tests
- TS parses Dart-generated fixture;
- Dart parses TS-generated fixture;
- invalid enum rejected;
- required field missing rejected;
- unknown compatible optional field tolerated;
- incompatible protocol major rejected;
- duplicate assignment IDs preserved exactly;
- round-trip serialization keeps semantic equivalence.

### Risks
- choosing an over-complex schema/codegen system;
- generating poor Dart ergonomics;
- allowing Cloud-specific fields to leak into plugin protocol.

### Guardrails
Keep the schemas small and domain-oriented. Do not model provider-specific details in Cloud↔Agent contracts.

### Dependencies
- P1.

### Exit criteria
TypeScript and Dart use generated/validated models derived from one canonical schema source, with automated compatibility tests.

---

# P3 — Dart Agent Engine skeleton

### Goal
Create the long-running headless Agent Engine as a native Dart application.

### Why
The Agent Engine is the execution host and must survive UI closure, run independently, and provide a stable platform for Worker Plugins.

### Scope
Create `apps/agent_engine` with:

#### Lifecycle
- startup;
- configuration loading;
- runtime directory initialization;
- shutdown;
- restart hook;
- signal handling;
- single-instance protection.

#### Logging
- structured logs;
- log levels;
- rotating local log files;
- redaction hooks;
- correlation fields.

#### Storage paths
Define platform-correct directories for:
- config;
- credentials references;
- logs;
- plugin packages;
- Worker runtime data;
- assignment journal;
- temporary files;
- update staging.

#### Interfaces
Add abstractions for:
- Cloud client;
- assignment journal;
- plugin manager;
- Worker manager;
- updater;
- local IPC server;
- secure storage;
- runtime capabilities.

Do not fully implement those subsystems yet.

#### Build
- `dart compile exe`;
- macOS;
- Linux;
- Windows CI compilation.

### Deliverables
- native executable;
- configuration model;
- lifecycle framework;
- logging framework;
- platform path abstraction;
- basic health/status object.

### Tests
- start/stop;
- duplicate instance behavior;
- invalid config;
- missing directories are created;
- SIGTERM/graceful shutdown;
- logs written and sensitive fields redacted;
- AOT build succeeds.

### Risks
- coupling Engine too tightly to Flutter;
- using static globals instead of injectable services;
- making UI assumptions in the Engine.

### Guardrails
Agent Engine imports Dart libraries only, never Flutter packages.

### Dependencies
- P2.

### Exit criteria
A self-contained Dart Agent Engine executable runs headlessly, reports health, handles shutdown safely, and compiles on all target desktop OSes.

---

# P4 — Flutter Agent App skeleton

### Goal
Create the cross-platform user interface for managing one local Conclave Agent host.

### Why
Users need a friendly way to enroll a machine, inspect Workers/Plugins, and manage local execution without using the terminal.

### Scope
Create `apps/agent_app`.

Initial screens:
- welcome/setup;
- Engine status;
- Cloud connection status;
- enrollment;
- installed plugins;
- configured Workers;
- active assignment summary;
- logs;
- settings;
- update status.

### Architecture
Use clear UI/state separation.

Recommended stores/services:
- EngineConnectionStore;
- AgentStatusStore;
- PluginStore;
- WorkerStore;
- AssignmentStore;
- SettingsStore;
- UpdateStore.

Do not embed Cloud orchestration logic in the UI.

### Engine relationship
Agent App:
- detects Engine;
- starts it if configured;
- connects using local IPC;
- can request restart;
- does not perform Worker execution itself.

### UI behavior
If Engine is unavailable:
- show explicit offline state;
- offer restart/start action;
- do not silently fall back to in-process execution.

### Deliverables
- desktop shell;
- navigation;
- Engine status card;
- enrollment placeholder;
- Workers/Plugins placeholder;
- logs/settings views;
- responsive desktop layout.

### Tests
- Engine offline UI;
- Engine online UI;
- reconnect;
- UI survives Engine restart;
- narrow window layout;
- no work continues inside UI after Engine disconnect.

### Dependencies
- P3;
- P5 may be developed partially in parallel after interfaces are frozen.

### Exit criteria
Agent App can launch, detect/connect to Agent Engine, show status, and close without stopping the Engine.

---

# P5 — Local IPC

### Goal
Create the reliable local communication boundary between Agent App and Agent Engine.

### Why
The Agent App and Engine are separate processes. They need authenticated local communication without exposing a network service to the LAN.

### Transport
Preferred final transport:
- Unix domain socket on macOS/Linux;
- named pipe on Windows.

Allowed first implementation:
- localhost-only TCP/HTTP/WebSocket with random local authentication token.

### Protocol
Reuse schemas from P2.

Commands:
- get status;
- get Agent identity;
- get Cloud connection status;
- enroll;
- list plugins;
- list Workers;
- list assignments;
- tail logs;
- update settings;
- restart Engine;
- trigger update check.

### Authentication
Even local IPC should validate the client.

Possible mechanisms:
- random bootstrap token stored with user-only permissions;
- OS user ownership checks;
- pipe/socket filesystem permissions.

### Reliability
Implement:
- reconnect;
- request timeout;
- protocol mismatch;
- Engine restart detection;
- backpressure for logs.

### Deliverables
- Dart IPC server;
- Flutter/Dart IPC client package;
- typed commands/events;
- authentication mechanism;
- local discovery strategy.

### Tests
- unauthorized client rejected;
- malformed payload rejected;
- reconnect after Engine restart;
- concurrent requests;
- log streaming;
- stale socket cleanup;
- Windows/macOS/Linux transport tests where feasible.

### Risks
- choosing a transport that is difficult to package cross-platform;
- accidental LAN exposure;
- sending secrets through logs/events.

### Dependencies
- P2;
- P3;
- P4.

### Exit criteria
Agent App controls and observes Engine entirely through authenticated local IPC, with no direct shared-memory assumptions.

---

# P6 — Cloud Agent Gateway parity

### Goal
Connect the Dart Agent Engine to the existing TypeScript Cloud control plane.

### Why
The TypeScript Agent already established important behavior. The Dart Engine must reach functional parity without changing Cloud authority.

### Scope

#### Enrollment
- one-time enrollment token;
- Workspace binding;
- machine metadata;
- Agent identity issuance;
- secure local credential storage.

#### Connection
- outbound WebSocket;
- TLS only;
- protocol version negotiation;
- Agent hello;
- heartbeat;
- presence state;
- reconnect with exponential backoff;
- jitter;
- session replacement policy.

#### Desired state
Cloud can send:
- Worker configurations;
- plugin requirements;
- update requirements;
- assignment notifications.

#### Agent state
Engine reports:
- version;
- OS/architecture;
- plugin inventory;
- Worker availability;
- capabilities;
- current assignments.

### Cloud changes
Keep Cloud TypeScript.

Refactor only if needed to support schema-first generated protocol bindings.

Do not move Cloud logic into Dart.

### Deliverables
- Dart Cloud client;
- enrollment implementation;
- secure credential abstraction;
- WebSocket connection manager;
- heartbeat/presence;
- desired-state sync.

### Tests
- first enrollment;
- invalid/expired token;
- revoked Agent;
- reconnect after network loss;
- duplicate session;
- protocol mismatch;
- heartbeat timeout;
- Cloud restart;
- Agent Engine restart.

### Security
Machine credentials must:
- never be logged;
- be revocable;
- belong to exactly one Workspace;
- be stored in OS secure storage when productionized.

### Dependencies
- P2;
- P3;
- Cloud Agent Gateway from existing implementation.

### Exit criteria
The Dart Agent Engine appears online in Cloud, can enroll, reconnect, synchronize desired state, and survives transient network failures.

---

# P7 — Dart assignment journal and reconciliation

### Goal
Guarantee assignment durability across Agent restart, disconnect, and duplicate Cloud delivery.

### Why
Write-capable AI work must not run twice accidentally, disappear after a crash, or return ambiguous terminal state.

### Assignment lifecycle
Define explicit local states:
- received;
- accepted;
- running;
- cancelling;
- succeeded;
- failed;
- cancelled;
- interrupted;
- result_pending_upload;
- reconciled.

### Journal
Persist:
- assignmentId;
- attemptId;
- WorkerId;
- plugin version;
- timestamps;
- state transitions;
- result reference;
- progress metadata;
- cancellation status.

Use durable local storage appropriate for low-volume structured state.

### Reconciliation
On reconnect:
1. Agent sends journal summary.
2. Cloud responds with authoritative state.
3. Engine resolves:
   - continue;
   - upload pending result;
   - cancel stale assignment;
   - mark already completed;
   - quarantine inconsistent state.

### Idempotency
Worker execution must never restart solely because the same assignment message is delivered twice.

### Deliverables
- journal store;
- state machine;
- reconciliation protocol;
- recovery rules;
- diagnostic tooling.

### Tests
- crash before ACK;
- crash after ACK before execution;
- crash during execution;
- crash after local success before upload;
- duplicate assignment.start;
- duplicate assignment.result;
- Cloud cancelled while Agent offline;
- corrupted journal detection/recovery.

### Risks
- retrying a write-capable Task twice;
- treating network ambiguity as failure and rerunning;
- journal corruption.

### Dependencies
- P6.

### Exit criteria
Restarting Agent Engine during assignment lifecycle does not corrupt Cloud state or cause unintended duplicate execution.

---

# P8 — Worker Plugin Protocol

### Goal
Define the stable language-independent boundary between Agent Engine and Worker Plugins.

### Why
Worker Plugins need to evolve independently and may be implemented in Dart, TypeScript, Rust, Python, Go, or another language.

### Transport
Preferred v1:
- JSON-RPC 2.0 over stdin/stdout.

Use stderr for bounded diagnostic logs only.

### Required plugin methods
- `initialize`;
- `health`;
- `getCapabilities`;
- `configureWorker`;
- `startAssignment`;
- `cancelAssignment`;
- `shutdown`.

### Notifications/events
- progress;
- log;
- artifact;
- usage;
- result;
- error;
- authentication_required;
- rate_limited.

### Plugin identity
Handshake returns:
- plugin id;
- version;
- protocol version;
- runtime language;
- capabilities.

### Process handling
Agent Engine must:
- spawn;
- monitor;
- bound memory where feasible;
- bound stdout/stderr;
- terminate gracefully;
- force kill if needed;
- restart unhealthy plugin;
- distinguish plugin crash from assignment failure.

### Deliverables
- protocol schema;
- Dart Engine plugin client;
- reference plugin server;
- test harness for third-party plugins.

### Tests
- correct handshake;
- unsupported protocol;
- malformed JSON;
- partial line;
- large output;
- plugin crash;
- timeout;
- cancel;
- plugin ignores cancel;
- process-tree termination;
- concurrent Workers if supported.

### Security
Plugin receives only scoped configuration/secrets/resources required for the Worker.

### Dependencies
- P2;
- P3.

### Exit criteria
An out-of-process Echo plugin can execute assignments, stream progress, be cancelled, crash safely, and restart without killing Agent Engine.

---

# P9 — Plugin package and install manager

### Goal
Allow Agent Engine to automatically install, update, rollback, and remove signed Worker Plugins from Cloud registry.

### Package metadata
Each plugin version includes:
- pluginId;
- version;
- digest;
- signature;
- publisher;
- protocol compatibility;
- Agent Engine compatibility;
- supported OS/arch;
- entrypoint;
- permissions;
- package size;
- release channel.

### Agent behavior
1. receive desired Worker/plugin version;
2. query registry;
3. choose compatible version;
4. download to staging;
5. verify digest;
6. verify signature;
7. unpack;
8. validate manifest;
9. install side-by-side;
10. health check;
11. activate;
12. retain previous version for rollback.

### Upgrade behavior
- no mid-assignment forced replacement;
- drain existing plugin process;
- activate new version;
- rollback if health check fails.

### Cleanup
Retention policy for:
- previous versions;
- unused packages;
- failed staging files.

### Deliverables
- plugin installer;
- version resolver;
- signature verifier;
- package cache;
- rollback manager;
- installed-plugin inventory API.

### Tests
- valid install;
- digest mismatch;
- signature failure;
- unsupported OS;
- unsupported Agent Engine version;
- update;
- rollback;
- disk-full simulation;
- interrupted download;
- revoked plugin version.

### Dependencies
- P6;
- P8.

### Exit criteria
Creating/enabling a Cloud Worker causes Agent Engine to install the required plugin securely and report it healthy.

---

# P10 — Deterministic Dart Worker Plugin

### Goal
Prove the full Architecture v3 execution path without AI-provider variability.

### Plugin
Implement a first-party Dart Echo/Test plugin.

Capabilities:
- deterministic result;
- progress updates;
- optional artificial delay;
- cancellation;
- artifact emission;
- deliberate error modes for tests.

### E2E flow
```text
Cloud
 -> WorkerAssignment
 -> Dart Agent Engine
 -> Dart Echo Plugin
 -> structured result
 -> Agent Engine
 -> Cloud
```

### Deliverables
- plugin package;
- manifest;
- registry entry;
- signed test package;
- E2E test.

### Tests
- success;
- cancellation;
- timeout;
- plugin crash;
- Agent reconnect;
- duplicate assignment;
- artifact transfer;
- plugin update between assignments.

### Dependencies
- P8;
- P9.

### Exit criteria
A real Cloud Task completes end-to-end through Dart Agent Engine and an out-of-process Dart plugin with no TypeScript Agent involvement.

---

# P11 — Runtime capability library in Dart

### Goal
Build the secure reusable local execution primitives required by coding agents and tool plugins.

### Scope

#### Process execution
- spawn process;
- stdin;
- stdout/stderr streaming;
- timeout;
- process-tree cancellation;
- exit code;
- environment allowlist.

#### Filesystem
- canonicalize paths;
- enforce repository/workspace roots;
- read;
- write;
- patch;
- delete;
- create directory;
- file hashing.

#### Search
- bounded file search;
- text search;
- ignore rules.

#### Git
- status;
- diff;
- branch;
- worktree;
- current revision;
- repository validation.

#### Commands
- allowlisted command execution;
- working-directory boundary;
- output limits;
- duration limits.

#### Artifacts
- hashes;
- metadata;
- local artifact staging;
- upload preparation.

### Security requirements
Port the behavioral protections from the existing Local Runtime:
- traversal prevention;
- symlink escape protection where possible;
- output limits;
- environment filtering;
- command scoping;
- audit/evidence.

### Deliverables
Reusable Dart packages used by Agent Engine and official plugins.

### Tests
- path traversal;
- symlink escape;
- huge stdout;
- hung process;
- process-tree cancellation;
- invalid Git repo;
- worktree isolation;
- command outside allowlist;
- hashing consistency.

### Dependencies
- P3.

### Exit criteria
Dart runtime primitives meet or exceed security/behavior parity with the current TypeScript Local Runtime capabilities.

---

# P12 — Codex Worker Plugin

### Goal
Support Codex as a first-class local/subscription-backed Worker through the Dart Agent Engine.

### Scope
- locate Codex CLI;
- detect version;
- detect authentication readiness without exposing credentials;
- invoke non-interactively;
- isolated session support;
- project/repository working directory;
- structured output parsing;
- progress/log mapping;
- timeout;
- cancellation;
- usage metadata where available.

### Worker configuration
Support:
- name;
- role set;
- model/config if Codex exposes it;
- session policy;
- repository permissions;
- timeout;
- concurrency.

### Session policy
Options:
- fresh session per Attempt;
- reuse within Task;
- persistent project session if explicitly allowed.

Independent review/research defaults to fresh context.

### Deliverables
- Dart Codex plugin;
- manifest;
- authentication status reporting;
- E2E fixture repository tests.

### Tests
- Codex missing;
- unauthenticated;
- successful task;
- malformed output;
- timeout;
- cancellation;
- CLI crash;
- repository permission denial;
- two isolated sessions;
- plugin update compatibility.

### Dependencies
- P9;
- P11.

### Exit criteria
Cloud can execute a real Codex Task through Dart Agent Engine and receive structured evidence/result without any direct Cloud-to-Codex path.

---

# P13 — Claude Code Worker Plugin

### Goal
Provide Claude Code through the same Worker Plugin abstraction as Codex.

### Scope
Mirror the generic behaviors established in P12:
- CLI discovery;
- auth readiness;
- non-interactive task execution;
- structured result;
- progress;
- cancellation;
- timeout;
- repository permissions;
- session isolation.

### Design requirement
Do not introduce Claude-specific branching into Cloud or Forge.

Only plugin implementation may contain Claude-specific logic.

### Deliverables
- Dart Claude Code plugin;
- manifest;
- health/auth state;
- mocked tests;
- real local acceptance test instructions.

### Tests
- missing CLI;
- unauthenticated;
- success;
- timeout;
- malformed output;
- cancellation;
- two independent sessions;
- same Task configurable between Codex and Claude by Worker selection only.

### Dependencies
- P11;
- P12 patterns.

### Exit criteria
Changing Worker configuration from Codex to Claude Code requires no orchestration code change.

---

# P14 — API Worker Plugins

### Goal
Move online provider API execution behind Agent-hosted Worker Plugins.

### Initial plugins
- OpenAI;
- Anthropic;
- Gemini later.

### Architecture rule
Cloud must never call model APIs directly.

### Implementation policy
Prefer Dart HTTP implementations when:
- provider API is straightforward;
- streaming/tool/schema functionality is manageable;
- official SDK adds little value.

Use a Node/other-language plugin when:
- official SDK provides significant complexity reduction;
- required features would be risky to reproduce;
- authentication/tooling is materially better.

The Worker Plugin Protocol makes both valid.

### Common capabilities
- API key/auth readiness;
- model list/config;
- streaming;
- structured output;
- usage tokens;
- rate-limit metadata;
- retry classification;
- cancellation;
- timeout.

### Secrets
Default v1:
- API key stored on Agent host;
- Cloud stores only secret reference/status.

### Deliverables
- OpenAI plugin;
- Anthropic plugin;
- provider-neutral Worker configuration;
- usage/cost reporting.

### Tests
- auth missing;
- invalid key;
- success;
- rate limit;
- retryable server failure;
- malformed structured result;
- timeout;
- cancellation;
- cost/usage reporting.

### Dependencies
- P8;
- P9.

### Exit criteria
All online model API calls execute through Agent Engine Worker Plugins, and repository search confirms Cloud does not import provider execution clients.

---

# P15 — Interactive web AI Worker Plugin

### Goal
Support subscription-backed web/cloud AI applications as first-class Workers while preserving Agent-only execution architecture.

### Architecture
```text
Cloud assignment
 -> Agent Engine
 -> Web AI Worker Plugin
 -> Cloud connector/mailbox relay
 -> ChatGPT/Claude/etc web session
 -> result
 -> Agent Engine
 -> Cloud
```

Cloud provides public connectivity but is not the model executor.

### Scope
- WorkerSession creation;
- provider/surface metadata;
- Conclave session id;
- optional external conversation reference;
- mailbox;
- get task/context;
- submit candidate/result;
- follow-up messages;
- session lease;
- waiting-for-user status;
- quota/unavailable status.

### Conversation policies
- fresh chat per Attempt;
- Task-level reuse;
- Project-level persistence if explicitly configured.

### Browser automation
Do not make DOM automation the primary architecture.

Use supported connector/app/MCP/plugin mechanisms when available.

### Deliverables
- web Worker plugin;
- Cloud relay endpoints;
- session ownership model;
- structured result path.

### Tests
- create session;
- claim assignment;
- pull context;
- submit result;
- follow-up;
- lease expiry;
- Agent disconnect;
- quota state;
- fallback to API Worker.

### Dependencies
- P8;
- P6;
- existing interactive connector concepts.

### Exit criteria
A subscription-backed web AI completes a real candidate Attempt through an Agent-owned Worker without direct provider API billing.

---

# P16 — Agent App functional UI

### Goal
Turn the Flutter Agent App from a shell into a complete local host-management UI.

### Screens

#### Overview
- Agent Engine online/offline;
- Cloud connected/disconnected;
- Agent identity;
- host;
- version;
- active assignment;
- health warnings.

#### Enrollment
- enrollment code;
- Workspace confirmation;
- successful binding;
- revoke/reset.

#### Workers
- configured Workers;
- health;
- authentication readiness;
- enabled/disabled;
- active assignment.

#### Plugins
- installed versions;
- update availability;
- permissions;
- health;
- rollback state.

#### Assignments
- current;
- recent;
- progress;
- elapsed time;
- status.

#### Logs
- filtered Agent Engine logs;
- plugin logs;
- export diagnostics.

#### Settings
- start at login;
- update channel;
- log level;
- local storage location;
- privacy/telemetry options.

### UX rules
- Cloud orchestration changes belong primarily in Studio;
- Agent App manages this machine only;
- local credentials are configured here when appropriate.

### Deliverables
Production-quality desktop UI and state management.

### Tests
- Engine offline;
- Cloud offline;
- plugin update;
- authentication missing;
- active assignment;
- restart Engine;
- local settings persistence;
- UI does not block long operations.

### Dependencies
- P5;
- P6;
- P9.

### Exit criteria
A normal user can enroll and maintain a host without terminal commands.

---

# P17 — Agent Engine self-update

### Goal
Allow deployed Agent Engines to update safely without manual reinstall.

### Release metadata
Cloud/R2 stores:
- version;
- channel;
- OS;
- architecture;
- digest;
- signature;
- minimum compatible protocol;
- release notes;
- package URL.

### Update lifecycle
- check;
- download;
- verify;
- stage;
- wait for safe point;
- drain incompatible assignments;
- restart;
- health check;
- commit;
- rollback if unhealthy.

### Forced security update
Support policy for minimum required version, but never corrupt running assignments.

### Agent App
Show:
- available version;
- downloading;
- staged;
- waiting for tasks;
- restarting;
- success;
- rollback.

### Deliverables
- update client;
- signed release verifier;
- staging directory;
- restart bootstrap;
- rollback strategy.

### Tests
- valid update;
- bad signature;
- digest mismatch;
- interrupted download;
- disk full;
- active assignment;
- restart failure;
- rollback;
- protocol-incompatible release.

### Dependencies
- P3;
- P6.

### Exit criteria
A test Agent Engine updates from one signed version to another and automatically rolls back on failed health check.

---

# P18 — Agent App packaging and distribution

### Goal
Provide a polished installable Conclave Agent product.

### Initial platform
macOS first.

### Package contents
- Flutter Agent App;
- Dart Agent Engine executable;
- default configuration;
- signing metadata;
- service/startup helper.

### macOS
- signed app;
- notarization;
- Engine launch-at-login/background service;
- secure storage integration;
- uninstall path;
- update permissions.

### Later
Windows:
- signed installer;
- startup/service integration;
- Credential Manager.

Linux:
- package/app bundle;
- systemd user service;
- secret storage integration.

### Install experience
1. install Agent App;
2. launch;
3. Engine starts;
4. enroll;
5. configure local credentials;
6. Cloud shows Agent online.

### Deliverables
- build scripts;
- release artifacts;
- installer docs;
- uninstall;
- upgrade path.

### Tests
- clean install;
- reinstall;
- upgrade;
- uninstall;
- Engine autostart;
- user logout/login;
- corrupted install recovery.

### Dependencies
- P16;
- P17.

### Exit criteria
A fresh macOS machine can install one signed package, enroll the Agent, restart the machine, and return online automatically.

---

# P19 — Studio architecture cleanup

### Goal
Make Studio the clean chat-first Cloud client defined by Architecture v3.

### Scope
Keep Flutter.

Refactor data architecture into focused stores/services:
- AuthStore;
- WorkspaceStore;
- ProjectStore;
- ChatStore;
- RunStore;
- AgentStore;
- WorkerStore;
- PluginStore;
- UsageStore.

### Remove
- monolithic snapshot state where avoidable;
- demo/static runtime assumptions;
- direct Agent/local execution assumptions;
- hard-coded personal identity.

### Navigation
- Workspace switcher;
- New Chat;
- Projects/Chats;
- Agents;
- Workers;
- Plugins;
- Usage;
- Settings.

### Chat behavior
- ordered messages;
- send;
- inline Run cards;
- clarification/approval;
- final result;
- artifact links;
- Open Run details.

### Deliverables
- refactored Studio data layer;
- chat-first navigation;
- clean API boundary.

### Tests
- empty account;
- multiple Workspaces;
- multiple Projects/Chats;
- Run updates;
- Agent list;
- Worker status;
- browser refresh state restoration;
- desktop/web consistency.

### Dependencies
- Cloud APIs already available;
- P1 architecture.

### Exit criteria
Studio communicates only with Cloud and provides the primary user flow through Projects and Chats.

---

# P20 — Multi-user authentication

### Goal
Complete secure authentication, tenancy, and collaboration foundations.

### User authentication
Support initial providers such as:
- GitHub;
- Google;
- email magic link if desired.

Keep provider integration behind an identity adapter.

### Web
- secure HttpOnly session cookie;
- SameSite;
- CSRF protection where needed;
- session expiration;
- refresh/rotation.

### Desktop Studio
Use browser-based OAuth/OIDC Authorization Code + PKCE.

### Workspace model
- owner;
- admin;
- member;
- viewer.

### Invitations
- invite;
- expiry;
- accept;
- revoke.

### Project access
Start with Workspace-wide access plus optional Project restriction.

### Audit
Record:
- login;
- logout;
- membership changes;
- Agent enroll/revoke;
- Worker changes;
- plugin approvals;
- Run controls.

### Tests
- cross-tenant ID substitution;
- viewer mutation denial;
- revoked session;
- invitation reuse;
- removed member;
- expired session;
- Project restriction;
- Agent from another Workspace.

### Dependencies
- P19 for polished UI, though backend work can start earlier.

### Exit criteria
Two real users can safely collaborate in one Workspace while being unable to access another Workspace's data.

---

# P21 — Cloud/Agent management UI

### Goal
Let users centrally manage their execution fleet from Studio.

### Agent management
Show:
- name;
- online/offline;
- OS/architecture;
- Agent Engine version;
- Agent App version where reported;
- update channel;
- plugin inventory;
- Worker count;
- active assignments;
- last seen;
- revoke.

### Worker management
Create/edit:
- Worker name;
- Agent;
- plugin;
- model/config;
- roles;
- capabilities;
- session policy;
- concurrency;
- billing mode;
- enabled state.

### Plugin catalog
Show:
- plugin description;
- publisher;
- versions;
- permissions;
- supported platforms;
- compatibility;
- release channel;
- installed Agents.

The catalog is read from the active Cloud plugin registry and is independent
of the tenant's configured Workers. This is required for first-time setup:
the first Worker selects a registered plugin, and only then does the Agent
Engine receive that plugin as desired state. A catalog query must therefore
not join through `workers` or hide every plugin until a Worker already exists.

### Desired-state behavior
Studio updates Cloud desired configuration.

Agent Engine synchronizes and applies it.

### Deliverables
- Agent management pages;
- Worker editor;
- Plugin catalog;
- update controls;
- status/live refresh.

### Tests
- create Worker;
- Agent offline;
- incompatible plugin;
- missing credentials;
- disable Worker during idle;
- revoke Agent;
- upgrade plugin;
- multi-Workspace isolation.

### Dependencies
- P6;
- P9;
- P16;
- P19;
- P20.

### Exit criteria
Users can manage Agents, Workers, and plugins centrally without database/file edits.

---

# P22 — Multi-worker / multi-Agent orchestration

### Goal
Prove generic distributed orchestration across multiple Workers and Agent Engines.

### Reuse existing execution policy modes
- single;
- parallel;
- synthesize;
- compare_and_select;
- competitive_implementation.

### Scheduler inputs
Consider:
- role/capability;
- Worker health;
- Agent online status;
- concurrency;
- model/provider independence;
- billing mode;
- estimated cost;
- Project policy;
- Workspace policy;
- user selection.

### Scenarios

#### Parallel research
Worker A on Agent 1 + Worker B on Agent 2.

#### Synthesis
Third Worker combines candidates.

#### Review
Independent Reviewer on separate Worker/provider.

#### Competitive implementation
Separate Git worktrees/workspaces.

### Failure handling
- Agent disconnect;
- Worker unavailable;
- quota;
- timeout;
- fallback;
- partial ensemble completion.

### Cost controls
- max candidates;
- max model calls;
- API budget;
- prefer subscription Workers;
- no uncontrolled nested ensembles.

### Deliverables
- distributed scheduling integration;
- deterministic candidate tracking;
- independence metadata;
- failure/fallback logic.

### Tests
- two Agents;
- one Agent fails;
- same-provider independence;
- provider-independent policy;
- budget stop;
- fallback;
- synthesis;
- competing implementations isolated correctly.

### Dependencies
- P12/P13/P14 depending scenario;
- P6;
- existing multi-worker Core logic.

### Exit criteria
The same Task execution policy works across Workers on multiple hosts and different plugin implementation languages.

---

# P23 — Forge E2E on Dart Agent Engine

### Goal
Prove the complete product workflow using the new host architecture.

### Fixture
Use a controlled real Git repository with:
- known bug/feature;
- test suite;
- deterministic acceptance criteria.

### Scenario
1. User logs into Studio.
2. Opens Project/Chat.
3. Sends development request.
4. Cloud creates Goal/Run.
5. Research Worker inspects repo.
6. Lead/Planner proposes plan.
7. Core validates plan.
8. Codex Worker implements in isolated workspace.
9. Reviewer Worker independently reviews.
10. Blocking Finding triggers correction loop if needed.
11. Test Worker executes real tests.
12. Verifier interprets evidence.
13. Run completes.
14. Chat displays verified result/artifacts.

### Required evidence
- task events;
- Worker identities;
- plugin versions;
- Git revision;
- diff;
- commands;
- exit codes;
- findings;
- verification;
- completion report.

### Recovery tests
- restart Agent Engine;
- restart Cloud Worker;
- temporary network loss;
- Reviewer timeout.

### Deliverables
- automated E2E suite;
- fixture repo;
- documented expected event sequence.

### Dependencies
- P12;
- P13 or another independent Reviewer;
- P19;
- P20 where auth required.

### Exit criteria
A real development Goal completes end-to-end with no TypeScript Agent process and no direct Cloud-to-model execution.

---

# P24 — Retire TypeScript Agent

### Goal
Remove the transitional Agent implementation after Dart Engine parity is proven.

### Preconditions
Do not start until:
- P23 passes;
- Agent enrollment parity;
- assignment journal parity;
- plugin install/update parity;
- self-update path exists;
- Codex/API plugins work;
- CI covers Dart Agent.

### Work
- remove `apps/agent`;
- remove Agent-specific pnpm workspace dependencies;
- remove duplicated TS Agent utilities;
- update CI;
- update docs;
- archive useful test fixtures if needed;
- repository search for legacy Agent imports.

### Migration support
Provide clear upgrade guidance for development installations.

### Tests
- complete CI;
- Cloud works with Dart Agents only;
- packaging;
- E2E;
- no dead references.

### Exit criteria
Host execution stack is exclusively:
- Flutter Agent App;
- Dart Agent Engine;
- executable Worker Plugins.

---

# P25 — Supply-chain and sandbox hardening

### Goal
Make plugin/Agent execution safe enough for external users.

### Plugin supply chain
- signing root;
- publisher identity;
- signature verification;
- revocation;
- key rotation;
- digest enforcement;
- immutable released packages.

### Agent releases
- App signing;
- Engine signing;
- update package signing;
- rollback protection.

### Plugin permissions
Enforce declared permissions:
- filesystem roots;
- repo write;
- shell;
- environment;
- network domains;
- credentials;
- browser;
- Docker.

### Sandboxing
Platform-specific strategy:
- macOS sandbox/process restrictions where feasible;
- Windows job/process controls;
- Linux namespaces/sandboxing where practical.

Do not promise perfect sandboxing if the platform cannot enforce it; expose trust levels.

### Credentials
- OS secure store;
- secret redaction;
- no secrets in logs;
- scoped injection into plugin process;
- revoke/rotate.

### Threat model
Cover:
- malicious plugin;
- compromised Cloud account;
- compromised Agent credential;
- prompt injection causing tool misuse;
- plugin package tampering;
- update compromise;
- repository escape;
- symlink attacks;
- command injection;
- cross-Workspace access.

### Operational security
- rate limits;
- anomaly logging;
- dependency scanning;
- SBOM if practical;
- retention rules;
- backup/restore;
- audit export.

### Tests
- tampered package;
- revoked signing key;
- path escape;
- secret leak tests;
- permission denial;
- malicious output sizes;
- command injection;
- Agent credential revocation.

### Dependencies
Most prior phases.

### Exit criteria
Threat model has no unresolved release-blocking findings and signed update/plugin supply chains are enforced.

---

# P26 — v0.1 release gate

### Goal
Define an objective release threshold rather than shipping based on feature impression.

### Required applications
- Studio Flutter web/desktop;
- Agent App Flutter desktop;
- Agent Engine Dart native;
- TypeScript Cloud.

### Required Cloud features
- authentication;
- Workspaces;
- Projects;
- Chats;
- Goals/Runs/Tasks/Attempts;
- Agent registry;
- Worker registry;
- plugin registry;
- assignment dispatcher;
- audit/evidence;
- D1/R2;
- Workflows;
- Durable Object Agent Gateway.

### Required Agent features
- enroll;
- reconnect;
- journal/recovery;
- plugin install/update;
- Worker execution;
- local credentials;
- self-update;
- logs;
- Agent App UI.

### Required Workers
At minimum:
- Codex or equivalent local coding Worker;
- one online API Worker;
- deterministic Test Worker.

Recommended:
- Claude Code;
- interactive web AI.

### Required orchestration
- single Worker;
- multi-worker research;
- synthesis;
- independent review;
- correction loop;
- verification;
- budget/fallback.

### Required multi-user
- login;
- Workspace;
- roles;
- invitations;
- tenant isolation;
- Project/Chat sharing.

### Required E2E
- Forge real-repository scenario;
- Agent restart recovery;
- Cloud restart recovery;
- multi-Agent scenario;
- plugin update/rollback;
- Agent update/rollback.

### Required quality
- all CI green;
- no skipped critical tests;
- docs reflect implementation;
- no direct Cloud-to-model production path;
- no legacy TypeScript Agent;
- no unresolved high-severity security findings.

### Release artifacts
- Studio web deployment;
- Studio desktop build;
- Agent App installer;
- Agent Engine bundle;
- signed plugins;
- changelog;
- migration/install docs;
- known limitations.

### Exit criteria
Conclave AX v0.1 can be installed by a new user, enrolled, configured with Workers, given a real development request, and produce a verified result through the Architecture v3 pipeline with recoverable state and auditable evidence.

---

# Delegation guidance

For each phase:

1. **Planning worker**
   - inspect current implementation;
   - compare it with the phase;
   - break the phase into small PR-sized tasks;
   - identify reusable existing code;
   - identify migration risk.

2. **Implementation worker**
   - implement one small task at a time;
   - add/update tests;
   - update documentation only where behavior changes.

3. **Independent reviewer**
   - review architecture compliance;
   - review security boundary;
   - verify tests actually cover the exit criteria;
   - reject scope creep.

4. **CI/evidence**
   - all relevant checks must pass before phase completion.

Do not mark a phase complete because files/classes exist. Mark it complete only when its behavioral exit criteria and tests pass.
