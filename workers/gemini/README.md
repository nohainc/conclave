# Conclave Gemini Worker

Standalone Dart console executable package for the Gemini product Worker.
It discovers and verifies the local Antigravity CLI, checks its version and
available local configuration, performs explicitly requested live probes,
executes assignments in sandbox mode, parses streaming JSON events, and stores
durable conversation IDs in the Worker state directory. Provider credentials,
CLI arguments, and conversation IDs remain local to this executable.

The executable speaks Local Worker Protocol 3.0 on stdin/stdout. Operational
logs go to stderr as structured JSONL. Passive checks do not send a model
request; the CLI reuses its local account credentials for headless requests.
A live probe sends a minimal request and may consume provider quota.
