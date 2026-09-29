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
In Conclave Workspace, the single source for this mapping and its local
execution policy is
[`FirstPartyWorkerAdapterDescriptor`](../../apps/host/lib/first_party_worker_adapter_descriptor.dart).
Setup, local registry migration, package resolution, readiness, and diagnostics
must resolve catalog entries through that registry instead of declaring their
own product-to-adapter mapping.

Each descriptor contains the product Worker Type ID and name, adapter package
ID, executable candidates, supported CLI version bounds, required local
permissions, default local concurrency, and CLI probe strategy. Version bounds
are currently open at both ends for the v1 `codex` and `agy` integrations; the
installed CLI version is discovered and shown in the normal Worker row. Both descriptors default
local concurrency to `1` and require `workstream_filesystem` plus
`shell_execution`. The Codex probe runs `codex --version` and
`codex login status` inside its adapter. Antigravity has no documented
non-interactive authentication-status command, so its routine probe runs
`agy --version`; its first setup and manual **Test** action additionally send
a tiny `OK` request through headless `stream-json` mode. The execution test
uses Antigravity's cached local authentication and sandbox, and may count
toward provider usage. It is never run by routine five-minute polling. Raw CLI
stdout/stderr stays inside the adapter; only bounded safe version and
reason-code fields cross the local adapter protocol. See
[Antigravity headless mode](https://antigravity.google/docs/cli/headless/) and
[installation and authentication](https://antigravity.google/docs/cli/install/).

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
local configuration and readiness status in one compact row. The normal row
shows the provider CLI name and version, CLI usability, last live-test result,
and local readiness. Rows do not expand and there is no details panel. If the
CLI is absent or its version command fails, the row shows a **Not configured**
badge, a short CLI-specific reason, and a **Check again** action. Once the CLI
is available, the row shows an enable/disable switch and a **Test** action for
configured Workers. Desktop probes also search common per-user CLI locations
so GUI launch PATH differences do not hide installations. Local execution
permissions use the fixed catalog policy and are not user-editable in the
Workers page. Unsupported legacy records remain persisted during migration but
are not rendered as v1 catalog rows.

Adapter package installation and verification are internal setup steps. The
normal Workers page and setup errors do not expose adapter package versions,
signatures, signing keys, or release channels. An internal bridge failure is
shown as **Conclave integration needs attention**. Advanced Diagnostics may
include the package ID, version, publisher, signing-key ID, release channel,
and signature-verification result for support troubleshooting.

Workspace app builds embed stable signed `codex` and `antigravity` adapter
archives. First-party setup verifies and seeds the bundled adapter before any
Cloud request, so a clean installation can configure Workers offline. The
existing signed Cloud release flow remains the silent upgrade path. A failed
download, signature check, compatibility check, or health check leaves the
last-known-good adapter active; when no installed candidate is usable,
Workspace falls back to its verified bundled release.

The Workspace resolves executables in this order: a cached absolute path that
still passes the descriptor's version check, the current process PATH, then
known per-user and platform install directories. The versioned local registry
stores only the selected absolute executable path and detected semantic
version; it does not store PATH or provider account data. Assignment launch
revalidates the cached path, rescans if it is missing or unsupported, and gives
the adapter the selected absolute path so launch does not depend on the GUI
process PATH. If discovery fails, the stale path and version are cleared.

The locator tests model Terminal with a CLI directory in PATH, Finder with the
system PATH and a known install directory, and normal login-item startup with a
minimal PATH and `~/.local/bin`. Both first-party CLIs are covered in each
launch context. These tests verify discovery against representative launch
environments; they do not launch the signed-in desktop app through Finder or
the macOS login-item service.

For the ChatGPT slot, Workspace launches the verified local adapter and sends
`initialize.request`, then `probe.request`. The adapter runs `codex --version`
followed by `codex login status`. Its protocol result includes the detected
version and a safe readiness issue code such as `cli_not_found` or
`authentication_required`. Workspace normalizes that result to one of the
stable readiness reason codes `cli_not_found`, `unsupported_cli_version`,
`authentication_required`, `execution_test_failed`, or `ready`. Raw CLI stderr
is never returned to the UI. No provider token is sent to the adapter; Codex
uses its own local authentication state. If authentication is missing, the
user signs into Codex through its own CLI and selects **Check again**. There is
no Node.js prerequisite check or in-app login launcher.

For an assignment, Workspace starts one fresh adapter process in the
Workstream CWD. The adapter starts one Codex process with JSON event output,
the locally permitted sandbox, and the Cloud-supplied model only when present.
It forwards safe generic progress and the final text response; it does not
forward raw tool output, provider diagnostics, or stderr. The Codex child gets
only a small runtime environment allowlist and no injected provider credentials.
Workspace enforces the assignment timeout and cancellation by terminating the
adapter process tree. Adapter failures are normalized to the provider-independent
execution error taxonomy: `worker_not_ready`, `cli_not_found`,
`authentication_required`, `unsupported_cli_version`, `model_not_supported`,
`permission_denied`, `quota_exhausted`, `provider_unavailable`, `timeout`,
`cancelled`, `internal_adapter_error`, and `execution_failed`. Provider-specific
parsing stays inside the adapter. The adapter and Workspace discard raw provider
stderr before returning assignment failures; Cloud persists and exposes only a
canonical code and its generic display message.

For the Gemini slot, Workspace uses the same adapter initialize/probe exchange.
The Antigravity adapter runs its version check locally. Its explicit setup or
manual **Test** action uses the documented headless stream protocol to verify
local authentication/configuration and execution. Authentication failures map
to `authentication_required`; permission setup diagnostics remain local
readiness diagnostics; assignment failures use the shared execution taxonomy,
including `model_not_supported`, `quota_exhausted`, `provider_unavailable`,
`permission_denied`, `execution_failed`, `timeout`, and `cancelled`. For an assignment it launches
one fresh `agy` process with `--input-format stream-json` and
`--output-format stream-json`, sends one user event, and closes stdin after
that turn. `init`, `step_update`, and terminal `result` events are translated
to the shared adapter protocol. The CLI sandbox is enabled; the adapter never
uses `--dangerously-skip-permissions`. Raw tool output, provider diagnostics,
and stderr are never exposed. Its child process receives the same minimal
runtime environment policy as Codex and no injected provider credentials.
If authentication is missing, the user completes Antigravity's own sign-in
flow outside Workspace and selects **Test** again. The CLI version is
displayed in the normal Worker row; the catalog does not enforce minimum or maximum
versions.
Google-account and Gemini API-key configuration remain within Antigravity;
Conclave neither selects the mode nor reads, copies, stores, or logs its
credentials.

Readiness is continuously rechecked at Workspace start, every five minutes,
when the desktop app resumes, and when a user explicitly rechecks setup. The
local state is one of `Ready`, `Not installed`, `Sign in required`,
`Unsupported CLI version`, `Conclave integration needs attention`, `Disabled`,
or `Test failed`. A manual live test stores its local result and timestamp;
routine readiness checks do not replace that last-test record.
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
