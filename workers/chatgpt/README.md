# Conclave ChatGPT Worker

Standalone Dart console executable package for the ChatGPT product Worker.
It discovers and verifies the local Codex CLI, passively checks provider login,
performs explicitly requested live probes, runs assignments as a constrained
workspace-write subprocess, parses structured events, and keeps durable provider
session IDs in the Worker state directory. Provider credentials, CLI arguments,
and session IDs remain local to this executable.

The executable speaks Local Worker Protocol 3.0 on stdin/stdout. Operational
logs go to stderr as structured JSONL. A live probe sends a minimal provider
request and may consume provider quota; passive readiness checks never send a
model request.
