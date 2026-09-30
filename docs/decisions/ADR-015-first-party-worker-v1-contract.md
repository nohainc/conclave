# ADR-015: First-Party Worker v1 Contract

**Status:** Accepted; product contract frozen for the first supported Workspace Worker release. First-party runtime implementation is refined by [ADR-017](ADR-017-standalone-dart-worker-executables.md).
**Date:** 2026-09-28  
**Builds on:** ADR-012, Architecture v7  
**Supersedes:** ADR-012 Worker Type catalog, identity/cardinality, naming, and local authentication UX where they conflict with this decision. Other ADR-012 decisions remain in force.

> **Runtime status and terminology:** The fixed `chatgpt` / `gemini` catalog,
> slot cardinality, provider-authentication boundary, and AX-owned model/usage
> rules below remain normative. References below to adapter packages, package
> IDs, or Local Worker Protocol 2.x record the legacy Node implementation and
> are superseded by ADR-017 / Local Worker Protocol 3.0. First-party Workers
> are signed native Dart console executables; Workspace must not probe provider
> CLIs. The full Workspace assignment path has not yet converged; see the
> [implementation plan](../roadmaps/WORKER_RUNTIME_V2_IMPLEMENTATION.md).

## Context

The legacy Workspace implementation supports a broad adapter catalog and
multiple configured Worker instances per type. The first product release
focuses on two first-party standalone Worker executables backed by local CLIs
and leaves provider sign-in, credential storage, and billing mode to those
CLIs. Conclave needs a
stable product, package, and inventory contract before the setup UI and
registry are simplified.

## Decision

### 1. Contract version and supported catalog

The first-party Worker catalog contract is **`firstPartyWorkerCatalogVersion: 1`**.
It contains exactly these two product-facing Worker types:

| Stable product type ID | Product name | Local execution integration |
| --- | --- | --- |
| `chatgpt` | ChatGPT | standalone ChatGPT Worker executable -> Codex CLI |
| `gemini` | Gemini | standalone Gemini Worker executable -> Antigravity CLI |

The user-facing names are **ChatGPT** and **Gemini**. Provider executable names,
version checks, and authentication details are package implementation details.
These names do not claim that Conclave provides a ChatGPT or Gemini API
integration.

Existing implementation IDs `codex` and `antigravity` may remain as adapter,
package, or persisted-record identifiers during implementation and migration.
They map respectively to product type IDs `chatgpt` and `gemini`. The product
type IDs above are the stable v1 catalog identifiers; implementation identifiers
must not leak into product copy as the primary Worker names. The product type
name is the Worker label; users do not provide a second Worker Name.

No other Worker Type is part of the supported v1 product catalog. This
excludes Claude Code, direct OpenAI/Gemini/Anthropic API Workers, Ollama, and
other adapters from v1 setup and scheduling offers. Their code and historical
records may remain during migration; this decision does not authorize deleting
them or their data.

### 2. Cardinality and identity

Each Workspace exposes exactly one catalog slot for each v1 product type:

~~~text
Workspace
├── ChatGPT slot (implemented by the Codex-backed Worker Package)
└── Gemini slot (implemented by the Antigravity-backed Worker Package)
~~~

The slots exist regardless of package readiness, authentication status, or
enabled state. Each slot can resolve to at most one local Worker
configuration and one Cloud inventory entry at a time. A configured Worker is
identified by `(workspaceId, productWorkerTypeId)` for v1; duplicate
configurations for the same pair are invalid. A slot's activation and readiness
are independent mutable properties, not additional Worker instances. Workspace
persists activation as `enabled` or `disabled` and preserves package-reported
readiness when activation changes. The legacy `status=disabled` value remains
only as a compatibility projection for scheduling; it must not replace
readiness. Catalog slot
identity must remain stable across package upgrades, authentication changes, and
readiness changes.

This is a product-facing cardinality and identity contract. Existing Worker IDs
and records should be preserved where they map unambiguously to these slots.
The Workspace registry persists these product IDs as `workerTypeId`; adapter
package IDs remain separate. Registry schema 12 maps
legacy `codex` records to `chatgpt` and `antigravity` records to `gemini`, then
resolves historical duplicates deterministically, preferring the most
configured/ready record and breaking ties by creation time and stable ID.
The Workspace product-to-package registry stores only product type ID,
product-facing name, and Worker Package ID. Generic permissions and concurrency
defaults are separate Workspace policy. Provider executable names, version and
authentication commands, environment requirements, and probe strategy stay in
the Worker Packages.
Removed slots are retained as tombstones and reuse their stable ID if set up
again. Legacy local model defaults and allow-lists are cleared; model choice is
supplied by Project/Workstream assignments. The Worker configuration UI is
limited to local readiness, permissions, concurrency, and diagnostics.

