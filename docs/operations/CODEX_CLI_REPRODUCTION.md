# Direct Codex CLI reproduction

`scripts/reproduce-codex-cli.dart` is a standalone diagnostic harness. It reads
an installed Codex Tool Profile, expands its execution arguments, forwards the
exact bytes of a UTF-8 prompt file through standard input, and drains stdout and
stderr concurrently. It uses the Profile's environment allowlist without
logging environment values. No timeout is imposed by this harness.

Run it from the repository root using a working directory where the provider is
authorized to execute the prompt. Prefer a disposable repository copy when the
prompt could edit files. The output directory must not already exist.

```sh
dart scripts/reproduce-codex-cli.dart \
  --prompt-file /absolute/path/prompt.txt \
  --profile-file /absolute/path/current-profile.json \
  --work-directory /absolute/path/disposable-repository \
  --output-directory /absolute/path/new-evidence-directory \
  --model gpt-5.6-luna \
  --reasoning-effort high
```

Choose the model and effort from the failing assignment's execution selection.
Omit them to use the provider defaults. Optional arguments are `--executable`,
`--sandbox-policy` (defaults to `restricted`), and `--session-id` for native
session resume. Use a disposable session when testing resume.

The harness supports the installed Codex Profile's standard argument markers,
raw-text stdin, and empty provider timeout arguments. It does not perform
Profile signature verification, version compatibility overrides, catalog
validation, conversation-context assembly, or assignment admission. It is not
a production Worker execution path.

Evidence files:

- `summary.json`: arguments, prompt byte count, duration, process exit code,
  stdin delivery, event counts, malformed-line count, and final-response presence.
- `stdout.jsonl`: raw provider events.
- `stderr.txt`: raw provider errors.
- `last-agent-message.txt`: last completed `agent_message.text`, including
  intermediate commentary from an interrupted run.
- `final-response.txt`: that message only when `turn.completed` was observed.

Raw evidence can contain private prompt/response content, tool output, paths,
or provider diagnostics. Keep it local; sanitize before sharing or committing.
The harness exits nonzero for a process/input/harness failure, a missing final
response, or a missing `turn.completed` event.

A successful direct CLI run proves that the CLI accepted that input with those
settings. It does not establish correctness of Service admission, Engine
interpretation, Cloud transport, or UI projection. Correlate those boundaries
with the failing assignment before diagnosing the product failure.
