# ADR-019: Conclave Profile Lab Architecture Contract

**Status:** Accepted for implementation  
**Date:** 2026-10-03  
**Decision:** Dedicated internal macOS engineering application (`apps/profile_lab`) for the authoring, inspection, testing, validation, release, promotion, rollback, and revocation of Conclave Worker Tool Profiles.  
**Builds on:** [ADR-012](ADR-012-workspace-owned-local-workers.md), [ADR-013](ADR-013-desktop-auth-and-dual-transport.md), [ADR-015](ADR-015-first-party-worker-v1-contract.md), [ADR-018](ADR-018-generic-cli-worker-engine-and-tool-profiles.md)  
**Normative for:** Profile Lab (`apps/profile_lab`), Cloud Profile administration routes, and shared Profile/Engine runtime boundaries.

---

## 1. Context

Conclave Architecture v8 replaced provider-specific Worker executables with one generic CLI Worker Engine (`engines/cli_worker`) configured by signed, immutable Tool Profiles.

Provider CLI software (e.g., Codex CLI, Gemini CLI / Antigravity, Claude Code, and future CLI tools) evolves rapidly. Vendors frequently update command-line flags, probe commands, authentication handshakes, stdout/stderr output modes, JSON schemas, streaming events, and session resumption mechanics.

To maintain reliable local Worker execution across the Conclave ecosystem without repeatedly shipping new Conclave Workspace application releases, Conclave requires a specialized engineering and operations surface.

This tool is **Conclave Profile Lab**.

Profile Lab is an **internal macOS desktop application** used by Conclave engineers and operators to:
- create and maintain Logical Workers and Profile Definitions;
- author, edit, and validate Profile Drafts;
- locally test Draft Profiles directly against installed provider CLIs using the generic CLI Worker Engine;
- capture cryptographic test evidence bound to exact Profile payload digests;
- request immutable signed Profile releases;
- manage release lifecycle promotion (`Testing` → `Beta` → `Stable`), rollback, and revocation.

Profile Lab is an internal engineering tool, not a general end-user product.

---

## 2. Why desktop rather than web

Profile testing requires direct, unmediated interaction with vendor CLI binaries installed in the local operating system environment. A web application cannot:
1. discover locally installed provider CLI binaries across standard macOS paths and shell environments;
2. run low-latency passive and live probes against local CLI binaries;
3. execute the generic CLI Worker Engine out-of-process in a controlled local test sandbox;
4. inspect child-process exit codes, signals, process-tree lifecycles, and stream real-time stdout/stderr JSONL events;
5. verify local session creation, session resumption, cancellation, and timeout semantics against the actual provider CLI.

Because testing a Profile against real provider CLIs is a prerequisite for promoting a Profile release to normal Workspaces, Profile Lab must be a native desktop application.

Target platform: **macOS only** (Flutter desktop).  
Repository location: `apps/profile_lab/`.

Profile Lab maintains its own dedicated macOS bundle identifier, application support directory, logging namespace, secure credential namespace, preferences, and release workflows. It does not share application data directories with Conclave Workspace.

---

## 3. The Core Authority Chain

Do not treat a Logical Worker and a Tool Profile Release as the same entity. The system strictly separates stable product identity from declarative runtime implementation.

The authoritative relationship is:

```text
Worker Catalog (Logical Worker)
       ↓
Tool Profile Definition
       ↓
Tool Profile Release (immutable version)
       ↓
Generic CLI Worker Engine
       ↓
Provider CLI (local binary)
```

### Definitions:
- **Logical Worker (`worker_catalog`):** The stable, product-facing identity referenced by Conclave AX, Cloud, Workflows, Workstream bindings, permissions, scheduling, history, and inventory (e.g., `chatgpt`, `gemini`, `claude`).
- **Tool Profile Definition (`tool_profile_definitions`):** The specification of how a logical Worker is implemented across provider tools (e.g., `chatgpt-codex`, `gemini-antigravity`, `claude-code`). Each logical Worker references one active Profile Definition.
- **Tool Profile Release (`tool_profile_releases`):** An immutable, versioned, signed payload for a Profile Definition (e.g., `v12`, `v13`, `v14`).
- **Generic CLI Worker Engine:** The shared, provider-independent child-process supervisor and protocol bridge (`engines/cli_worker`).
- **Provider CLI:** The vendor-supplied executable installed on the user's workstation (`codex`, `agy`, `claude`).

