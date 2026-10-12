# Worker Profile V9

**Status:** Canonical architecture contract for V9 implementation
**Date:** 2026-10-12
**Scope:** Conclave Cloud, Profile Lab, Workspace, CLI Worker Engine, and the logical Worker catalog

This specification defines the V9 identity, publication, verification,
activation, and execution-snapshot contract for Worker Profiles. It supersedes
the V8 Profile release/channel lifecycle. V8 ADRs and implementation documents
remain historical records; they are not silently rewritten.

The normative terms **MUST**, **MUST NOT**, **SHOULD**, and **MAY** describe
requirements for V9 implementation work.

## 1. Core decision

Conclave has exactly one centrally published Profile for each logical Worker.
That Profile is the authoritative JSON definition of the Worker's behavior.

```text
Profile Lab operator
        |
        | validate, test, publish request
        v
Conclave Cloud
        | one current published Profile + bounded history
        | atomic publication and authorization
        v
Conclave Workspace / Service
        | fetch -> verify -> cache -> activate
        v
Generic CLI Worker Engine
        | interprets the execution snapshot
        v
Provider CLI
```

The Engine remains provider-independent. ChatGPT, Gemini, and future logical
Workers differ through Profile data and the provider CLI they describe, not
through provider-specific Engine executables or branches in Cloud or
Workspace.

## 2. Shared identity model

| Concept | V9 meaning |
| --- | --- |
| Logical Worker | Stable product identity selected by AX, Workflows, Cloud, and Workspace, such as `chatgpt` or `gemini`. |
| Profile | One canonical JSON behavior definition belonging to exactly one logical Worker. |
| Profile revision | Cloud-assigned monotonically increasing revision of the same logical Worker's published Profile. A revision is not an active release channel. |
| Profile digest | SHA-256 digest of the canonical Profile JSON. |
| Profile candidate | Unpublished JSON being edited and tested in Profile Lab. It is not a published Profile and is never admitted to normal Workspace execution. |
| Profile snapshot | The verified Profile identity, revision, digest, signature, and canonical JSON captured for one execution. It remains immutable until that execution completes. |
| Known-good history | Retained prior published snapshots used for audit or restoration. Historical snapshots are not separately active. |

The V9 contract uses one stable logical Worker identity and one current
published Profile identity. Storage may separate current state, audit history,
signatures, and payload blobs, but those implementation details MUST NOT create
multiple active Profiles for one logical Worker.

## 3. Required invariants

1. **One current Profile:** Cloud MUST expose at most one current published
   Profile for each logical Worker, and a valid Worker MUST have exactly one
   when it is enabled for execution.
2. **Authoritative JSON:** The canonical Profile JSON is the source of truth
   for executable behavior. Identity, revision, digest, signature, publisher,
   and timestamps are integrity metadata around that JSON, not competing
   behavior definitions.
3. **Authorized publication:** Only an authorized Profile Lab operator MAY
   publish or restore a Profile. AI assistance MAY edit a candidate but MUST
   NOT publish, sign, or activate it.
4. **Provider-independent Engine:** The generic CLI Worker Engine owns process
   supervision, protocol handling, limits, session integrity, and security
   invariants. Profiles select only behavior supported by its finite schema.
5. **Atomic publication:** Cloud MUST validate, canonicalize, digest, sign,
   assign the next revision, persist the current Profile, and record audit
   evidence as one atomic state transition. A partial publication MUST NOT be
   observable as current state.
6. **Verified Workspace activation:** Workspace MUST fetch, verify, cache, and
   validate a Profile before activation. A failed candidate MUST NOT replace
   the active cached Profile.
7. **Stable execution snapshot:** An execution MUST use the Profile snapshot
   selected at activation/assignment time. Later publication, restoration, or
   cache refresh MUST NOT rewrite that execution's Profile identity.
8. **Multiple provider CLI versions:** One Profile MAY declare supported
   provider CLI version ranges and bounded version-specific overrides. These
   overrides modify the same Profile; they are not separate Profiles.
9. **Restoration is republishing:** A known-good historical Profile MAY be
   restored, but Cloud MUST publish it as a new current revision. History MUST
   NOT be exposed as a separate active release channel.
10. **No Profile channels:** V9 MUST NOT define or expose testing, beta, or
    stable Profile channels, channel pointers, promotion workflows, or channel
    rollback.

