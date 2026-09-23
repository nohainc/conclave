# Conclave AX Roadmap

Architecture v4 is normative.

The active next-phase roadmap after the completed authentication migration is:

[Post-Authentication Architecture v4 Conformance & Realtime Roadmap](docs/roadmaps/POST_AUTH_V4_IMPLEMENTATION.md)

The original v4 migration roadmap remains useful as implementation history:

[Architecture v4 Implementation Roadmap](docs/roadmaps/ARCHITECTURE_V4_IMPLEMENTATION.md)

Track completed v4/authentication work in:

[v4 Implementation Status](docs/roadmaps/V4_IMPLEMENTATION_STATUS.md)

Current execution model:

```text
Conclave AX -> Conclave Cloud -> Conclave Host -> Worker
```

Accounts are the user-facing representation of Credential Profiles.

Workers never connect directly to Conclave Cloud.
