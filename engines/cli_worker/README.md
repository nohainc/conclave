# Conclave CLI Worker Engine

Standalone Dart console process implementing the generic Protocol 4.1 runtime.
The Engine loads one immutable Tool Profile payload and verifies its runtime
structure, Engine compatibility, and payload SHA-256 digest during initialize.
Workspace remains responsible for official release signature verification and
canonical Tool Profile v1 schema admission before launch.

For local development, launch with absolute paths:

~~~sh
dart run bin/conclave_cli_worker.dart \
  --profile /absolute/path/to/profile.v1.json \
  --engine-version 1.3.0 \
  --state-directory /absolute/path/to/worker-state
~~~

The Engine reads Protocol 4.1 NDJSON from stdin and writes frames to stdout.
Structured arguments are passed directly to the resolved provider CLI with
shell execution disabled. Logs are written to stderr.

Provider CLI discovery uses Profile executable names and approved Profile
locations first, then Engine-owned OS baseline locations, then the inherited
`PATH` when the Profile allows PATH search. The Engine keeps a bounded cached
path in its state directory and verifies the expected executable name and
executable status again before reuse. Discovery uses standard OS home variables;
it does not require Conclave-specific environment variables.

The Engine admits bounded Profile payloads and rejects unsafe discovery paths,
reserved Conclave/cloud environment names, oversized rule and selector sets,
and unsupported sandbox policy names. The provider process receives only
declared environment variables, with 64 variables, 64 KiB per value, and 256
KiB total limits. Provider stdout/stderr, stdin, session identifiers, and
execution deadlines are capped by Engine-owned limits. Session keys and stored
provider session IDs are validated, and session files are confined to the
Engine state directory. Provider credentials such as `OPENAI_API_KEY` can be
passed through only when an official Profile explicitly declares them.
The provider working directory is fixed to the Engine's assigned Thread
directory; Profile data cannot select an arbitrary working directory.

Model discovery is Profile-declared. TSV discovery is suitable for providers
that expose a bounded listing command. ChatGPT/Codex Profiles may instead use
`format: "codex_app_server"`; the Engine starts `codex app-server`, performs
the `initialize` and `model/list` JSON-RPC exchange, and stores only sanitized
model and reasoning-effort metadata. The app-server is terminated after the
probe and is not used as a second execution runtime.

The host process supervisor owns cancellation of the Engine process. Within an
assignment, the Engine enforces an outer provider deadline and terminates the
provider process if its output consumer fails or the deadline expires.

The Workspace release supervisor still uses the migration-only v2 Worker
identity path; wiring Workspace launch to the Engine is a later integration
step.

Protocol 4.1 adds a catalog revision pin to execution requests. Legacy 4.0 frames
remain readable without that field; native model identifiers remain local to the
Engine and are never accepted as client-supplied invocation arguments.