### 3. Provider authentication and billing boundary

The local CLI owns its provider authentication and billing configuration. Its
Worker Package owns all interaction with that CLI, including discovery,
version checks, authentication/readiness interpretation, and execution:

- Codex CLI owns ChatGPT sign-in, API-key sign-in, credential persistence, and
  billing selection for the ChatGPT slot.
- Antigravity CLI owns Google-account sign-in, Gemini API-key configuration,
  credential persistence, and billing selection for the Gemini slot.

Conclave does not ask the user to choose subscription versus API key, does not
infer or promise which billing mode the CLI is using, and does not solicit,
resolve from Conclave credential storage, persist, or synchronize provider
credentials for these slots. Workspace may copy only environment values named
by a package's signed generic passthrough policy into that package process; the
Worker Package decides which declared values to forward to its provider CLI.
Workspace does not interpret those variable names or values. A supported CLI
may keep its own credentials in its own secure credential store. The Worker
Package may launch the provider-supported CLI authentication flow and report
safe readiness information to Workspace.

For v1, these states are equivalent from Conclave's perspective when the
Worker Package reports that execution is available. Authentication-mode
reporting is outside the v1 contract. Conclave's own desktop human session and
Workspace runtime credential remain separate credentials governed by
ADR-013/ADR-014 and are not provider credentials.

### 4. Readiness and execution

The Worker Package determines whether its provider integration can execute by
checking its local CLI, supported version, authentication/configuration, and
execution prerequisites. It uses the CLI's supported local interfaces and
does not receive credentials resolved from Conclave credential storage. It may
receive package-declared ambient environment values through Workspace's generic
bounded passthrough; provider credential resolution and semantics stay outside
Workspace.

First-party Local Worker Protocol 2.6 defines `probe.request` modes `passive`
and `live`. Passive probes perform executable discovery, version checks, and
cheap provider-supported authentication checks without a model request. Live
probes perform a small `OK` request. `probe.result` returns structured checks
with stable issue codes and bounded local diagnostics; diagnostics are never
included in Cloud inventory. Protocol 2.6 also reports the package-resolved CLI
name, absolute path, and version. Workspace stores them locally and performs
no executable discovery. Protocol 2.1 and 2.2 packages retain their legacy
probe-result shape; protocol 2.3 packages remain admitted during migration.
Workspace persists the latest passive probe state and timestamp, the latest
live-test outcome and timestamp, and the package's stable actionable issue
code. It does not infer provider authentication from historical
`credentialStatus`. If passive probing confirms the Gemini CLI and version but
the package reports authentication as unchecked with `setup_required`, the
Worker remains `setup_required` until a live probe succeeds; Workspace does
not label that untested state as a broken integration. Assignment eligibility
uses this package-reported readiness summary, not legacy credential status.
An `execute.request` also carries the remaining assignment `timeoutMs`.
Workspace derives it from
the assignment budget after queueing and package initialization; the Worker
Package subtracts a small cleanup grace to bound its provider CLI. Explicit
live readiness tests keep a separate 30-second deadline. Protocol 2.5 carries
the Conclave session policies `stateless` and `durable_session`; the latter
requires an opaque logical `sessionKey`. Cloud and Workspace route only these
generic values. Each package maps the key to a provider session identifier in
its local store and verifies resume behavior without exposing that identifier
over either protocol boundary. Cloud does not persist provider session IDs or
the opaque key. Both first-party packages default to stateless execution.
Workspace provides a private `Workspace/Workers/<worker-id>/state` directory
to each configured Worker Package through `CONCLAVE_WORKER_STATE_DIR`. Package
files in that directory are opaque to Workspace; packages may use it for local
session mappings and non-secret tool metadata.
Persistent provider processes (`persistent_process`) are deferred.
Execution remains process-per-assignment: the resident Workspace starts one
fresh Worker Package process per assignment, and that package starts one fresh
provider CLI process. Durable sessions resume provider IDs across those fresh
CLI processes. Long-running provider daemons remain deferred until the Codex
and Gemini Workers are proven stable.

