# Copilot CLI local verification — 2026-10-23

Tested macOS arm64, Copilot CLI 1.0.103, candidate Profile revision 6,
and the source CLI Worker Engine advertising version 1.3.0. Sanitized
executable observations are retained in [copilot.json](copilot.json).
This is local provider evidence, not signed application or publication evidence.

## Profile execution

The unmodified candidate initialized and discovered 31 listed models through
the Engine. `claude-haiku-4.5` was excluded. Auto completed a real request;
a durable second request recalled the first request's marker correctly.
Passive readiness is installation/discovery evidence, not authentication or
model availability evidence.

The bare `copilot --model` error contains a static list of possible IDs.
Explicit requests for `gpt-5.4-mini`, `gpt-5.3-codex`,
`claude-sonnet-5.5`, and `gpt-6-luna` failed with `Model ... is not available`.
Auto nevertheless resolved to `gpt-6-luna` and succeeded. The cause of that
discrepancy is unconfirmed; do not equate parser enumeration with account
entitlement. Keep discovered entries `listed` until execution verifies them.

Auto without an effort used `medium` in the captured request. Auto with `none`
succeeded and reported `none`; Auto with `low` or `max` failed before a model
call. Keep Auto's Profile effort list empty. Explicit `gpt-6-luna` requests
with `none`, `low`, or `max` failed at model availability, so these probes
cannot verify that model's effort table. Tiny `OK` prompts establish invocation
behavior, not quality, relative speed, or reasoning performance.

## Session statistics

The installed CLI supports `--usage-output-file`. A minimal reproduction is:

```sh
copilot --model auto --output-format json --stream off \
  --usage-output-file /tmp/copilot-usage.json \
  -p 'Reply with exactly: OK'
```

Run from an empty scratch directory. The recorded probes additionally disabled
custom instructions and built-in MCP servers and denied shell/write tools.

The file includes `modelMetrics.<model>.usage` with input, output, cache-read,
cache-write and reasoning tokens; request counts/costs; API duration;
`totalNanoAiu`; and `aiCreditsStatus`. The successful Auto sample reported
14,274 input tokens, 5 output tokens, 0 cache-read tokens, 14,271 cache-write
tokens, 0 reasoning tokens, and 2,710 ms API duration. Preserve the provider's
token categories and billing units rather than adding overlapping categories
or assuming request cost is a dollar value. A failed preflight also produced
a zero-usage file, so file existence does not establish success.

The JSONL terminal `result.usage` contains request cost, API/session duration
and code-change counts, but no token breakdown in this capture. A
`session.usage_checkpoint` event also carried an `accountingSnapshot` with
the detailed session totals. Raw checkpoint events contain internal tracing
metadata and should not be published wholesale.

GitHub documents interactive `/usage` as session accounting. It is not an
account-quota CLI subcommand. The existing Profile intentionally has no
top-level `usage` command: passing `-p /usage` is an ordinary prompt and must
not be used as a quota query.

## Account quota and structured model discovery

The CLI's experimental SDK transport offers a non-model quota query:

1. Start `copilot --headless --stdio` with the existing local CLI login.
2. Send JSON-RPC method `account.getQuota` with empty parameters.
3. Frame each request as `Content-Length: <UTF-8 byte length>\r\n\r\n<JSON>`;
   read the response using the same framing. This is not newline JSON.
4. Bound the deadline/output and terminate the child after reading the result.

The real call returned `quotaSnapshots` for `chat`, `completions`, and
`premium_interactions`, including entitlement, used requests, remaining
percentage, reset date, quota availability and token-based-billing flags.
All returned reset timestamps were already past at probe time. Treat them as
raw provider observations, not a verified current balance or future reset.
No credential was extracted or supplied in the RPC payload.

`models.list` returned an empty conversation-model array on the same install.
The SDK documents model metadata including capabilities, but this machine
could not supply it. A future account-aware discovery path should prefer
validated structured capabilities over guessed effort defaults when the CLI
actually returns those capabilities. Preserve the present distinction between
listed and verified models.

Conclave's existing `usage.jsonRpc` helper uses a newline transport and a
Codex initialization handshake. Merely setting its method to
`account.getQuota` would not work. Integrating this RPC requires a reviewed,
generic framing/handshake option and matching validators/tests; this
investigation does not introduce a provider-specific runtime branch.

## Activity events

Profile release 7 adds a declarative `activity` mapping (no provider adapter).
A real `copilot --output-format json --stream off --model auto` run that used
`bash` and `create` emitted these events, which the mapping reads:

| Copilot event | Activity |
|---|---|
| `assistant.turn_start` | `model.started` "Thinking" |
| `tool.execution_start` (`data.toolCallId`, `data.toolName`) | `tool.started` "Using a tool" |
| `tool.execution_complete`, `data.success == true` | `tool.completed` |
| `tool.execution_complete`, `data.success == false` | `tool.failed` |
| `assistant.message` with non-empty `data.content` | `message.updated` |

Tool arguments, shell output and message text are not mapped. Tool titles are
generic because Copilot tool names (`bash`, `create`, `view`, ...) are not a
documented closed set; the tool name is passed as a detail.
`copilot_profile_execution_test.dart` replays these events and checks the
emitted `WorkerActivity` frames.

## Validation and limits

- Focused Copilot discovery/Profile replay: 7 passed, including real-format
  authentication and unavailable-model errors.
- TypeScript Tool Profile package: 155 passed; the actual Copilot candidate is
  now included in the canonical publication-schema test.
- `pnpm validate:profile-lab`: analysis and all 64 tests passed.
- `pnpm validate:engine`: protocol (36) and Dart Profile (31) tests passed,
  then stopped on a pre-existing formatting difference in
  `packages/conclave_cli_worker_runtime/test/cli_streaming_runner_test.dart`.
- Separate Engine analysis passed. Its full tests initially had 86 passes,
  2 skips, and 2 fixture-startup timeouts in `activity_execution_harness_test`.
  Both timed-out tests passed on an isolated rerun with `--concurrency=1`.
- `pnpm validate:cloud`: type checks completed; 825 tests passed and 302
  failed. Repeated failures include the SQLite fixture applying
  `0083_copilot_worker.sql` before the V9 catalog identity columns exist;
  other fixtures hit a `profile_json` CHECK constraint. These broader gates
  remain open and are not claimed as passing.

Focused schema/replay tests plus real Engine execution are sufficient to verify
the candidate's observed invocation and session behavior. They do not qualify
every listed model/effort, read-only isolation, deployed Thread execution,
launchd/TCC/Keychain, or publication. No migration, activation or compatibility
contract was changed. Existing unrelated working-tree changes were preserved.

References: [CLI usage](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/overview),
[SDK client](https://github.com/github/copilot-sdk/blob/main/nodejs/src/client.ts),
[SDK RPC definitions](https://github.com/github/copilot-sdk/blob/main/nodejs/src/generated/rpc.ts).
