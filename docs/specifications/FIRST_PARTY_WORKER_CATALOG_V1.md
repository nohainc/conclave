# First-Party Worker Catalog Contract v1

**Contract ID:** `firstPartyWorkerCatalogVersion: 1`  
**Status:** Frozen by [ADR-015](../decisions/ADR-015-first-party-worker-v1-contract.md)

This document is the concise shared catalog contract for Conclave Workspace,
Cloud inventory, and AX presentation. ADR-015 records the decision and
compatibility scope.

## Catalog

| Product type ID | User-facing name | Local CLI | Cardinality per Workspace |
| --- | --- | --- | --- |
| `chatgpt` | ChatGPT | `codex` (Codex CLI) | Exactly one stable catalog slot; zero or one configured Worker |
| `gemini` | Gemini | `agy` (Antigravity CLI) | Exactly one stable catalog slot; zero or one configured Worker |

The catalog has exactly these two first-party types in v1. Internal adapter
package IDs can remain `codex` and `antigravity`; they map to product type IDs
`chatgpt` and `gemini` respectively. Product-facing labels are ChatGPT and
Gemini, with the CLI names available as explanatory implementation details.

The stable v1 identity key for a configured slot is:

~~~text
(workspaceId, productWorkerTypeId)
~~~

Workspace local persistence uses `chatgpt` and `gemini` as the corresponding
`workerTypeId` values. Adapter package IDs remain separate implementation
identifiers: `codex` for ChatGPT and `antigravity` for Gemini. Registry schema
6 migrates prior `codex` and `antigravity` records to the product IDs and
enforces one stored record per `(workspaceId, workerTypeId)`. Record names may
not be customized in the v1 UI and are not identity keys. Legacy local model
defaults and allow-lists are cleared; model selection belongs to the
Project/Workstream assignment. If older data contains
duplicates, migration deterministically keeps the most configured/ready record;
ties prefer the earlier creation timestamp and then the lexically smaller
stable ID. A removed Worker Type can be set up again by reusing its stable ID.

There must not be duplicate configured Worker records or synchronized
inventory entries for a key. A slot exists even when not configured or not
Ready. Its status is reported on the slot; it does not create another slot.

## Workspace Workers page

When the connected, unlocked lifecycle state exposes the Workers page, it
renders the two catalog slots in a fixed order: ChatGPT, then Gemini. The page
does not have an Add Worker action, an empty-list state, or a Worker Type
selector. Each slot combines its fixed catalog identity with the matching
local configuration and readiness status in one compact row. Rows do not
expand and there is no details panel. The CLI and its detected version appear
on the second line when the CLI version command succeeds. The status badge is
on that same line. If the CLI is absent or its version command fails, the row
shows a **Not configured** badge, a red reason on a third line, and a
**Check again** action. Once the CLI is available, the row shows an
enable/disable switch instead. Desktop probes also search common per-user
CLI locations so GUI launch PATH differences do not hide installations. Local
execution permissions use the fixed catalog policy and are not user-editable
in the Workers page. Unsupported legacy records remain persisted during
migration but are not rendered as v1 catalog rows.

For the ChatGPT slot, readiness checks probe the installed `codex` CLI and its
reported version, `codex login status`, and the local adapter package through
Workspace signature/integrity verification. There is no Node.js prerequisite
check or in-app login launcher. If authentication is missing, the user signs
into Codex through its own CLI and then selects **Check again**. Codex retains
and uses its own authentication state. Conclave never requests, stores, or
logs OpenAI credentials.

For the Gemini slot, readiness checks probe the installed `agy` CLI and its
reported version, validate local
Antigravity authentication using its documented standalone `agy -p /usage`
command, and verify the installed adapter package. There is no Node.js prerequisite check or in-app login launcher. If authentication is missing, the user completes Antigravity's own sign-in flow outside Workspace and selects **Check again**. The CLI version is displayed for diagnostics; the catalog does not enforce minimum or maximum versions. **Check again** repeats the local checks. Authentication output is discarded and only the exit status is used.
Google-account and Gemini API-key configuration remain within Antigravity;
Conclave neither selects the mode nor reads, copies, stores, or logs its
credentials.

Readiness is continuously rechecked at Workspace start, every five minutes,
when the desktop app resumes, and when a user explicitly rechecks setup. The
local state is one of `Ready`, `Not installed`, `Sign in required`,
`Unsupported CLI version`, `Adapter unavailable`, `Disabled`, or `Test failed`.
Changed state is persisted locally and immediately included in the next safe
Cloud inventory snapshot. Cloud retains the coarse scheduling gate separately:
only `Ready` Workers are eligible for dispatch. Provider credentials and local
paths are never included.

## Authentication contract

The provider CLI owns login, API-key configuration, credential persistence,
and billing mode. Conclave does not ask whether subscription or API-key mode is
preferred; does not determine or represent the mode; and does not receive,
store, log, or synchronize provider credentials. A local CLI's own secure
credential store is outside Conclave storage.

Conclave may launch the CLI's documented authentication flow and validate
whether execution is available. From Conclave's perspective, supported local
authentication modes are equivalent if the CLI is usable. The desktop human
session and Workspace runtime credential are separate Conclave credentials and
are not covered by this provider-auth rule.

## Safe synchronized projection

Cloud inventory may include only the fields needed for discovery and
scheduling, such as Workspace ID, stable Worker ID, product type ID, readiness
or enabled state, supported CLI/adapter version, safe capabilities, and a
non-sensitive attention reason. It must not contain Worker names, auth
strategy, credential status or references, local permission names, model
defaults/allow-lists, provider tokens, API keys, credential-store references,
auth files, local paths, or asserted billing mode. AX receives only this safe
projection and Cloud-owned scheduling state.

The Workspace is authoritative for local CLI availability, compatibility,
execution permissions, and readiness. Cloud scheduling cannot make an
unready local slot executable.

## Excluded from v1 catalog

Claude Code, direct OpenAI API, direct Gemini API, direct Anthropic API,
Ollama, and other Worker integrations are not offered as first-party v1 Worker
types. Existing code and persisted records are retained until a later phase
defines safe migration and cleanup.
