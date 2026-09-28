# ADR-015: First-Party Worker v1 Contract

**Status:** Accepted; contract frozen for the first supported Workspace Worker release. Implementation and migration are subsequent phases.
**Date:** 2026-09-28  
**Builds on:** ADR-012, Architecture v7  
**Supersedes:** ADR-012 Worker Type catalog, identity/cardinality, naming, and local authentication UX where they conflict with this decision. Other ADR-012 decisions remain in force.

## Context

The current Workspace implementation supports a broad adapter catalog and
multiple configured Worker instances per type. The first product release should
focus on two first-party local CLI integrations and leave provider sign-in,
credential storage, and billing mode to those CLIs. Conclave needs a stable
product and inventory contract before the setup UI and registry are simplified.

## Decision

### 1. Contract version and supported catalog

The first-party Worker catalog contract is **`firstPartyWorkerCatalogVersion: 1`**.
It contains exactly these two product-facing Worker types:

| Stable product type ID | Product name | Local execution integration |
| --- | --- | --- |
| `chatgpt` | ChatGPT | Codex CLI (`codex`) |
| `gemini` | Gemini | Antigravity CLI (`agy`) |

The user-facing names are **ChatGPT** and **Gemini**. The CLI name is shown as
an implementation detail in setup, diagnostics, and status surfaces. These
names do not claim that Conclave provides a ChatGPT or Gemini API integration.

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
├── ChatGPT slot (powered by Codex CLI)
└── Gemini slot (powered by Antigravity CLI)
~~~

The slots exist even when a CLI is missing, unauthenticated, disabled, or
otherwise not ready. Each slot can resolve to at most one local Worker
configuration and one Cloud inventory entry at a time. A configured Worker is
identified by `(workspaceId, productWorkerTypeId)` for v1; duplicate
configurations for the same pair are invalid. A slot's readiness and enabled
state are mutable properties, not additional Worker instances. Catalog slot
identity must remain stable across CLI upgrades, reauthentication, and
readiness changes.

This is a product-facing cardinality and identity contract. Existing Worker IDs
and records should be preserved where they map unambiguously to these slots.
The Workspace registry persists these product IDs as `workerTypeId`; adapter
package IDs remain separate. Registry schema 6 maps
legacy `codex` records to `chatgpt` and `antigravity` records to `gemini`, then
resolves historical duplicates deterministically, preferring the most
configured/ready record and breaking ties by creation time and stable ID.
Removed slots are retained as tombstones and reuse their stable ID if set up
again. Legacy local model defaults and allow-lists are cleared; model choice is
supplied by Project/Workstream assignments. The Worker configuration UI is
limited to local readiness, permissions, concurrency, and diagnostics.

### 3. Provider authentication and billing boundary

The local CLI owns its provider authentication and billing configuration:

- Codex CLI owns ChatGPT sign-in, API-key sign-in, credential persistence, and
  billing selection for the ChatGPT slot.
- Antigravity CLI owns Google-account sign-in, Gemini API-key configuration,
  credential persistence, and billing selection for the Gemini slot.

Conclave Workspace does not ask the user to choose subscription versus API
key, does not infer or promise which billing mode the CLI is using, and does
not request, import, proxy, synchronize, or store provider credentials for
these slots. A supported CLI may keep its own credentials in its own secure
credential store. Conclave may launch the provider-supported CLI authentication
flow and may report only whether the CLI is installed, supported, and usable.

For v1, these states are equivalent from Conclave's perspective when the CLI
can execute successfully. Authentication-mode reporting is outside the v1
contract. Conclave's own desktop human session and Workspace runtime
credential remain separate credentials governed by ADR-013/ADR-014 and are
not provider credentials.

### 4. Readiness and execution

Conclave determines whether a slot can execute by checking the relevant local
CLI, supported version, adapter compatibility, and execution prerequisites.
Presence of the executable alone is insufficient to mark a slot Ready. The
adapter uses the CLI's supported local authentication/configuration and
headless execution interfaces; it must not receive a copied provider token from
Conclave.

The Workspace remains authoritative for local execution readiness and
permissions. Cloud receives only safe inventory/readiness metadata required for
discovery and scheduling. No provider credential, credential reference,
credential file path, or billing-mode assertion is part of the v1 synchronized
inventory contract.

Model choice, Project/Workstream role, and remote scheduling policy are not
local Worker slot identity or provider authentication concerns. Their ownership
continues to follow the current AX/Cloud execution contracts.

### 5. Compatibility and scope

This ADR freezes the product contract; it does not itself remove existing
catalog implementations, rewrite historical ADRs, change adapter protocols,
or migrate Cloud rows. Compatibility handling for those changes remains
separate.

## Consequences

- Workspace UI and Cloud inventory can present a fixed ChatGPT/Gemini catalog
  rather than a generic Add Worker flow.
- The product does not need a provider credential-entry or billing-mode flow
  for either v1 Worker.
- Internal adapter IDs may differ from product type IDs, but their mapping is
  explicit and stable.
- Existing multi-instance and broader adapter behavior is legacy/migration
  scope until later phases implement this contract.

## References

- [ADR-012: Workspace-Owned Workers](ADR-012-workspace-owned-local-workers.md)
- [Architecture v7](../architecture/ARCHITECTURE_V7.md)
- [Application boundaries](../architecture/APPLICATIONS.md)
- [Worker v1 catalog contract](../specifications/FIRST_PARTY_WORKER_CATALOG_V1.md)
