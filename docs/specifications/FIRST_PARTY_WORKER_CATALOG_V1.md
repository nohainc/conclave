# First-Party Worker Catalog Contract v1

**Contract ID:** `firstPartyWorkerCatalogVersion: 1`  
**Status:** Frozen by [ADR-015](../decisions/ADR-015-first-party-worker-v1-contract.md)

This document is the concise shared catalog contract for Conclave Workspace,
Cloud inventory, and AX presentation. ADR-015 records the decision and
compatibility scope.

## Catalog

| Product type ID | User-facing name | Worker Package integration | Cardinality per Workspace |
| --- | --- | --- | --- |
| `chatgpt` | ChatGPT | Codex-backed package (`codex`) | Exactly one stable catalog slot; zero or one configured Worker |
| `gemini` | Gemini | Antigravity package (`antigravity`) | Exactly one stable catalog slot; zero or one configured Worker |

The catalog has exactly these two first-party types in v1. Internal Worker
Package IDs can remain `codex` and `antigravity`; they map to product type IDs
`chatgpt` and `gemini` respectively. Product-facing labels are ChatGPT and
Gemini. The Workspace's
[`FirstPartyWorkerPackage` registry](../../apps/host/lib/first_party_worker_registry.dart)
contains only the stable product ID, product-facing name, and Worker Package
ID. Generic Workspace execution defaults live separately. Package-owned
executable discovery, version/authentication checks, environment requirements,
command construction, probe strategy, and provider diagnostics stay in each
Worker Package. Workspace launches the mapped package and consumes its bounded
Local Worker Protocol result.

The stable v1 identity key for a configured slot is:

~~~text
(workspaceId, productWorkerTypeId)
~~~

Workspace local persistence uses `chatgpt` and `gemini` as the corresponding
`workerTypeId` values. Worker Package IDs remain separate implementation
identifiers: `codex` for ChatGPT and `antigravity` for Gemini. Registry schema
12 migrates prior `codex` and `antigravity` records to the product IDs and
enforces one stored record per `(workspaceId, workerTypeId)`. The migration
discards previously cached provider executable paths and CLI versions. Record names may
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
local configuration and package-reported readiness status in one compact row.
The normal row shows product-facing identity, package-reported readiness,
last live-test result, and local readiness. A failed manual test
shows safe package-provided check summaries and a stable failure result,
with a copy action. Raw stderr and tool output are not shown. If the
package reports the CLI absent or unusable, the row shows a **Not configured**
badge, a safe readiness reason, and a **Check again** action. Once the package
reports usable, the row shows an enable/disable switch and a **Test** action for
configured Workers. Provider executable discovery, including handling GUI
launch PATH differences, occurs inside the Worker Package. Workspace does not
cache provider executable paths or interpret provider version checks. Local
execution permissions use the fixed catalog policy and are not user-editable
in the Workers page. Unsupported legacy records remain persisted during
migration but are not rendered as v1 catalog rows.

Worker Package installation and verification are internal setup steps. The
normal Workers page and setup errors do not expose Worker Package versions,
signatures, signing keys, or release channels. An internal bridge failure is
shown as **Conclave integration needs attention**. Advanced Diagnostics may
include the package ID, version, publisher, signing-key ID, release channel,
and signature-verification result for support troubleshooting. This readiness
label means Workspace could not admit, start, or communicate with its local
Worker Package; the package-provided safe diagnostic offers next steps.

Product release builds embed stable signed `codex` and `antigravity` Worker
archives. Local builds may embed unsigned first-party archives and enable them
only through their app-bundled fallback; Cloud-delivered archives always
require signature verification. First-party setup verifies and seeds the
bundled Worker Package before any Cloud request, so a clean installation can
configure Workers offline. The existing signed Cloud release flow remains the
silent upgrade path. A failed download, signature check, generic protocol
compatibility check, or package health check leaves the last-known-good package
active; when no installed candidate is usable, Workspace falls back to its
bundled package.

