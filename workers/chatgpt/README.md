# Conclave ChatGPT Worker v2 (migration-only)

This provider-specific executable is retained temporarily as the behavior
reference for the v8 migration. New ChatGPT/Codex local execution is owned by the
generic CLI Worker Engine and the signed `chatgpt-codex` Tool Profile.

`dart test` in this package now runs the generic Engine/Profile acceptance
corpus. The v2 executable and service are not the acceptance target and should
be removed after v8 acceptance. Historical Protocol 3.0 details are retained
only in the source until that cleanup phase.
