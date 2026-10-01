# Worker Engine and Tool Profile Migration Matrix

**Status:** Phases 1, 15, and 16 have synthetic fixture acceptance coverage for both initial Profiles
**Architecture:** [Architecture v8](../architecture/ARCHITECTURE_V8.md)
**Profile contract:** [Tool Profile v1](../specifications/TOOL_PROFILE_V1.md)
**Implementation sequence:** [Architecture v8 plan](ARCHITECTURE_V8_IMPLEMENTATION.md)

## Scope and evidence

This matrix inventories the provider-specific behavior in the migration-only
ChatGPT/Codex and Gemini/Antigravity Dart Workers. Their service implementations
are the behavior references; generic Engine acceptance suites exercise the
ported behavior through fixture CLIs:

- `workers/chatgpt/lib/chatgpt_worker_service.dart`
- `workers/gemini/lib/gemini_worker_service.dart`
- `engines/cli_worker/test/codex_profile_acceptance_test.dart`
- `engines/cli_worker/test/gemini_profile_acceptance_test.dart`
- `packages/tool-profile/test/fixtures/codex-events/`
- `packages/tool-profile/test/fixtures/antigravity-events/`

The historic `workers/chatgpt` and `workers/gemini` test commands delegate to
the corresponding generic Engine acceptance suite.

The current services use shared process/runtime primitives from
`packages/conclave_cli_worker_runtime`. Provider-specific process arguments,
discovery lists, event names, and mappings are migration code; after the v8
acceptance gates, those details belong in signed Profile Releases and the old
provider Worker implementations are removed.

Classification:

- **Generic Engine primitive** — provider-neutral behavior compiled into the
  Engine and enforced by it.
- **Profile data** — bounded provider-specific values interpreted by generic
  Engine primitives.
- **Temporary provider-specific code** — implementation that remains only
  until its behavior is ported and accepted, then is deleted.
- **Not representable safely → explicit design decision** — v1 cannot express
  the current behavior without expanding its trust boundary or defining missing
  semantics. The decision below must be settled before claiming parity.

## Shared execution boundary

| Current behavior | v8 owner and classification | Migration notes |
| --- | --- | --- |
| Resolve one local CLI, launch with structured argv, set working directory, send stdin, drain bounded output, enforce deadline, terminate on timeout/error. | **Generic Engine primitive** | Reuse the provider-neutral process boundary; keep shell execution disabled, output bounds, cleanup, and Workspace cancellation authoritative. No profile may choose a shell or helper process. |
| Cache and revalidate a discovered absolute executable path; cache is local to Worker state. | **Generic Engine primitive** | Cache ownership/path format are implementation details. The profile supplies only candidate name and approved search locations. |
| Keep provider credentials local and pass only explicitly allowed environment keys. | **Generic Engine primitive** for filtering; **Profile data** for provider-specific allowlist. | Never copy these values into Profile payloads, Cloud, Work Requests, or diagnostics. |
| Translate provider output to Local Worker Protocol progress/result/error frames and safe messages. | **Generic Engine primitive** for protocol and bounds; **Profile data** for mappings. | Provider text remains bounded diagnostics and is not forwarded as raw user-visible progress. |
| Store provider session IDs locally by logical session key. | **Generic Engine primitive** | Preserve the existing local-only property and enforce identity continuity in Engine code. |
| Provider-specific branches in `ChatGptWorkerService` and `GeminiWorkerService`. | **Temporary provider-specific code** | Delete after both Profiles pass fixture, real-provider, durable-session, and Work v1 acceptance. Do not port the two Dart services into a generic `if provider == ...` dispatcher. |

## ChatGPT / Codex

