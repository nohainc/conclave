# Provider discovery and normalization — Phase 3

Implemented 2026-10-11. Architecture v8 and the Workspace Service ownership
boundary remain unchanged. Extends [Worker execution options v2](WORKER_EXECUTION_OPTIONS_V2.md)
and [Tool Profile v1](TOOL_PROFILE_V1.md).

## Signed mapping

Optional `model.selectionMapping` schema version 1 is finite signed data. It
requires `model.selectionMode: combined`, discovery, model support, and minimum
Engine 1.2.0. It does not introduce a provider adapter or suffix heuristic.

```json
{
  "schemaVersion": 1,
  "models": [{
    "id": "gemini-3.8-flash",
    "name": "Gemini 3.8 Flash",
    "variants": [{
      "nativeId": "gemini-3.8-flash-low",
      "effort": "low",
      "providerVersion": {"min": "1.3.3", "maxExclusive": "1.3.4"}
    }]
  }]
}
```

Each family may declare an evidence-backed `defaultEffort`. Omission means no
known default. A selected combined family with efforts and no default requires
an explicit effort in Core, AX workflow validation and Engine execution. All-null
Auto selection continues to defer to the provider. There is no first-variant or
High fallback.

Bounds: 128 logical families, 128 native variants total, 16 distinct efforts per
family. Duplicate logical IDs, overlapping native ownership and overlapping
family/effort rows are rejected. Version intervals are semantic-version ranges,
minimum inclusive and maximum exclusive; absent intervals match every version.
Disjoint intervals may map renamed native IDs to the same logical selection.
An invalid default or inverted range invalidates the signed mapping.

## Discovery and execution

Codex remains app-server discovery. Actual model IDs, native `model` values,
per-model `supportedReasoningEfforts` and `defaultReasoningEffort` are preserved.
Execution uses the discovered native model and the signed separate effort
argument mapping. There is no shared GPT effort matrix.

For combined selections, the Engine intersects the signed exact native table
with this CLI version and this discovery response. Only present variants become
supported efforts. Empty families disappear. Unclassified native IDs remain
separate entries with their native identity and no inferred efforts. A collision
between a logical family and an unclassified ID fails discovery. A failed or
malformed discovery can use only the existing cache with the exact same Profile
digest and CLI version; absent CLI support cannot manufacture capabilities.

A selected logical pair resolves to one version-compatible signed native row.
The Engine emits `--model <nativeId>` through the existing Profile model argument
slot. Combined selection suppresses the separate `reasoningEffort` argument
context; no conflicting `--effort` is emitted. Unsupported pairs fail before
provider execution. Cloud additionally checks advertised combined efforts against
the signed versioned table and rejects widening or invented defaults.

Variant verification/availability is tracked in the local v2 catalog's private
`variantStatuses` map. Rejection disables only that effort; verified siblings
remain selectable. A family is unavailable when every variant is unavailable,
and verified when all available variants have executable success evidence.
Refresh preserves statuses only in the existing exact Profile/version cache
binding and only for still-discovered efforts. Workspace strips both native ID
and variant status bookkeeping before inventory publication. Catalog revision
includes local binding and statuses, with stable ordering; public clients receive
only the existing opaque revision and aggregate public selection metadata.

## Installed AGY mapping

The current authoring candidate applies these exact rows to the AGY versions
admitted by the Profile (1.2.16 and 1.3.3). The mapping intentionally omits a
variant-level version bound because both admitted versions expose the same
native identifiers. The Profile's `supportedVersions` remains the outer gate;
future AGY versions require separate discovery evidence and a reviewed Profile
update before they can use these rows.

| Logical ID | Supported efforts | Native invocation | Default |
| --- | --- | --- | --- |
| gemini-3.8-flash | low, medium, high | `--model gemini-3.8-flash-<effort>` | Unknown; explicit effort required |
| gemini-3.7-flash | low, medium, high | `--model gemini-3.7-flash-<effort>` | Unknown; explicit effort required |
| gemini-3.6-flash | low, medium, high | `--model gemini-3.6-flash-<effort>` | Unknown; explicit effort required |
| gemini-3.1-pro | low, high | `--model gemini-3.1-pro-<effort>` | Unknown; explicit effort required |

The table abbreviates the eleven explicit signed rows; the Engine never constructs
native IDs using this display notation. Discovery evidence is retained in
[the Phase 1 audit](../architecture/MODEL_EFFORT_SELECTION_PHASE_1.md).

## Validation and rollout

The process fixture exercises all eleven pairs, rejects missing efforts, checks
exact native argv with no separate effort flag, rejects one variant and verifies
its siblings remain usable after discovery refresh. Unit coverage includes exact
installed discovery, duplicates, malformed output, missing/unsupported CLI,
versioned renames, version gates and unclassified ID collisions. Codex native
invocation and effort preservation have separate process-level coverage.

Engine version advances from 1.1.0 to 1.2.0; both canonical materializations are
rebuilt. Profiles without the optional mapping retain their existing behavior.
The candidate remains unsigned and inactive: no signed release, admission,
production deployment, persistent selection rewrite, or database migration is
performed. Existing saved native IDs remain distinct only while discovered and
unmapped; selecting newly grouped families requires an explicit reviewed pair.
A future activated Profile release must treat changed saved IDs as unsupported
and allow users to reselect, rather than guessing a migrated effort.

Validation record: all 46 Engine tests passed; worker protocol 27 and Dart Profile
25 passed during component validation; focused Cloud/Core/inventory tests passed;
AX model/workflow tests 15 passed. Type checks for Cloud, Core, Tool Profile and
runtime protocol passed. Broader Cloud/shared scope: 678 passed, one existing
fixture failure (`capabilities` forbidden in worker inventory). Engine component
validation stops on existing supervisor formatting; AX component validation stops
on existing app-state/cache formatting. These unrelated files were preserved.
Focused Workspace registry/inventory coverage verifies private-field stripping.
No real provider inference was run: process fixtures prove parameter routing,
while the installed catalog establishes listed support. Provider-account execution
verification remains a separate release acceptance activity.
