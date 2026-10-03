# Profile Lab Specification

**Status:** Architecture v8 normative specification  
**Architecture:** [Architecture v8](../architecture/ARCHITECTURE_V8.md)  
**Decision:** [ADR-019](../decisions/ADR-019-conclave-profile-lab.md)  
**Implementation:** `apps/profile_lab`  

---

## 1. Executive Summary

Conclave Profile Lab is an internal macOS desktop application (`apps/profile_lab`) dedicated to authoring, validating, sandbox testing, publishing, promoting, rolling back, and revoking Conclave Tool Profiles and Logical Workers.

Under Architecture v8, provider-specific Worker executables are replaced by one generic CLI Worker Engine (`engines/cli_worker`) configured by signed, immutable Tool Profiles. Vendor CLI tools evolve rapidly. Profile Lab is the operational control surface that enables engineers and maintainers to keep provider CLI integrations up to date without releasing new Workspace application binaries.

---

## 2. Product Boundaries & Architecture Surfaces

Conclave enforces a strict separation across four distinct product surfaces:

```text
+-----------------------+      +-----------------------+      +-----------------------+
|      Conclave AX      |      |   Conclave Workspace  |      |  Conclave Profile Lab |
+-----------------------+      +-----------------------+      +-----------------------+
| Human orchestration   |      | Local Work Root &     |      | Profile engineering   |
| Projects & Workstreams|      | reliable execution    |      | Draft authoring       |
| Step bindings         |      | Admitted signed       |      | Sandbox testing       |
| Worker selection      |      | releases ONLY         |      | Evidence & promotion  |
+-----------------------+      +-----------------------+      +-----------------------+
           \                               |                             /
            \                              |                            /
             +---------------------------------------------------------+
             |                     Conclave Cloud                      |
             | Authoritative state, Worker catalog, signing boundary   |
             +---------------------------------------------------------+
```

### Boundary Rules:
1. **Conclave AX:** Web application for human project orchestration. Displays catalog workers and local readiness. Exposes zero profile editing or administration.
2. **Conclave Cloud:** Multi-tenant authoritative backend. Manages `worker_catalog`, `tool_profile_definitions`, `tool_profile_releases`, release channels, and Ed25519 cryptographic signatures. Executes zero provider tools.
3. **Conclave Workspace:** Background-first native desktop machine runtime. Manages local Work Roots, process tree execution, and local worker readiness. Consumes **only** cryptographically signed, admitted Tool Profile Releases.
4. **Conclave Profile Lab:** Administrative desktop engineering application. Authors and tests unsigned local Draft Profile candidates against installed provider CLIs in an isolated sandbox. Exposes full release lifecycle management. **Never registers as an execution Workspace, never accepts Work assignments, and never owns Project Work Roots.**

---

## 3. The Core Authority Chain

Logical Worker product identity is strictly decoupled from versioned implementation profiles:

```text
Worker Catalog (`worker_catalog`)
       ↓
Tool Profile Definition (`tool_profile_definitions`)
       ↓
Tool Profile Release (`tool_profile_releases`)
       ↓
Generic CLI Worker Engine (`engines/cli_worker`)
       ↓
Provider CLI (local executable binary)
```

No Worker identity (such as `chatgpt` or `gemini`) is hardcoded in Profile Lab, Workspace, or AX. Conclave Cloud is the sole authority for catalog descriptors and profile bindings. Adding a new Worker in Profile Lab makes it discoverable by Workspaces and selectable in AX without application redeployment or code modifications.

---

## 4. Draft Authoring & Sandbox Testing

Profile Lab allows engineers to author and iteratively refine Draft Profiles before requesting a signed release:

- **Local Draft Store (`DraftProfileStore`):** Persists draft configurations locally under Profile Lab's dedicated application support directory (`~/Library/Application Support/conclave_profile_lab/drafts/`).
- **Unsigned Draft Candidate (`LocalDraftProfileCandidate`):** Implements `ToolProfileCandidate` with `isSigned => false`. Unsigned drafts are strictly barred from entering Workspace's trusted profile store (`ToolProfileReleaseStore`).
- **Sandbox Test Supervisor:** Uses `PlatformProcessSupervisor` from `conclave_cli_worker_runtime` to run tests out of process with hard execution deadlines, process tree cleanup, and secret redaction (`SafeProviderDiagnostics`).
- **Probe Suite:**
  - **Passive Probe:** Validates binary existence, version allowance, and zero-prompt execution.
  - **Live Probe:** Executes a bounded test prompt against the installed CLI to verify stdout/stderr stream parsing, event rules, and exit status.
  - **Session Test:** Verifies session creation, session resumption (`resume` pattern), and multi-turn state retention.

---

## 5. Cryptographic Evidence & Release Publication

To publish a Draft Profile as a signed release, Profile Lab captures evidence bound to the exact payload SHA-256 digest:

1. **Evidence Contract (`ToolProfileEvidenceContract`):** Collects binary paths, exact CLI version strings, passive probe results, live probe outputs, and diagnostic session status.
2. **Digest Invalidation:** Any mutation to a Draft Profile payload changes its SHA-256 `payloadDigest` and invalidates all previously gathered test evidence.
3. **Cloud Admin API (`POST /api/admin/workers/definitions/:id/releases`):** Submits the draft JSON payload and verified test evidence artifact.
4. **Cloud Signing Boundary:** Cloud verifies administrative scope (`profiles:admin`), checks payload schema, validates evidence completeness, and signs the release using Cloud's Ed25519 private key.
5. **Signed Admission (`ToolProfileReleaseAdmission`):** Returned to clients with `isSigned => true`. Production Workspaces load and verify these signed releases using public keys (`ReleaseTrustRoots`).

---

## 6. Release Lifecycle & Channel Promotion

Profile releases move through a controlled lifecycle managed via Profile Lab:

```text
Local Draft → Published Release → Testing Channel → Beta Channel → Stable Channel
                                        |                |
                                     Rollback         Revocation
```

- **Channel Pointers:** Cloud maintains channel pointers (`workspace_tool_profile_channels`) pointing to release versions (`testing`, `beta`, `stable`).
- **Channel Promotion:** Promoting a release moves a pointer forward. The underlying profile payload and signature remain 100% immutable.
- **Rollback:** Pointing a channel backward to an earlier immutable release version instantly restores a known-good configuration.
- **Revocation:** Marking a release as revoked (`revoked_at` timestamp) causes Cloud and Workspaces to immediately refuse execution for that release version across all channels.

---

## 7. AI Repair Loop & Provenance Tracking

Profile Lab supports an iterative AI-assisted repair loop for Profile maintenance:

1. **Iteration Workflow:** Generate candidate → Validate JSON schema → Run local probe suite → Normalize failure log → Prompt AI for revision → Display diff → Retest.
2. **Iteration Ceilings:** Automatically caps iterations (default: 3) and requires explicit human confirmation before applying material changes.
3. **AI Provenance Model:** Every draft records:
   - Creator/Modifier origin (`human` vs `ai`);
   - AI model and provider identifier (e.g. `gpt-4o`, `claude-3-5-sonnet`);
   - Parent release version and digest;
   - Prompt/task reference;
   - Resulting diff digest.

Audit records provide clear operational history (e.g. *"Draft v20 created by AI-assisted change, reviewed by Vitalii, tested on Codex 0.188.0, published by controlled signer, promoted to Testing by Vitalii"*).

---

## 8. Security Ceilings & Architecture Guards

Profile Lab enforces strict security boundaries verified by automated repository guards (`verify-v8-architecture.mjs`):

1. **Zero Direct D1 Access:** Profile Lab communicates exclusively via HTTPS REST endpoints (`ProfileAdminApiClient`). Direct database bindings (`D1Database`, raw SQL) are strictly prohibited.
2. **Zero Signing Seeds:** Signing private key seeds (`CONCLAVE_WORKSPACE_ED25519_SEED`, `Ed25519PrivateKey`) are forbidden in Profile Lab code. Signature generation belongs solely to Cloud.
3. **Secret Redaction:** Test output logs and diagnostic summaries undergo strict secret redaction preventing provider keys or desktop tokens from being stored in logs or evidence artifacts.
4. **Process Isolation:** Provider CLI processes run under bounded deadlines with full process tree termination upon completion or cancellation.

---

## 9. Manual Profile Lifecycle Completion & Autonomous AI Maintenance Governance

### Acceptance Declaration
The **manual Profile lifecycle is declared complete** and verified across all operational surfaces.

### Human Acceptance Threshold:
Before autonomous AI profile maintenance is permitted, the manual Profile Lab control path must satisfy the following acceptance threshold without exception:

1. **Human Creation:** A human operator can create a completely new Logical Worker (`worker_catalog`) and Tool Profile Definition (`tool_profile_definitions`) via Profile Lab and Cloud admin REST APIs.
2. **Local Real CLI Testing:** A human operator can author an initial Draft Profile payload and execute passive probes, live probes, and diagnostic session tests directly against a real local CLI binary installed on macOS.
3. **Cryptographic Release Publication:** Profile Lab captures verified test evidence (`ToolProfileEvidenceContract`), computes the exact payload digest, and requests an Ed25519-signed release from Cloud (`POST /api/admin/workers/definitions/:id/releases`).
4. **Channel Promotion & Rollback:** The release can be promoted through channels (`testing` → `beta` → `stable`), rolled back to an earlier immutable version, or revoked (`revoked_at` blocklist enforcement).
5. **Dynamic Discovery:** Conclave Workspace and Conclave AX dynamically discover the new Worker, report inventory, display readiness, and execute Workstream steps **without editing or redeploying application source code**.

### Autonomous AI Maintenance Boundary:
Autonomous AI agents may propose draft modifications, analyze failure logs, and suggest profile updates **only** within the bounds of this verified manual lifecycle:
- AI models propose state changes by generating draft candidate JSON payloads.
- Conclave owns persistent state, validates JSON schemas against `TOOL_PROFILE_LIMITS`, and enforces signature verification.
- Material profile changes require explicit human review and confirmation before release publication.
- Autonomous background tasks must never be given uncontrolled release publishing or channel promotion authority.