| Current behavior | v8 owner and classification | Migration notes |
| --- | --- | --- |
| Resolve `codex`; try cached path, PATH (up to 32 entries), then home paths `.local/bin`, `.npm-global/bin`, `.npm/bin`, `.volta/bin`, `.bun/bin`; also macOS `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`, Linux `/usr/local/bin`, `/usr/bin`, `/bin`, and Windows Node/System32 locations. | **Profile data** for `codex` and home/standard locations; **Generic Engine primitive** for bounded PATH search, platform executable suffixes, cache revalidation, and safe OS locations. | Profile paths must use only admitted path placeholders/locations. Never accept a Cloud-supplied absolute executable path. |
| Run `--version` with a 10-second bound; parse a three-part semantic version (including prerelease/build suffix) from stdout. The current service detects a version but does not reject unsupported ranges. | **Profile data** for arguments, source, and extractor; **Generic Engine primitive** for bounded command execution and semantic-version parsing/range comparison. | Official Profile Releases must declare supported ranges and fail closed outside them. That is an explicit v8 policy addition; current code has no range evidence from which to invent those values. |
| Passive auth check runs the already-resolved executable as `codex login status`; exit code 0 passes, otherwise `provider_authentication_required`. | **Profile data** for argv, timeout, exit-code rule, and issue code; **Generic Engine primitive** for running the probe on the admitted executable. | Directly expressible by Tool Profile v1 passive checks. |
| Execute with `--ask-for-approval never --sandbox workspace-write exec --json --color never --skip-git-repo-check --cd <working directory>`, optional `--model <model>`, optional `resume <session id>`, otherwise `--ephemeral` for stateless work, then `-`. | **Profile data** for structured argument templates and conditions; **Generic Engine primitive** for placeholder expansion and permission ceilings. | Map sandbox flags from the Engine-approved policy. The Profile cannot independently grant `full_access`. |
| Send prompt as raw stdin text (Codex's final `-` argument selects stdin). | **Profile data** for raw-text stdin mode; **Generic Engine primitive** for bounded stdin delivery and close. | Directly expressible by Tool Profile v1. |
| Parse JSONL events; invalid JSON fails, valid non-object/unmapped events are ignored. | **Profile data** for `jsonl` output and event selectors; **Generic Engine primitive** for bounded line framing, JSON decode, and event dispatch. | Unknown provider events must not become protocol errors unless a Profile marks a required terminal event missing. |
| On `item.completed` with `item.type=agent_message`, capture `item.text` as final response, bounded to 512 KiB. Success also requires exit 0, `turn.completed`, no provider error, and non-empty final text. | **Profile data** for selectors/actions/terminal contract; **Generic Engine primitive** for output bounds and terminal validation. | Directly expressible with selectors and finite actions in Tool Profile v1. |
| `turn.started` emits 10% progress; started/updated/completed command, MCP tool, or web-search items emit 45%. | **Profile data** for event matches, fixed percentages, and safe message keys; **Generic Engine primitive** for progress frame emission. | Preserve the current coarse milestones without exposing raw event text. |
| Extract `thread_id` from `thread.started`; require a non-empty ID of at most 256 characters, reject conflicting IDs, and on resume require the observed ID to match the stored one. | **Profile data** for event/selector; **Generic Engine primitive** for length bounds, local session storage, and identity continuity. | Profile v1 `set_session` plus Engine-enforced durable-session policy covers this. |
| Resume with `resume <stored id>`; for a new durable session omit `--ephemeral`, then require and store the observed ID. | **Profile data** for resume/stateless argument conditions; **Generic Engine primitive** for policy and session state. | Never accept a provider ID from Cloud or the assignment payload. |
| Pass requested model with `--model <model>`; current service forwards it without an allowlist or substitution. | **Profile data** for argument and `pass_through`/allowlist policy; **Generic Engine primitive** to reject unsupported values when a Profile declares an allowlist. | No silent model substitution. |
| Allowlist: `PATH`, `HOME`, `USERPROFILE`, `TMP`, `TEMP`, `TMPDIR`, `LANG`, `LC_ALL`, `SSL_CERT_FILE`, `SSL_CERT_DIR`, `CODEX_HOME`, `OPENAI_API_KEY`. | **Profile data** for names; **Generic Engine primitive** for parent-environment filtering and reserved Conclave/Cloud secret denial. | `OPENAI_API_KEY` remains local provider auth; it is never serialized into a Profile. |
| Map cancellation, timeout, authentication, permission/sandbox denial, and fallback failures to stable issue codes; diagnostics expose only the classified code. | **Profile data** for bounded evidence matchers and issue codes; **Generic Engine primitive** for stable public messages, retry policy, redaction, and safe diagnostics. | Tool Profile v1 has the required stable error-code vocabulary; each matcher must use an Engine-approved bounded pattern. |
| Approval is disabled and Codex is explicitly constrained to `workspace-write`. | **Profile data** maps approved execution policy to CLI flags; **Generic Engine primitive** enforces Workspace permissions and cannot be weakened by Profile. | Keep both flags together in fixtures and review; never infer permissions from a provider's default. |

## Gemini / Antigravity

| Current behavior | v8 owner and classification | Migration notes |
| --- | --- | --- |
| Resolve `agy`; try cached path, PATH (up to 32 entries), home paths `.local/bin`, `.gemini/antigravity-cli/bin`, and `AppData/Local/agy/bin`; also the same macOS/Linux standard paths and Windows `ProgramFiles/Google/antigravity-cli` plus System32. | **Profile data** for `agy` and admitted locations; **Generic Engine primitive** for search, cache, platform handling, and safe OS locations. | As with Codex, executable selection remains local and bounded. |
| Run `--version` with a 10-second bound; parse a three-part semantic version from stdout. Current code detects but does not range-check versions. | **Profile data** for command/source/extractor; **Generic Engine primitive** for bounded execution and version comparison. | Official Profile Releases must declare supported ranges; current implementation does not establish the ranges. |
| Read `~/.gemini/antigravity-cli/settings.json`; reject non-`gemini` non-null `modelProvider`; when it is `gemini`, require non-empty `GEMINI_API_KEY`; missing settings/home produce warnings and do not fail readiness. | **Profile data** for bounded path, selectors, and outcomes; **Generic Engine primitive** for home-bound JSON reading and non-empty environment presence checks. | Tool Profile v1's bounded config check represents the current behavior. The Engine returns status and stable issue codes only. Missing settings/home warn; absent/null `modelProvider` passes; another value fails with `provider_failure`; `gemini` without a non-empty key fails with `provider_authentication_required`. |
| Send JSON stdin `{"event":"user","message":{"content":"<prompt>"}}` with newline; request `stream-json` input and output. | **Profile data** for JSON-object stdin and input/output modes; **Generic Engine primitive** for JSON serialization, bounded JSONL framing, and event dispatch. | Directly expressible by Tool Profile v1. |
| Run with `--sandbox --print-timeout <seconds>s`, optional `--conversation <id>`, optional `--model <model>`. | **Profile data** for argument templates; **Generic Engine primitive** for policy-constrained argument construction. | The sandbox flag must map to an Engine-approved policy, not broaden Workspace permission. |
| Pass provider print timeout as `max(1, ceil((assignmentMs - 1500) / 1000))`; independently give the process runner `assignmentTimeout - 1800 ms` (minimum 250 ms). | **Not representable safely → explicit design decision.** | Decision: define provider timeout translation separately from the Engine hard deadline. Preserve ceiling/minimum-one behavior for `--print-timeout`; keep the Engine-owned 1800 ms cleanup grace and 250 ms minimum authoritative. Profile schema must distinguish provider timeout reserve from process cleanup reserve before fixtures freeze. |
| Parse `init` and `result` events; require terminal `result.status=SUCCESS`, a non-empty bounded `result.response`, exit 0, and no provider error. | **Profile data** for event/status/response selectors and terminal rules; **Generic Engine primitive** for bounds and terminal validation. | Directly expressible by finite selectors/actions and output limits. |
| Extract `conversation_id` from `init` and/or terminal `result`; reject conflicting, missing (for durable work), or resumed IDs that differ from the stored ID. | **Profile data** for selectors/actions; **Generic Engine primitive** for consistency, persistence, and resume verification. | Profile v1 event rules can set session from both event shapes; Engine must reject conflicting values. |
| Resume with `--conversation <stored id>`. | **Profile data** for resume arguments; **Generic Engine primitive** for local durable-session policy. | No provider session identifiers cross Local Worker Protocol 4.0. |
| Pass requested model with `--model <model>` without current local allowlist/substitution. | **Profile data** for argument and model policy; **Generic Engine primitive** for declared allowlist enforcement. | No silent substitution. |
| Allowlist: `PATH`, `HOME`, `USERPROFILE`, `ProgramFiles`, `TMP`, `TEMP`, `TMPDIR`, `LANG`, `LC_ALL`, `SSL_CERT_FILE`, `SSL_CERT_DIR`, `AGY_ADC_AUTH`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION`, `GOOGLE_GEMINI_BASE_URL`. | **Profile data** for names; **Generic Engine primitive** for allowlist filtering and secret boundary. | Values stay in Workspace process memory/local provider environment; never in Cloud/Profile payloads. |
| For `step_update` with `state=ACTIVE`, report 40%; use a special message for `step_type=agent_response` and a general working message for every other string step type. | **Not representable safely → explicit design decision** for the catch-all/override semantics; otherwise **Profile data** for event and message mappings. | Decision: progress mappings use deterministic first-match evaluation in Profile source order; a specific `agent_response` rule precedes the generic ACTIVE fallback. Rules for one event that need multiple actions combine them in the same rule. Define this in the Profile contract and test overlap/fallback before fixture freeze. |
| Map cancellation, timeout, missing executable, auth/credential errors, permission/config/sandbox denial, and fallback failures to stable issue codes. | **Profile data** for bounded evidence matchers and issue codes; **Generic Engine primitive** for process failures, public messages, redaction, retry policy, and diagnostics. | Matcher IDs and precedence must be finite, bounded, and fixture-tested. |
| `--sandbox` requests the provider's sandbox behavior. | **Profile data** maps the approved Workspace execution policy; **Generic Engine primitive** enforces the permission ceiling. | Validate the provider flag's exact semantics against the supported `agy` versions during real acceptance. |

## Cross-provider compatibility and acceptance notes

1. Version-range claims are new v8 release data. Do not derive or guess them
   from the current workers; establish them with official CLI compatibility
   evidence and fixtures.
2. Tool Profile v1 can represent the normal argument, stdin, output, event,
   session, model, progress, error, and bounded local-config probe mappings.
   Two versioned-contract decisions remain before full Profile parity is
   claimed: separate provider timeout translation from the Engine hard
   deadline, and define first-match progress fallback precedence.
3. The ChatGPT/Codex acceptance fixture asserts the Profile's full argv
   policy, raw stdin prompt, filtered environment, passive login, live probe,
   JSONL final text, progress, model forwarding, stateless `--ephemeral`,
   durable start/resume, session mismatch, and permission error mapping. Its
   synthetic event corpus is under
   `packages/tool-profile/test/fixtures/codex-events/`. The historic
   `workers/chatgpt` test command delegates to this generic Engine acceptance
   test; it no longer launches the v2 Worker.
4. The Gemini/Antigravity acceptance fixture asserts discovery/version,
   missing and supported/unsupported local config, auth readiness, allowlisted
   environment, stream-json stdin and JSONL events, provider timeout, model and
   sandbox arguments, result/progress mapping, durable conversation start and
   resume, identity mismatch/conflict, authentication/sandbox errors, and a
   missing terminal event. Its synthetic event corpus is under
   `packages/tool-profile/test/fixtures/antigravity-events/`. The historic
   `workers/gemini` test command delegates to generic Engine acceptance.
5. These tests use fixture CLIs and do not establish official signed Cloud
   releases, provider-version support claims, or real authenticated Codex or
   Antigravity runs. Those remain required before replacing the migration-only
   Worker implementations.

## Phase 1 exit

Every requested behavior has a generic Engine owner, Profile data owner, a
planned deletion point for the old provider implementation, or a named design
decision above. Synthetic fixture acceptance now exercises both provider
Profiles through the generic Engine. The timeout and progress design decisions
remain documented; real-provider validation and signed official releases are
still required before deleting migration-only Worker code.