Provider CLI stdout/stderr is captured and interpreted inside the Worker
Package, which returns only bounded provider-neutral diagnostics. If a package
crashes before returning a protocol frame, Workspace may retain a small,
redacted tail of the package process's stderr for local diagnostics. That
fallback is never included in Cloud messages, inventory, or assignment errors.

Conclave Workspace MUST NOT discover, version, authenticate with, or execute a
provider CLI or other provider tool directly. It launches and supervises
verified Worker Packages through the Local Worker Protocol. The package owns
provider-specific executable discovery, version and authentication checks,
environment requirements, command construction, output interpretation, and
safe diagnostics. Workspace remains authoritative for package admission,
machine permissions, process lifetime, and whether a package-reported Ready
slot is eligible for local dispatch. It does not interpret provider CLI
semantics.

Cloud receives only safe inventory/readiness metadata required for discovery
and scheduling. No provider credential, credential reference, credential file
path, or billing-mode assertion is part of the v1 synchronized inventory
contract. Readiness is reported through the Local Worker Protocol and remains
provider-neutral at Cloud-facing boundaries.

The Cloud inventory projection is a fixed-catalog record: Worker and Workspace
IDs, product Worker Type ID, local activation/readiness and issue code, native
Worker runtime version, provider tool name/version, capabilities, local
concurrency limit, revision, and timestamps. It does not store a display name,
provider tool path, auth strategy, credential status, model preference, local
permission summary, or adapter version. Workspace authoritative snapshots
remove omitted slots and their Cloud scheduling records.

Model choice, Project/Workstream role, and remote scheduling policy are not
local Worker slot identity or provider authentication concerns. Their ownership
continues to follow the current AX/Cloud execution contracts.

### 5. Protocol separation

The three protocol contracts remain independent:

1. **Human Product Protocol** — AX and Cloud product actions/read models, plus
   the explicitly defined human-authenticated Workspace management routes.
2. **Workspace Runtime Protocol** — the Workspace runtime and Cloud Gateway
   exchange inventory, assignments, progress, results, and cancellation.
3. **Local Worker Protocol** — Workspace and one Worker Package exchange
   initialization, package-reported readiness, execution, progress, results,
   errors, and cancellation.

These protocols may carry the same canonical domain identifiers, but their
envelopes, credentials, transports, and schemas are not interchangeable. AX
does not speak the Workspace Runtime Protocol; Worker Packages do not speak
either Cloud-facing protocol and receive no Cloud runtime credential. Workspace
translates between protocols and never forwards one protocol's envelope into
another.

### 6. Compatibility and scope

This ADR freezes the product and Worker Package boundary; it does not itself
remove existing catalog implementations, rewrite historical ADRs, change the
implemented Local Worker Protocol schema, or migrate Cloud rows. Compatibility
handling for those changes remains separate.

## Consequences

- Workspace UI and Cloud inventory can present a fixed ChatGPT/Gemini catalog
  rather than a generic Add Worker flow.
- The product does not need a provider credential-entry or billing-mode flow
  for either v1 Worker.
- Internal Worker Package IDs may differ from product type IDs, but their mapping is
  explicit and stable.
- Existing multi-instance and broader adapter behavior is legacy/migration
  scope until later phases implement this contract.

## References

- [ADR-012: Workspace-Owned Workers](ADR-012-workspace-owned-local-workers.md)
- [Architecture v7](../architecture/ARCHITECTURE_V7.md)
- [Application boundaries](../architecture/APPLICATIONS.md)
- [Worker v1 catalog contract](../specifications/FIRST_PARTY_WORKER_CATALOG_V1.md)

## Worker Runtime v2 implementation note

ADR-017 does not change this product catalog, cardinality, provider-authentication boundary, or AX-owned model/usage rules. It replaces the first Node-backed package implementation with independently versioned signed Dart console executables. Product IDs remain `chatgpt` and `gemini`; Codex and Antigravity remain provider-tool implementation details owned by those Workers.

The Workspace's schema 17 local registry now stores the fixed product slot
identity and local activation, permission, concurrency, readiness, probe, and
provider-tool diagnostic state. It does not persist user-defined names,
provider credential references/status, model defaults, adapter configuration,
or a legacy status as primary readiness. Worker release policy and active
version remain in the Worker's version-independent release-state file.
