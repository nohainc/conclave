# Tool Profile Evidence-Bound Promotion Contract

**Status:** Canonical Architecture v8 Promotion & Evidence Specification  
**Decisions:** [ADR-018](../decisions/ADR-018-generic-cli-worker-engine-and-tool-profiles.md), [ADR-019](../decisions/ADR-019-conclave-profile-lab.md)  
**Lifecycle Contract:** [Tool Profile Lifecycle](TOOL_PROFILE_LIFECYCLE.md)  
**Authority:** Cloud Acceptance Validator (`apps/cloud/src/tool-profile-validation.ts`) & D1 Evidence Store (`tool_profile_acceptance_evidence`)

---

## 1. Motivation & Problem Statement

In automated, AI-assisted, and distributed engineering workflows, claims such as *"tests passed"* or *"verified for release v19"* cannot be trusted without cryptographic proof.

If testing evidence were associated merely with a human-readable identifier (such as `chatgpt-codex v19`):
1. An operator or AI model could run tests on candidate $A$, then modify a single argument or timeout value to produce candidate $B$, and promote candidate $B$ without re-testing.
2. An autonomous AI repair loop could iterate through multiple patches, conflate test results across iterations, and promote a candidate whose actual payload never passed live testing.
3. A malicious or erroneous actor could submit fabricated or stale test output.

To guarantee that **only the exact byte sequence that was tested can ever be published or promoted**, Conclave enforces **evidence-bound promotion**.

---

## 2. The Identity Triplet & Payload Digest

Every piece of testing evidence must be permanently bound to an immutable **Identity Triplet**:

```text
( profileDefinitionId, releaseVersion, payloadDigest )
```

### 2.1 Canonical Payload Serialization
Before computing the cryptographic digest, the Profile payload must be normalized into its canonical JSON form:
1. **Key Sorting:** Object keys are sorted lexicographically at every nesting depth.
2. **Whitespace:** Compact representation without pretty-printing indentations or trailing whitespace.
3. **Encoding:** Strict UTF-8 character encoding.
4. **Implementation:** Governed by `canonicalReleaseJson()` in `apps/cloud/src/release-trust.ts`.

### 2.2 Canonical Payload Digest Calculation
The canonical digest is the SHA-256 cryptographic hash of the canonical payload bytes:

$$\text{payloadDigest} = \text{SHA-256}(\text{canonicalPayloadJson})$$

Format:
- Exact 64 lowercase hexadecimal characters (e.g. `7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069`).
- Enforced at the database layer via:
  ```sql
  payload_digest TEXT NOT NULL CHECK (length(payload_digest) = 64)
  ```

---

## 3. The Evidence Staleness Invariant

> **The Single-Byte Invariant:**  
> If even a single byte of a draft Profile payload changes, its canonical `payloadDigest` changes immediately and irrevocably. Any prior test evidence referencing the previous digest is automatically classified as **`STALE`**.

```text
Draft v19 (Payload A)
  digest: 7f83b1...
  Test Suite: ALL PASSED (evidence bound to 7f83b1...)
       |
  Edit 1 byte (e.g., timeout changed from 30 to 60)
       |
       v
Draft v19 (Payload B)
  digest: a4e892...
  Prior Evidence Status: STALE (bound to 7f83b1..., expected a4e892...)
  Promotion Status: BLOCKED until test suite re-runs on a4e892...
```

### Staleness Rules:
1. **Zero Re-use across Edits:** Profile Lab must immediately flag all previous scenario results as `STALE` the instant the editor buffer is modified.
2. **Publication Blocker:** Conclave Cloud rejects any `publishDraftToolProfileRelease` call where the submitted test evidence digest does not exactly match the database draft `payload_digest`.
3. **Promotion Blocker:** Conclave Cloud rejects any `promoteToolProfileRelease` call to `stable` where the acceptance evidence `profileDigest` does not match the release record `payload_digest`.

---

## 4. Normalized Evidence Schema

Every testing scenario executed in Profile Lab or in a certified test runner must produce a structured evidence record adhering to this schema:

```json
{
  "formatVersion": 1,
  "profileDefinitionId": "chatgpt-codex",
  "releaseVersion": 19,
  "profileReleaseVersion": "19",
  "logicalWorkerTypeId": "chatgpt",
  "payloadDigest": "7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069",
  "engineVersion": "1.2.0",
  "providerToolName": "codex",
  "providerToolVersion": "0.187.1",
  "profileLabVersion": "0.1.0",
  "hostEnvironment": {
    "os": "macOS",
    "osVersion": "15.0.1",
    "kernelVersion": "Darwin 24.0.0",
    "architecture": "arm64"
  },
  "testRun": {
    "testType": "local_sandbox_suite",
    "startedAt": "2026-10-03T00:30:00.000Z",
    "completedAt": "2026-10-03T00:30:15.240Z",
    "durationMs": 15240,
    "overallResult": "passed"
  },
  "scenarios": {
    "schema_validation": {
      "result": "passed",
      "durationMs": 12,
      "issueCode": "NONE"
    },
    "engine_compatibility": {
      "result": "passed",
      "durationMs": 5,
      "issueCode": "NONE"
    },
    "executable_discovery": {
      "result": "passed",
      "durationMs": 45,
      "issueCode": "NONE",
      "discoveredPath": "/usr/local/bin/codex"
    },
    "provider_version_detection": {
      "result": "passed",
      "durationMs": 180,
      "detectedVersion": "0.187.1",
      "issueCode": "NONE"
    },
    "passive_probe": {
      "result": "passed",
      "durationMs": 320,
      "issueCode": "NONE"
    },
    "live_probe": {
      "result": "passed",
      "durationMs": 2150,
      "issueCode": "NONE"
    },
    "controlled_execution": {
      "result": "passed",
      "durationMs": 3400,
      "issueCode": "NONE"
    },
    "session_create": {
      "result": "passed",
      "durationMs": 2800,
      "issueCode": "NONE"
    },
    "session_resume": {
      "result": "passed",
      "durationMs": 3100,
      "issueCode": "NONE"
    },
    "cancellation_and_timeout": {
      "result": "passed",
      "durationMs": 3228,
      "issueCode": "NONE"
    }
  },
  "provenance": {
    "authorType": "human",
    "actorUserId": "usr_991823ab",
    "aiModelId": null,
    "sourceReleaseDigest": "6b21c45..."
  }
}
```

### 4.1 Required Metadata Attributes:

| Field | Type | Description |
| :--- | :--- | :--- |
| `formatVersion` | `1` | Schema version of the evidence format. |
| `profileDefinitionId` | `string` | Target Profile Definition identifier (e.g. `chatgpt-codex`). |
| `releaseVersion` | `integer` | Target integer release version (e.g. `19`). |
| `payloadDigest` | `string` | Exact 64-character SHA-256 hash of the canonical payload. |
| `logicalWorkerTypeId` | `string` | Logical worker identity (e.g. `chatgpt`). |
| `engineVersion` | `string` | Semver of the CLI Worker Engine used during testing. |
| `providerToolName` | `string` | Binary name of the provider CLI (e.g. `codex`). |
| `providerToolVersion`| `string` | Semver of the installed provider CLI tool tested against. |
| `profileLabVersion` | `string` | Version of the Profile Lab desktop application. |
| `hostEnvironment.os`| `string` | Operating system (`macOS`). |
| `hostEnvironment.osVersion`| `string` | macOS version string (e.g. `15.0.1`). |
| `testRun.startedAt` | `ISO 8601` | Precise UTC start timestamp. |
| `testRun.completedAt`| `ISO 8601` | Precise UTC completion timestamp. |
| `testRun.durationMs`| `integer` | Total test execution duration in milliseconds. |
| `testRun.overallResult`| `enum` | Normalized result: `"passed"` or `"failed"`. |
| `scenarios` | `map` | Breakdown of individual test scenarios and results. |
| `provenance` | `object` | Author provenance (`human`, `ai_generated`, `ai_assisted`). |

---

## 5. Normalized Issue Codes

When tests fail or encounter warnings, errors must be mapped to normalized issue codes rather than dumping raw, variable terminal strings:

| Issue Code | Category | Meaning |
| :--- | :--- | :--- |
| `NONE` | Success | Scenario completed successfully. |
| `SCHEMA_VIOLATION` | Static Validation | Payload fails JSON Schema or exceeds machine bounds. |
| `ENGINE_INCOMPATIBLE`| Engine Compatibility| Installed CLI Worker Engine is outside supported semver range. |
| `CLI_NOT_FOUND` | Discovery | Provider executable candidates could not be located on disk. |
| `CLI_VERSION_UNSUPPORTED`| Version | Detected provider CLI version is outside supported version range. |
| `AUTH_PROBE_FAILED` | Passive Probe | Provider CLI is not logged in or passive check failed. |
| `LIVE_PROBE_FAILED` | Live Probe | Live model inference ping failed or returned provider error. |
| `PARSE_ERROR` | Execution | Engine could not parse provider output / stream events. |
| `SESSION_START_FAILED`| Sessions | Provider CLI failed to emit a valid session identifier. |
| `SESSION_RESUME_FAILED`| Sessions | Resuming existing session failed or started fresh session. |
| `TIMEOUT_EXPIRED` | Timing | Process exceeded the configured test deadline. |
| `PROCESS_LEAK` | Process Safety | Child process did not terminate cleanly upon cancellation. |

---

## 6. Promotion Gates and Evidence Validation

Promotion through the lifecycle channels requires meeting specific evidence criteria:

```text
[ Draft Candidate ]
       |
       | Local Sandbox Test Suite
       v
+-------------------------------+
| Gate 1: Publish to Testing    | ---> Requires 100% pass on all 10 local sandbox scenarios
+-------------------------------+      bound to payloadDigest
       |
       v
[ Testing Channel ]
       |
       | Multi-Workspace Canary
       v
+-------------------------------+
| Gate 2: Promote to Beta       | ---> Requires testing channel verification & operator authorization
+-------------------------------+
       |
       v
[ Beta Channel ]
       |
       | Full Real-Provider Acceptance Suite
       v
+-------------------------------+
| Gate 3: Promote to Stable     | ---> Strictly requires complete acceptance evidence artifact:
+-------------------------------+      - payloadDigest match
                                       - engineVersion within supported range
                                       - providerToolVersion within supported range
                                       - acceptedAt within 90 days
                                       - all required acceptance scenarios "passed"
                                       - explicit human confirmation
```

### Gate 3: Stable Promotion Validation Invariants
As enforced by `validateToolProfileAcceptanceEvidence()` in `apps/cloud/src/tool-profile-validation.ts`:
1. **Digest Equality:** `evidence.profileDigest === release.payload_digest`.
2. **Identity Alignment:** Definition ID, release version, and logical worker type must match the database record.
3. **Engine Range Inclusion:** `evidence.engineVersion` must fall within `profile.engineCompatibility` range `[min, maxExclusive)`.
4. **Tool Range Inclusion:** `evidence.providerToolVersion` must fall within one of `profile.providerTool.supportedVersions` ranges.
5. **Freshness:** `acceptedAt` timestamp must not be in the future (within clock skew) and must be $\le 90\text{ days}$ old.
6. **Required Scenarios Passed:** Every scenario in `requiredAcceptanceScenarios` must have status `"passed"`:
   - `passive_probe`
   - `live_probe`
   - `representative_workstream_write`
   - `durable_session_start`
   - `durable_session_resume`
   - `cancellation`
   - `timeout`
7. **Database Persistence:** Evidence is stored immutably in `tool_profile_acceptance_evidence` upon successful promotion.

---

## 7. AI Automation Invariants

When AI models participate in Profile maintenance (e.g. self-healing Profiles when a provider CLI updates):

1. **No Evidence Spoofing:** An AI agent cannot manufacture evidence. The evidence must be generated by the Profile Lab test sandbox or controlled acceptance runner executing the real provider CLI process.
2. **Automatic Staleness on AI Edits:** When an AI model applies a patch to a draft Profile, the `payloadDigest` changes. Any previous test evidence gathered by the AI model on prior iterations is rendered `STALE`.
3. **Closed-Loop AI Verification:** An automated AI repair cycle must follow:
   $$\text{Failing Test} \longrightarrow \text{AI Generates Draft Patch} \longrightarrow \text{Re-calculate Digest} \longrightarrow \text{Run Sandbox Tests} \longrightarrow \text{Digest-Bound Evidence Recorded}$$
4. **Immutable Audit Record:** Cloud audit tables capture the AI model name, prompt hash, and parent release digest to guarantee complete traceability.