### Dynamic Worker Architecture:
Workers are **never hardcoded** in Profile Lab, Workspace, or AX. Conclave Cloud is the sole authority for available Workers.

The application dynamically queries Cloud for catalog and Profile state:
- `worker_catalog`
- `tool_profile_definitions`
- `tool_profile_releases`
- `tool_profile_channel_pointers`
- `workspace_tool_profile_channels`

No conditional branch such as `if worker == 'chatgpt'` or `if worker == 'gemini'` is permitted for normal Worker lifecycle behavior. Adding a new Worker (such as `claude`) in Profile Lab makes it discoverable by Workspace and orchestratable by AX without modifying application source code.

Profile Lab must not keep a built-in list of provider executables. Local discovery derives executable names from the Worker catalog and loaded Tool Profiles, including Profile-declared executable candidates and standard locations. Provider session formats and resume arguments are Profile data; diagnostics and repair suggestions must not invent these settings from a provider name or a failed session scenario.

---

## 4. Product Boundaries: Profile Lab vs Workspace vs AX

The responsibilities of Conclave applications are strictly separated:

```text
+---------------------+      +---------------------+      +---------------------+
|     Conclave AX     |      |  Conclave Workspace |      | Conclave Profile Lab|
+---------------------+      +---------------------+      +---------------------+
| Human orchestration |      | Local Work Root &   |      | Profile engineering |
| Projects & Streams  |      | reliable execution  |      | Draft authoring     |
| Step bindings       |      | Admitted signed     |      | Local Engine testing|
| Worker selection    |      |   releases ONLY     |      | Validation & Diffing|
| Readiness display   |      | Enforces local auth |      | Promotion & Rollback|
| NO Profile editing  |      | NO Profile editing  |      | Revocation audit    |
+---------------------+      +---------------------+      +---------------------+
           \                            |                            /
            \                           |                           /
             +-----------------------------------------------------+
             |                    Conclave Cloud                   |
             | Authoritative state, Worker catalog, signing boundary|
             +-----------------------------------------------------+
```

### Invariant: Profile Lab is NOT a Workspace
Profile Lab must **never** behave like Conclave Workspace. Specifically, Profile Lab:
1. **MUST NOT** register itself as an execution Workspace via `/api/workspace-runtime/register`;
2. **MUST NOT** advertise local Workers to Cloud inventory or synchronize readiness slots;
3. **MUST NOT** receive Work assignments from the Cloud scheduler;
4. **MUST NOT** participate in Work scheduling or capacity allocation;
5. **MUST NOT** create Workstreams or own Project Work Roots;
6. **MUST NOT** execute normal AX Work Requests or expose local Workers to Projects.

The local Engine execution inside Profile Lab exists **exclusively for Profile candidate validation and testing**.

### Boundary Matrix:

| Capability | Conclave Profile Lab | Conclave Workspace | Conclave AX | Conclave Cloud |
| :--- | :--- | :--- | :--- | :--- |
| **Manage Worker Catalog** | Author / Administer | Read-only sync | Read-only display | Authoritative store |
| **Author / Edit Profiles** | Yes (Drafts) | Forbidden | Forbidden | Validates & stores |
| **Test Unsigned Local Drafts** | Yes (sandbox only) | Forbidden | Forbidden | Forbidden |
| **Verify Signed Profile Releases**| Yes | Yes (mandatory) | No | Signs upon publish |
| **Execute Normal Work Assignments**| Forbidden | Yes | Forbidden | Schedules |
| **Own Project Work Roots** | Forbidden | Yes | Forbidden | Metadata only |
| **Configure Step Bindings** | Forbidden | Forbidden | Yes | Stores & validates |
| **Manage Release Channels** | Yes (promote/rollback)| Forbidden | Forbidden | Updates pointers |
| **Revoke Profile Releases** | Yes (admin action) | Consumes blocklist | Forbidden | Enforces revocation |

