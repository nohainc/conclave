# Conclave Gemini Worker (migration-only)

This package contains the pre-v8 Gemini Worker Runtime v2 implementation and
is retained only as migration reference until v8 acceptance is complete. New
Gemini execution belongs to the generic CLI Worker Engine and the official
`gemini-antigravity` Tool Profile Release.

Run `dart test` from this package to execute the generic Engine + Profile
acceptance corpus. It does not launch the migration-only v2 Worker. The
synthetic Antigravity CLI and JSONL corpus exercise discovery, versioning,
local config/auth readiness, filtered environment, stream-json transport,
timeout/model/sandbox arguments, progress, sessions, and error mapping.

The current v2 executable speaks Local Worker Protocol 3.0 and is not the v8
runtime contract. Remove its provider-specific runtime code after generic
Engine + Profile, real-provider, durable-session, and Work v1 acceptance.