## 4. Profile JSON contract

The Profile JSON contains bounded execution behavior only. It MUST be valid
against the versioned Profile schema and MUST NOT contain provider credentials,
arbitrary code, shell command strings, or unconstrained expressions.

A Profile MAY include, subject to the Engine schema:

- provider executable candidates and version detection;
- supported provider CLI version ranges;
- bounded compatibility overrides for non-overlapping version ranges;
- authentication/readiness probes;
- structured execution arguments and prompt transport;
- output/event extraction and error mappings;
- model and session/resume mappings;
- progress and timeout behavior;
- provider environment allowlists and bounded permission mappings.

The shape below is illustrative; the schema version is independent of the V9
architecture version:

```json
{
  "schemaVersion": 1,
  "providerTool": {
    "name": "codex",
    "executableCandidates": ["codex"],
    "supportedVersions": [
      { "min": "0.180.0", "maxExclusive": "0.200.0" }
    ]
  },
  "execution": {
    "arguments": ["exec", "--json", "-"],
    "stdin": { "mode": "raw_text", "value": "{{prompt}}" }
  },
  "compatibilityOverrides": []
}
```

The Engine MUST detect the installed provider CLI version, select one
unambiguous compatible behavior, and fail closed with a diagnostic when the
version is unknown or unsupported.

## 5. Publication and restoration

Profile Lab owns the candidate workflow:

```text
edit candidate -> schema validation -> Engine/provider test -> operator review
       -> authorized Cloud publication request
```

Cloud owns the authoritative transition:

1. authenticate the Profile Lab audience and required operator permission;
2. verify the candidate's logical Worker identity and schema;
3. verify validation/test evidence is bound to the candidate digest;
4. canonicalize the JSON and calculate its digest;
5. allocate the next Cloud revision;
6. sign the canonical Profile metadata/payload;
7. atomically replace the logical Worker's current published Profile and append
   audit/history metadata.

Publication requests MUST use optimistic concurrency against the current
revision or digest so that a stale candidate cannot silently overwrite a newer
publication.

Restoration uses the same path: the operator selects a retained known-good
snapshot, Profile Lab revalidates it, and Cloud publishes the same JSON as a
new revision. The restored historical revision remains history only.

## 6. Workspace verification, caching, and activation

Workspace MUST treat Cloud as the authority for the current Profile but MUST
remain able to operate from its verified local cache when synchronization is
temporarily unavailable.

For a newly fetched or refreshed Profile, Workspace MUST:

1. verify the logical Worker identity, signature, digest, and canonical JSON;
2. validate the Profile schema and Engine compatibility;
3. detect the installed provider CLI and validate the declared version range;
4. stage the verified payload in Profile-owned application data;
5. initialize/probe it through the generic Engine as required by the runtime;
6. atomically mark it current only after all admission checks pass;
7. retain the prior verified known-good snapshot for recovery and diagnostics.

Activation failure leaves the prior active cache entry unchanged. A revoked,
invalid, incompatible, or tampered Profile MUST fail closed and MUST NOT be
used for a new execution.

## 7. Execution snapshots and continuity

When Workspace admits an assignment, it binds the execution to a Profile
snapshot containing at least:

```text
logicalWorkerId
profileRevision
profileDigest
profileSignature
engineVersion
providerToolName
providerToolVersion
```

The Engine receives the canonical JSON for that snapshot and MUST NOT reload
the current Cloud or Workspace Profile during the execution. New executions
may use a later revision only after Workspace has verified and activated it.
Existing executions finish under their original snapshot, including retries
that are part of the same execution lifecycle.

## 8. Component ownership

| Component | V9 responsibility | V9 prohibition |
| --- | --- | --- |
| Cloud | Own logical Worker identity, current Profile, revision/digest/signature metadata, bounded history, authorization, atomic publication, and audit. | Must not execute provider CLIs or expose multiple active channels. |
| Profile Lab | Edit candidates, validate, run Engine-backed provider tests, show diffs, request publication, and request known-good restoration. | Must not publish without operator authorization, store provider credentials, or make candidates active in Workspace. |
| Workspace / Service | Fetch, verify, cache, activate, snapshot, and supervise Profile-backed Engine executions. | Must not edit Profile JSON, select a channel, or use an unverified payload. |
| CLI Worker Engine | Interpret the finite Profile schema, supervise provider CLI processes, enforce limits/security/session integrity, and emit provider-neutral results. | Must not contain provider-specific Worker executables or bypass Profile/Workspace admission. |
| AX / product workflows | Select logical Workers and display safe readiness/diagnostic metadata. | Must not edit or directly activate Profiles. |