---

## 5. Trust Boundary: Draft Candidates vs Admitted Signed Releases

A core architectural tenet of Architecture v8 is that production Workspaces accept only verified, admitted, signed Profile releases.

Profile Lab requires the capability to test an in-development, unreleased, unsigned Profile payload against the real CLI. This capability must **never** weaken the production trust path.

The architecture formally distinguishes:
- `SignedProfileRelease`: A cryptographically signed, immutable Profile payload admitted through Cloud verification. Conclave Workspace admits **only** this type.
- `LocalDraftProfileCandidate`: A mutable, unsigned, locally authored Profile configuration residing in Profile Lab.

The canonical state machine and promotion rules are specified in the [Tool Profile Lifecycle Specification](../specifications/TOOL_PROFILE_LIFECYCLE.md).

### Trust Invariants:
1. **Strict Sandbox Isolation:** A `LocalDraftProfileCandidate` may only execute within Profile Lab's dedicated test sandbox.
2. **No Admission to Production Caches:** A Draft Profile candidate must never enter the Workspace Tool Profile cache (`tool_profiles/`), the local Worker registry, or Cloud scheduling.
3. **Immutability of Published Releases:** Once published, a Profile Release is permanently frozen:
   - payload JSON;
   - release version number;
   - SHA-256 `payloadDigest`;
   - Worker identity;
   - Profile Definition identity;
   - engine family.
4. **Editing Creates Drafts:** Editing a published release (even Stable) never alters that release. It creates a new Draft candidate targeting the next sequential version (e.g., `Stable v12` → Edit → `Draft v13`).
5. **Channel Promotion Preserves Payloads:** Promoting a release (`Testing` → `Beta` → `Stable`) moves Cloud channel pointers. It does not alter a single bit of the Profile payload or digest.
6. **Rollback Moves Pointers:** Rolling back moves the channel pointer backward to an earlier known-good immutable release (e.g., `Stable: v18` → Rollback → `Stable: v17`).
7. **Revocation Forbids Execution:** Revocation permanently invalidates a release. Workspaces immediately reject and cease executing revoked Profile releases.

---

## 6. Provider Credential Invariants

Profile Lab adheres strictly to the repository security contract regarding AI provider credentials:

1. **Provider CLI Ownership:** Provider authentication remains owned entirely by the locally installed provider CLI (e.g., `codex login`, `agy auth login`, `claude login`).
2. **No Plaintext or Managed Provider Secrets:** Profile Lab **never** prompts for, accepts, displays, or stores provider credentials, API keys, session tokens, or account passwords (including OpenAI, Google, Anthropic, or other vendor keys).
3. **Passive and Live Inspection Only:** Profile Lab probes inspect only verifiable technical facts:
   - executable present on disk;
   - executable version satisfies compatibility range;
   - CLI reports authenticated status via passive probe (e.g. exit code 0 on config check);
   - CLI successfully executes a minimal bounded live probe prompt.
4. **Credential Isolation:** Profile Lab process execution isolates environments and explicitly forbids capturing or persisting provider credential caches into Profile Lab test evidence.

---

## 7. Profile Lab Authentication & Signing Architecture

### Human Authentication:
Profile Lab uses Conclave Cloud authentication via a browser-assisted desktop authentication flow similar to Conclave Workspace.

However, Profile Lab operates under a **dedicated administrative security audience**:
```text
conclave.profile-lab.management
```

Conclave Cloud validates that the authenticated human holds explicit Profile administration privileges:
- `profiles:admin`
- `profiles:release:manage`

Normal Conclave accounts and standard Workspace owner sessions are denied access to Profile Lab management endpoints.