The Worker Package resolves provider executables, including its cached path,
PATH lookup, and known per-user/platform locations. Its signed
`environmentPolicy.environmentPassthrough` lists the parent variables Workspace
may copy into the package process. Workspace uses `includeParentEnvironment:
false`, adds only its bounded generic base environment, and copies only those
declared names without interpreting provider-specific semantics. The baseline
builds a GUI-safe `PATH` from absolute entries in the launching environment,
standard OS executable locations, and generic per-user executable locations;
package manifests do not duplicate this runtime baseline. The package consumes
`providerCliPassthrough` to construct the provider CLI environment.
Sensitive passthrough values are redacted from package output. Any selected
executable path and detected provider-tool version remain package-local and are
not stored in the Workspace Worker registry or passed as provider semantics
for Workspace to interpret. The Workspace registry may store only bounded,
safe package
diagnostics from a failed manual test; raw CLI output and provider account data
remain inside the Worker Package. Assignment launch and readiness recovery
remain package responsibilities, including environment construction for
colocated runtimes when required.

Worker Package tests model Terminal, Finder, and login-item launch environments
with different PATH values and known install directories. They verify package
discovery without requiring Workspace to inspect those locations or provider
executables.

For the ChatGPT slot, Workspace launches the verified Worker Package and sends
`initialize.request`, then `probe.request` in `passive` mode for routine
readiness. The package checks executable discovery, runs its version check,
and uses its supported cheap authentication check. A user-requested **Test**
sends a `live` probe that performs the small `OK` request. The package returns
its detected version and structured check results. Workspace validates and
stores only the package's bounded protocol result; it does not normalize
provider-specific CLI behavior.
Raw CLI stderr is not returned to the UI. A failed manual test may produce a
bounded safe diagnostic from the Worker Package; raw provider output is not
synchronized to Cloud. Workspace does not resolve or interpret Codex
credentials. The package uses local authentication state, with `CODEX_HOME`
and XDG directory values forwarded only when declared in its signed
environment policy. If authentication is missing, the
user signs into Codex through its own CLI and requests a package recheck. There is
no Node.js prerequisite check or in-app login launcher.

For an assignment, Workspace starts one fresh Worker Package process in the
Workstream CWD. The package starts one Codex process with JSON event output,
the locally permitted sandbox, and the Cloud-supplied model only when present.
It forwards safe generic progress and the final text response; it does not
forward raw tool output, provider diagnostics, or stderr. The Codex child gets
the generic runtime environment plus only provider variables declared by the
package's signed policy; the package uses local Codex authentication state.
Workspace enforces the assignment timeout and cancellation by terminating the
Worker Package process tree. The package maps provider failures to the shared
provider-independent
execution error taxonomy: `worker_not_ready`, `cli_not_found`,
`authentication_required`, `unsupported_cli_version`, `model_not_supported`,
`permission_denied`, `quota_exhausted`, `provider_unavailable`, `timeout`,
`cancelled`, `internal_adapter_error`, and `execution_failed`. Provider-specific
parsing stays inside the package. The package discards raw provider CLI stderr
before returning assignment failures; Cloud persists and exposes only a
canonical code and its generic display message. Raw provider stderr is not
forwarded during manual readiness tests; safe bounded package diagnostics stay
local.

For the Gemini slot, Workspace uses the same Worker Package initialize/probe
exchange. The passive Antigravity probe discovers the CLI and checks its
version; it marks authentication as skipped because the package has no cheap
non-model authentication check. Its explicit setup or manual **Test** action
uses a live probe through the documented headless stream protocol to verify
local authentication/configuration and execution. Authentication failures map
to `authentication_required`; permission setup diagnostics remain local
readiness diagnostics; assignment failures use the shared execution taxonomy,
including `model_not_supported`, `quota_exhausted`, `provider_unavailable`,
`permission_denied`, `execution_failed`, `timeout`, and `cancelled`. For an assignment it launches
one fresh `agy` process with `--input-format stream-json` and
`--output-format stream-json`, sends one user event, and closes stdin after
that turn. `init`, `step_update`, and terminal `result` events are translated
to the Local Worker Protocol. The CLI sandbox is enabled; the package never
uses `--dangerously-skip-permissions`. Raw tool output, provider diagnostics,
and CLI stderr are never exposed. Its child process receives the generic
runtime environment plus the provider variables declared by Antigravity's
signed policy. That policy supports Antigravity's cached operating-system
keyring credentials, its documented `GEMINI_API_KEY` mode and
`GOOGLE_GEMINI_BASE_URL`, and CLI ADC configuration through `AGY_ADC_AUTH`,
`GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_CLOUD_LOCATION`, and
`GOOGLE_CLOUD_QUOTA_PROJECT`. API-key mode also requires the CLI's own
`modelProvider: "gemini"` setting; Workspace and the package do not rewrite
that setting or reconstruct provider authentication. `GOOGLE_API_KEY` is not
an Antigravity CLI auth alias. Workspace copies declared values generically into
the package process; the package decides what to forward to `agy`. These values
are not persisted or synchronized by Workspace. If authentication is missing,
the user completes Antigravity's own sign-in/configuration flow outside
Workspace and requests another package probe. A package-reported
Provider CLI versions remain package-local and are not displayed in the normal
Worker row or synchronized as Workspace readiness data.
Google-account and Gemini API-key configuration remain within Antigravity;
Workspace does not select the mode or interpret those credentials.

