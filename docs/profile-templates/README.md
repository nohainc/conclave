# Runtime model catalog profiles

These are the replacement Tool Profile documents for the ChatGPT/Codex and Gemini/Antigravity workers.

They intentionally do not contain a signed model catalog or effort list. When a Worker starts or its catalog is refreshed, Workspace runs the profile's discovery protocol and publishes the sanitized result through the Cloud Worker inventory. AX reads that inventory; it never connects directly to a provider CLI.

The ChatGPT profile uses the Codex app-server JSON-RPC protocol (`initialize`, then `model/list`) so the installed Codex account supplies its current model and per-model reasoning-effort catalog. The generic Worker Engine still executes the signed profile command; app-server is used only for discovery.

The Gemini discovery output is tab separated:

```text
model-id<TAB>display name<TAB>effort1,effort2<TAB>default effort
```

The third and fourth fields are optional. A provider that does not report effort metadata simply produces model choices without effort choices. Do not add provider model names or guessed effort rules to these profiles.

Import each JSON document as a new Tool Profile release in Profile Lab. Retire older static-catalog releases after the new release has been qualified in Workspace.
Migrations `0034_runtime_model_catalog_starters.sql`,
`0035_codex_app_server_model_discovery.sql`, and
`0038_gemini_combined_model_selection.sql` update the untouched
development starters to these documents while preserving customized starters.

Profile Lab also migrates an existing local ChatGPT Draft that still uses the
old `codex models` TSV probe (or embeds a static catalog) to the app-server
discovery shape when the Draft is opened. The migration only changes the
unsigned local Draft; published releases remain immutable and must be
republished after the Draft passes its test ladder.

The ChatGPT profile requires a Codex CLI version that implements `codex app-server` and the `model/list` request. If the app-server cannot initialize or the account is not authenticated, the Worker will remain executable but its model list will use the last successful cache, or remain empty on first discovery.

## ChatGPT Codex v2: live activity

`chatgpt-codex-runtime-catalog.v2.json` is the v1 document plus an `activity`
block (adapter `codex-jsonl`) and corrected progress item types. Without it the
Worker emits no Worker Activity events, so the Work tab cannot show live status
or elapsed time. Import it as a new release in Profile Lab; the mapping replay
check should pass, then qualify it in Workspace before retiring v1.

## Antigravity live activity

`gemini-antigravity-runtime-catalog.live-activity.json` is the pasted Antigravity
profile with an `activity` block (adapter `agy-stream-json`). It maps `init` to
"Thinking", agent responses to "Writing the response", and tool `step_update`
events with a `tool_id` to start, completion and failure pairs. Tool events
without an id are handled by the adapter's fallback, so they are not reported
twice. Import it as a new release in Profile Lab.

Release 3 of the Antigravity live-activity starter
(`gemini-antigravity-runtime-catalog.live-activity-v3.json`) supersedes release 2.
It follows the documented AGY stream-json shape (`step_type` `tool`, `DONE`
completion, `tool_info.error` for failures). Tool steps without a `tool_id` are
paired by the engine adapter using `step_index`.

## Claude Code (`claude-code`, release 1)

`claude-code-runtime-catalog.v1.json` is the starter Profile for the `claude`
Worker. Migration `apps/cloud/migrations-v8/0049_claude_worker.sql` registers the
Worker in `worker_catalog` (release stage `testing`, sort order 30) with
`profile_definition_id` `claude-code` and `provider_tool_name` `claude`. Since
0044 removed the V8 definition and starter tables, the Profile identity lives only on
the catalog row, and no starter template is seeded. Create the first Draft from a blank
Profile in Profile Lab and paste this JSON. No Profile is published by the migration.

Before publishing, confirm with `claude --version` that the supported range
(`2.1.0` up to `3.0.0`) is right, and run a live probe. The execution mapping
uses `claude -p --output-format stream-json --verbose` with stdin, and reads the
session from the `system`/`init` event and the `result` event. The model
allowlist uses the Claude Code aliases `sonnet`, `opus`, and `haiku`, so no
version-specific model IDs are guessed. This release has no `activity` block: Claude
streams tool use inside nested `assistant` content blocks, which the declarative
mapping cannot select, so live tool activity needs a dedicated engine adapter
(`claude-stream-json`) before it can be added.

Claude Code does not expose a `claude models` TSV command. This Profile uses
its declared alias catalog and omits `model.discovery`; declaring that command
causes the Engine's passive probe to fail with `provider_failure`. For an
existing Draft, remove the entire `model.discovery` object (keep `arguments`,
`unknownModelPolicy`, `allowlist`, and `catalog`) or reimport this template,
then rerun the passive and live probes. No Engine or Profile Lab rebuild is
needed for this Profile-only correction. The empty passive checks verify CLI
availability/version only; a live probe is still needed to verify authentication
and execution. Published Profiles require a new revision through the normal
publication workflow.

The Claude environment allowlist preserves `USER`, `LOGNAME`, `SHELL`, and
`__CF_USER_TEXT_ENCODING` alongside `HOME`. On the tested macOS installation,
omitting these user-session variables caused the headless live probe to return
"Not logged in" despite the interactive CLI being authenticated. Preserving
them together restored successful authentication; no credentials are embedded
in the Profile. Reimport the updated template into an existing Draft before
rerunning its live probe.

The supervisor must also preserve these variables when launching the Engine.
After updating `conclave_cli_worker_runtime`, restart Profile Lab (rebuild an
installed packaged app); editing the Profile alone cannot restore variables
that the supervisor removed before the Engine started.

## Antigravity live-activity release 4

`gemini-antigravity-runtime-catalog.live-activity-v4.json` supersedes release 3. Release 3 required a `tool_id` field, which the documented `agy` stream-json format does not include. A real headless capture showed that tool steps are identified by `step_index`, that the `ACTIVE` and `DONE` events for one tool step share that index, and that the tool name is `run_command`. Release 4 keys the tool lifecycle on `step_index`. Profile Lab's replay fixture and the Engine adapter use the same shape.

Release 4 also declares `1.3.4` as a supported Antigravity version. That is the build the stream-json capture was taken from, and the release 3 ranges did not include it.