### Signing Key Boundary:
Production Profile signing keys **MUST NEVER** be stored in, accessible to, or managed by Profile Lab.

The publication workflow delegates signing to a secure Cloud/CI signing boundary:
1. Profile Lab completes local testing and validates all test evidence against the candidate `payloadDigest`.
2. Profile Lab submits a publication request to Conclave Cloud containing the candidate payload and normalized test evidence.
3. Conclave Cloud validates the payload schema and requires release-manager authorization. Stable promotion, channel rollback, release revocation, and assignment to the Stable channel require fresh session-bound step-up authentication.
4. The isolated Cloud/CI signer signs the canonical payload digest with the production private key.
5. Cloud records the immutable `SignedProfileRelease` row and assigns it to the initial release stage (e.g., `Testing`).

---

## 8. Test Lifecycle and Evidence Binding

Profile Lab validates Profile candidates across a standardized 10-step verification lifecycle:
1. **Schema Validation:** Syntax, types, required fields, and unknown-property rejection against `Tool Profile v1`.
2. **Engine Compatibility:** Verifies the generic CLI Worker Engine version matches engine family constraints.
3. **Executable Discovery:** Locates the provider CLI binary using defined candidate paths and search rules.
4. **Provider Version Detection:** Executes version command and extracts normalized semver.
5. **Passive Probe:** Evaluates non-interactive auth/readiness checks without invoking model inference.
6. **Live Probe:** Executes a minimal, bounded inference prompt to verify live model round-tripping.
7. **Controlled Execution Test:** Verifies stdout/stderr streaming, JSONL event extraction, and output limits.
8. **Session Creation Test:** Asserts provider session ID extraction from live execution.
9. **Session Resume Test:** Asserts resumption of an existing session using configured resume arguments.
10. **Failure & Cancellation Test:** Asserts process termination, timeout handling, and normalized error mapping.

Passive Probe and Live Probe are stages within the full acceptance ladder, not standalone actions. Profile Lab exposes only the full ladder until isolated probe execution is implemented, so a probe label cannot trigger the remaining stages implicitly.

### Cryptographic Evidence Invariant:
Every test run generates a structured evidence record bound to the exact SHA-256 `payloadDigest` of the tested Profile:

```text
{
  "profileDefinitionId": "chatgpt-codex",
  "candidateVersion": 18,
  "payloadDigest": "sha256:7f83b165...",
  "engineVersion": "1.2.0",
  "providerCli": "codex",
  "providerVersion": "0.187.1",
  "os": "macOS 15.0",
  "profileLabVersion": "0.1.0",
  "timestamp": "2026-10-03T00:30:00Z",
  "testResults": { ... }
}
```

If the Profile payload is edited in Profile Lab, its SHA-256 `payloadDigest` changes immediately. All existing test evidence is automatically marked **STALE**. A Profile cannot be submitted for publication or promoted with stale or missing evidence. Detailed promotion criteria and the complete evidence schema are governed by the [Tool Profile Evidence-Bound Promotion Contract](../specifications/TOOL_PROFILE_EVIDENCE_CONTRACT.md).

### Evidence Sanitization:
Local evidence logs remain on the operator's machine. Evidence synchronized to Cloud for audit and promotion gates is strictly sanitized:
- environment variables are stripped;
- local filesystem home directories are normalized or redacted;
- raw authentication tokens are excluded;
- unbounded stdout/stderr streams are truncated to normalized diagnostic codes.

---

## 9. Shared Runtime Architecture & Parallel Development

Profile Lab and Conclave Workspace must execute identical low-level process and engine behavior. To prevent code duplication and runtime divergence, low-level engine invocation primitives are shared:
- Profile JSON parsing and schema validation;
- CLI Worker Engine process supervisor;
- Provider CLI discovery and version extraction;
- Local Worker Protocol 4.0 framing;
- Passive and live probe interpretation;
- Diagnostic error normalization.