Workspace requests a Worker Package readiness probe at startup, after app
resume, on explicit recheck, and on the configured passive-check interval. The
package reports provider-specific readiness using the versioned Local Worker
Protocol; Workspace stores only validated safe reason codes. The local state
may be `Ready`, `Not configured`, `Sign in required`,
`Conclave integration needs attention`, `Disabled`, or `Test failed`. A manual
live test stores its local result and timestamp,
plus a bounded safe diagnostic on failure; a successful test clears the old
diagnostic. Diagnostics remain local and are omitted from Cloud inventory.
Routine readiness checks do not replace that last-test record.
Before requesting a probe from a configured first-party slot, Workspace
validates its active Worker Package and restores a verified last-known-good or
embedded package when the active package is missing or invalid. This recovery runs locally and does not
depend on a Cloud Worker Package release being available.
Changed state is persisted locally and immediately included in the next safe
Cloud inventory snapshot. Cloud retains the coarse scheduling gate separately:
only `Ready` Workers are eligible for dispatch. Provider credentials and local
paths are never included.

## Authentication contract

The provider CLI owns login, API-key configuration, credential persistence,
and billing mode. Its Worker Package mediates all interaction with that CLI.
Conclave does not ask whether subscription or API-key mode is preferred, or
determine or represent the mode. Workspace may copy package-declared ambient
environment values into the Worker Package through its generic bounded
passthrough; the Worker Package decides which values reach its provider CLI.
Conclave does not persist, log, or synchronize those values. A local CLI's own
secure credential store is outside Conclave storage.

The Worker Package may launch the CLI's documented authentication flow and
report whether execution is available. From Conclave's perspective, supported
local authentication modes are equivalent if the package reports the CLI
usable. The desktop human
session and Workspace runtime credential are separate Conclave credentials and
are not covered by this provider-auth rule.

Local Worker Protocol 2.5 supports the Conclave session policies `stateless`
and `durable_session`. Durable assignments require an opaque `sessionKey`,
which callers reuse for the same logical Conclave conversation. Cloud persists
the generic policy with the assignment and routes the key to Workspace without
persisting it. Workspace forwards the policy and key to the Worker Package and
strips them from the model prompt. Each first-party package maps the key to its
provider conversation/thread identifier in package-local storage and verifies
resume behavior. Provider identifiers never leave the package or enter Cloud.
`persistent_process` is deferred; each assignment continues to start a fresh
package and provider CLI process.

## Safe synchronized projection

Cloud inventory may include only the fields needed for discovery and
scheduling, such as Workspace ID, stable Worker ID, product type ID, readiness
or enabled state, safe package-reported provider tool version, Worker Package
version, capabilities, and a
non-sensitive attention reason. It must not contain Worker names, auth
strategy, credential status or references, local permission names, model
defaults/allow-lists, provider tokens, API keys, credential-store references,
auth files, local paths, or asserted billing mode. AX receives only this safe
projection and Cloud-owned scheduling state.

Workspace is authoritative for Worker Package admission, local permissions,
and dispatch eligibility. The Worker Package is authoritative for provider CLI
availability, compatibility, authentication/readiness, and execution
prerequisites. Cloud scheduling cannot make an unready local slot executable.

## Excluded from v1 catalog

Claude Code, direct OpenAI API, direct Gemini API, direct Anthropic API,
Ollama, and other Worker integrations are not offered as first-party v1 Worker
types. Existing code and persisted records are retained until a later phase
defines safe migration and cleanup.
