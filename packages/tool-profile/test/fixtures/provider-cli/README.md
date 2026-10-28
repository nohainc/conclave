# Provider CLI fixtures

These small fake CLIs exercise the signed ChatGPT and Gemini Tool Profiles
through the generic Engine. They are test inputs, not Syntila Worker
executables or installable packages.

`codex_profile_provider.dart` and `antigravity_profile_provider.dart` verify
provider-specific arguments, environment allowlists, event parsing, readiness,
progress, error mapping, and durable session behavior. `fixture_provider.dart`
exercises generic Engine process limits, deadlines, and output handling.

The sanitized JSONL streams under `codex-events/` and `antigravity-events/`
are replay fixtures for the current adapter contracts. They contain only
bounded event names, tool kinds, synthetic identifiers, and terminal statuses;
provider prompts, responses, commands, and tool output are intentionally
omitted. The fixture provider reports version `1.2.3` so acceptance tests are
repeatable without depending on a local provider installation.

The event families are based on the recorded Codex `0.160.0` and AGY `1.3.3`
acceptance evidence. These files are sanitized replay recordings rather than
raw provider logs; opt-in real-provider smoke tests cover the installed CLI
against the same normalized contract.