### Distinct Trust Gate:
While the underlying engine library is shared, the trust gate is strictly segregated:
- Workspace requires a valid cryptographic signature and verified Cloud channel pointer before execution.
- Profile Lab allows explicit execution of an unsigned `LocalDraftProfileCandidate` within its isolated test sandbox.

### Parallel Development Discipline:
Dynamic Worker loading and Workspace readiness reconciliation are actively being refined in `apps/workspace` and `apps/app`. To preserve stability:
- Profile Lab development proceeds initially in `apps/profile_lab/` and dedicated Cloud administrative routes;
- Existing Workspace Worker loading, scheduling, and AX Worker selectors must remain untouched during initial Profile Lab scaffolding;
- Extraction of shared engine packages and draft execution integration takes place after dynamic Worker contracts stabilize.

---

## 10. Consequences

### Positive:
- **No Workspace App Releases for CLI Updates:** Provider CLI updates (e.g. Codex or Claude changing arguments) are resolved by releasing an updated Tool Profile via Profile Lab without deploying a new Workspace binary.
- **Dynamic Extensibility:** New Workers (e.g., Claude) can be defined, tested against local binaries, published, and promoted dynamically.
- **Zero Provider Credential Risk:** Conclave continues to avoid handling or persisting third-party AI provider credentials.
- **Cryptographic Promotion Assurance:** Workspaces only execute Profiles that have undergone verified local testing and secure Cloud signing.
- **Clean Architectural Separation:** Profile Lab owns complexity; Workspace owns reliable local execution; AX owns orchestration; Cloud owns authoritative state.

### Negative / Trade-offs:
- Requires maintaining a dedicated Flutter desktop application for internal engineering operations.
- Operators must have locally installed provider CLIs on their macOS machines to run live test suites.
- Cloud must maintain administrative authorization policies and isolated signing infrastructure for Profile releases.

---

## 11. Human Authentication & Boundary Isolation (Phase 6)

Profile Lab reuses Conclave's browser-assisted human sign-in pattern (intents, approval URL, polling, claiming, session rotation, revocation), but enforces an explicit and distinct security boundary:

1. **Dedicated Audience (`conclave.profile-lab.management`):**
   - Profile Lab auth intents declare `audience: 'conclave.profile-lab.management'` and `clientName: 'Conclave Profile Lab'`.
   - Resulting desktop sessions are permanently tagged with this audience.
   - Normal Workspace sessions use `conclave.desktop.management`.

2. **Cloud Authorization Gates:**
   - Profile administrative endpoints (`/api/profile-admin/*`, `/api/profiles/*`, `/api/releases/*`) require permissions `profiles:admin` and `profiles:release:manage`.
   - When accessed by a desktop client, `authorizeProfileAdmin` strictly requires `context.audience === 'conclave.profile-lab.management'`.
   - Catalog and draft administration requires `CONCLAVE_PROFILE_ADMIN_USER_IDS`; publication and rollout management requires the separate `CONCLAVE_PROFILE_RELEASE_MANAGER_USER_IDS` allowlist.

3. **Mutual Exclusion:**
   - A normal Workspace session token (`conclave.desktop.management`) presented to Profile administrative endpoints is rejected with HTTP 403.
   - A Profile Lab session token (`conclave.profile-lab.management`) presented to Workspace registration or runtime endpoints is rejected with HTTP 403.
   - Workspace credentials and Profile Lab credentials cannot be interchanged or accidentally escalated.

4. **Isolated Local Credential Namespace:**
   - Profile Lab stores active sessions in the macOS login Keychain under the `com.conclaveax.profile-lab` service.
   - Keychain session envelopes include the normalized Cloud origin. A session is loaded only for that same origin; changing origins clears the local session. Legacy sessions that lack origin binding are discarded and their plaintext files removed.
   - Profile Lab never interacts with Workspace's Keychain namespace, installation IDs, or local database state.