## 9. Explicitly removed from the V9 contract

The following V8 concepts are not compatibility targets for V9:

- draft-to-testing-to-beta-to-stable Profile promotion;
- testing, beta, and stable channel pointers;
- multiple competing active Profile releases;
- channel-specific Workspace selection;
- release-number administration as the identity of current behavior;
- channel rollback APIs.

V9 still permits unpublished Profile Lab candidates, immutable published
history, automatic revisions, digest/signature verification, and one-click
known-good restoration through a new atomic publication.

## 10. D1 persistence and migration contract

Cloud stores the current published state in one `worker_profiles` row keyed by
`worker_type_id`. The row contains the canonical JSON, schema version, Cloud
revision, digest, signature, signing key ID, publishing actor, and timestamp.

Cloud stores prior published snapshots in `worker_profile_history`, keyed by
`(worker_type_id, revision)`, with the snapshot JSON, digest, signature,
signing key ID, actor, publication timestamp, and optional restoration reason.
History is for audit and restoration only; it is never selected through a
channel pointer.

The D1 migration sequence is mandatory:

1. create `worker_profiles` and `worker_profile_history` first;
2. migrate the currently approved stable Profile for each Worker into the
   single current row;
3. validate JSON shape, digest format, and required signature metadata through
   destination constraints, failing closed on malformed data;
4. preserve earlier published snapshots in V9 history where they can be
   mapped unambiguously;
5. deploy and verify the V9 readers and writers;
6. remove legacy Profile release/channel tables only in a later cleanup
   migration.

Existing migrations MUST remain in order and production migration history MUST
NOT be deleted or renumbered. The first replacement migration MUST NOT delete
or rewrite the V8 Profile tables it reads.

## 11. Cloud API contract

The V9 Cloud API exposes one current Profile identity per logical Worker:

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/admin/workers` | List managed Workers and current Profile summaries. |
| `GET` | `/api/admin/workers/:id/profile` | Read the current published Profile. |
| `POST` | `/api/admin/workers/:id/profile/validate` | Validate candidate JSON and optional test evidence without publishing. |
| `PUT` | `/api/admin/workers/:id/profile` | Publish a tested candidate as the next revision. |
| `GET` | `/api/admin/workers/:id/profile/history` | Inspect retained previous snapshots. |
| `POST` | `/api/admin/workers/:id/profile/restore` | Republish a retained snapshot as a new revision. |
| `GET` | `/api/workers/:id/profile` | Return the verified current Profile to an authorized Workspace runtime. |

The publish request MUST contain `expectedRevision`, `candidateDigest`, the
candidate `profile`, and recent `evidence`. `expectedRevision` is `0` only
for a Worker with no current Profile. Cloud recalculates the canonical digest,
validates the Profile schema and compatibility ranges, checks evidence identity
and freshness, and signs the resulting revision. Client evidence demonstrates
what Profile Lab reported from its local Engine/CLI test; it is not treated as
cryptographic proof of local execution.

The V9 endpoints do not accept channel names, promotion actions, release
statuses, or draft-publication transitions. During the additive migration,
legacy V8 endpoints may remain available solely for consumers that have not yet
migrated; they MUST NOT be used by new V9 readers or writers and are removed by
a later cleanup migration after consumer cutover.

## 12. Acceptance contract

The V9 contract is accepted when all four runtime/control-plane components
reference this specification and agree on these facts:

- the same stable logical Worker identity names the Profile in Cloud, Profile
  Lab, Workspace, and Engine admission data;
- the same canonical JSON and digest identify the behavior being published,
  cached, activated, and executed;
- the same Cloud-assigned revision identifies the current published state;
- publication and restoration are operator-authorized and atomic;
- Workspace activation and Engine execution use a verified immutable snapshot;
- no component requires Profile testing, beta, or stable channels.

Implementation changes to routes, storage, local caches, protocol frames, and
tests must trace back to this contract and must not introduce a second Profile
identity or lifecycle.
