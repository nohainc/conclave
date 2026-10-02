# Provider CLI fixtures

These small fake CLIs exercise the signed ChatGPT and Gemini Tool Profiles
through the generic Engine. They are test inputs, not Conclave Worker
executables or installable packages.

`codex_profile_provider.dart` and `antigravity_profile_provider.dart` verify
provider-specific arguments, environment allowlists, event parsing, readiness,
progress, error mapping, and durable session behavior. `fixture_provider.dart`
exercises generic Engine process limits, deadlines, and output handling.