### Cloud Origin Configuration:
Profile Lab's build default is `https://app.conclaveax.com`; `CONCLAVE_CLOUD_URL` can set an environment-specific build default. A local development build may use `http://localhost:8787`. The Cloud connection settings persist an origin override and can reset it to the build default. Every HTTP client requires an origin-only URL and permits plaintext HTTP only for loopback in non-release builds.

---

## 12. Profile Admin Cloud API Contract (Phase 7)

Profile Lab interacts with Conclave Cloud exclusively via bounded HTTP/JSON endpoints. **Profile Lab never connects directly to Cloudflare D1 or runs raw SQL queries.** All persistence, validation, immutability triggers, and audit logging remain owned by Cloud routes.

Every administrative endpoint is guarded by `authorizeToolProfileAdmin(request, env, ctx)`, which enforces:
1. A valid authenticated user in the allowlist for the required permission: `CONCLAVE_PROFILE_ADMIN_USER_IDS` for administration or `CONCLAVE_PROFILE_RELEASE_MANAGER_USER_IDS` for release management.
2. Required permissions (`profiles:admin` or `profiles:release:manage`).
3. The dedicated desktop audience `conclave.profile-lab.management`.

Stable promotion, Stable channel assignment, release revocation, and channel rollback additionally require a fresh session-bound passkey step-up (five-minute maximum age). The desktop session binds a browser-completed passkey ceremony through `POST /api/desktop-auth/profile-lab/step-up/complete`; stale ceremonies are rejected. Missing or stale step-up proof returns HTTP 428. Publication and other release-manager actions require `profiles:release:manage` but do not require step-up.

Profile Lab execution creates unique scratch directories under its dedicated sandbox root. The root and run directory must be real directories contained at the expected path. Active Engine assignments are cancelled and the supervisor is disposed during teardown; cleanup errors are surfaced and prevent a passing ladder result.

### Administrative Read and Write Endpoints:

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/admin/workers/catalog` | Complete administrative view of all logical workers (all visibility states, lifecycle states, release stages, capabilities, sort order, and active profile definition). |
| `POST` | `/api/admin/workers/catalog` | Atomically creates an approved logical worker catalog entry and its active Tool Profile definition. |
| `GET` | `/api/admin/tool-profiles/definitions` | Lists all profile definitions with associated worker info, channel pointers (`stable`, `beta`, `testing`), latest release version, and release counts. |
| `GET` | `/api/admin/tool-profiles/definitions/:profileDefinitionId` | Detailed single definition lookup with active channel pointers and release stats. |
| `POST` | `/api/admin/tool-profiles/definitions` | Creates a new Tool Profile definition linked to an existing logical worker. |
| `GET` | `/api/admin/tool-profiles/:profileDefinitionId/releases` | Lists all releases for a definition (up to 100, newest first) with metadata, digest, signature, and latest acceptance evidence. |
| `GET` | `/api/admin/tool-profiles/:profileDefinitionId/releases/:version` | Retrieves a single release by version including parsed Tool Profile v1 payload and verification metadata. |
| `POST` | `/api/admin/tool-profiles/:profileDefinitionId/releases` | Creates a new draft release version with strict schema and credential-leak validation. |
| `PUT` | `/api/admin/tool-profiles/:profileDefinitionId/releases/:version/draft` | Updates the payload of an unreleased draft version (recomputing `payloadDigest`); accepts the quoted base SHA-256 digest in `If-Match` for optimistic concurrency. |
| `POST` | `/api/admin/tool-profiles/:profileDefinitionId/releases/:version/publish` | Freezes and cryptographically signs a draft release, transitioning it to `testing`. Payload becomes immutable. |
| `POST` | `/api/admin/tool-profiles/:profileDefinitionId/releases/:version/promote` | Promotes a release into `beta` or `stable`. Promoting to `stable` requires a complete Cloud-validated acceptance contract bound to the exact payload digest. |
| `POST` | `/api/admin/tool-profiles/:profileDefinitionId/releases/:version/retire` | Retires a release (must not be targeted by an active channel pointer). |
| `POST` | `/api/admin/tool-profiles/:profileDefinitionId/releases/:version/revoke` | Revokes a release immediately and clears any channel pointers targeting it via DB triggers. |
| `GET` | `/api/admin/tool-profiles/channels` | Lists all active channel pointers across all profile definitions. |
| `GET` | `/api/admin/tool-profiles/:profileDefinitionId/channels` | Lists active channel pointers for a specific profile definition. |
| `POST` | `/api/admin/tool-profiles/:profileDefinitionId/channels/:channel/rollback` | Rolls back a channel pointer to an earlier valid release version without altering immutable release payloads. |
| `GET` | `/api/admin/tool-profiles/:profileDefinitionId/releases/:version/evidence` | Lists acceptance evidence records submitted for a specific release version. |
| `POST` | `/api/admin/tool-profiles/:profileDefinitionId/releases/:version/evidence` | Submits acceptance evidence, validating that `profileDigest` matches the immutable release `payloadDigest`. |
| `GET` | `/api/admin/tool-profiles/:profileDefinitionId/releases/:version/audit` | Retrieves lifecycle and pointer audit events for a specific release version. |
| `GET` | `/api/admin/tool-profiles/:profileDefinitionId/audit` | Retrieves all audit events for a profile definition across all release versions. |
| `GET` | `/api/admin/tool-profiles/audit` | Retrieves global profile administrative audit trail. |

### Evidence and Rollback Invariants:
- **Evidence Binding:** Acceptance evidence submitted to Cloud is cryptographically checked against the target release's canonical SHA-256 `payloadDigest`. Stale evidence produced from prior edits is rejected. Evidence records are immutable and cannot be updated or deleted once submitted.
- **Non-Destructive Rollback:** Rollback updates the pointer in `tool_profile_channel_pointers` to target an earlier published release. The release records themselves are never edited. The database trigger `tool_profile_channel_update_audit` automatically logs a `stable_rollback` event to `tool_profile_release_audit`.

---

## 8. Manual Profile Lifecycle Acceptance & AI Maintenance Boundary

### Manual Lifecycle Acceptance Decision:
**Manual Profile lifecycle: COMPLETE** for the implemented control path. Profile Lab and Cloud provide Worker/Profile creation, local Draft editing and Engine-backed qualification, signed publication, channel promotion, rollback, and revocation. Fixture acceptance verifies dynamic Workspace discovery and Work execution through AX without Worker-specific source changes. Publication and Stable promotion require separately stored Cloud qualification and acceptance record IDs.

This status does not mean Cloud cryptographically attests that a local provider CLI executed the submitted evidence scenarios. Cloud validates the authenticated contract's identity, payload digest, version ranges, freshness, and capability-derived scenario map, then stores it immutably. Real-provider coverage and deployed Testing Workspace rollout are tracked independently in the acceptance records. See the [evidence contract](../specifications/TOOL_PROFILE_EVIDENCE_CONTRACT.md) for these limits.

### AI Maintenance Boundary:
Autonomous AI agents are permitted to participate in Profile maintenance **only** by generating and proposing candidate Draft Profile revisions within this verified manual framework:
- Conclave owns persistent state and enforces strict schema validation and signature checks.
- Model-backed proposals run through the generic CLI Worker Engine using a Cloud-selected Stable Worker Profile whose signature and revocation state Profile Lab verifies. The unsigned target Draft is never used as the model runner.
- The operator explicitly consents before Draft content and bounded diagnostics are sent to the selected provider CLI. Provider credentials remain under local CLI ownership and are never collected by Profile Lab.
- Model output must validate as a Tool Profile and preserve Worker, Profile, release version, and provider identity. Profile Lab presents a diff and requires an explicit human review-and-apply action; proposal provenance is kept in local Draft metadata.
- AI proposals modify only local Draft state. Qualification, publication, signing, Stable promotion, rollback, and revocation remain separate human-controlled workflows with their existing Cloud authorization and step-up checks.
- Uncontrolled AI release authority is strictly prohibited.
