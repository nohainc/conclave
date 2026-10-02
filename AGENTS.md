# Conclave AI Development Instructions

These rules are canonical for AI-assisted development in this repository.

## Working method
1. Read `ARCHITECTURE.md`, `ROADMAP.md`, and relevant ADRs/specifications before changing architecture or public contracts.
2. Work in small, independently reviewable phases. Do not combine unrelated refactors with feature work.
3. Prefer explicit domain types and interfaces over provider-specific logic.
4. Treat Conclave Core as provider-independent. Provider, local-model, coding-agent, and CI integrations execute through the CLI Worker Engine and signed Tool Profiles; humans contribute through product workflows.
5. Follow the v8 contract in `docs/architecture/ARCHITECTURE_V8.md`: logical Workers resolve through signed Tool Profiles to provider CLIs under the generic CLI Worker Engine. Do not introduce provider-specific Worker executables, browser-based provider access, managed provider credentials, legacy runtime entities, or compatibility APIs for unreleased architectures.
6. AI models may propose state changes; Conclave owns persistent state and validates transitions.
7. Do not trust natural-language claims such as "tests pass". Where possible, collect executable evidence.
8. Never store API keys or credentials in plaintext application tables.

## Required completion report
Every implementation task must report:
- what changed;
- tests/checks executed and their results;
- documentation changed;
- remaining risks, assumptions, or unresolved issues;
- migrations or compatibility impact.

## Quality
- Add or update tests for behavior changes.
- Keep schemas/contracts versioned. The v8 D1 schema is a fresh-start baseline,
  not a compatibility migration chain.
- Cloud route/service modules own D1 access. Keep Conclave Core independent of
  D1 bindings and raw SQL; add persistence interfaces only for a concrete
  boundary or testing need, not for a hypothetical database replacement.
- Workspace owns local registry, Profile/Engine state, sessions, logs, and Work
  Root data. Do not treat Cloud persistence as the source of local runtime
  state.
- Avoid premature infrastructure: add Durable Objects, Queues, vector databases, or extra providers only when a concrete requirement exists.
- Update documentation whenever architecture, data model, protocol, workflow behavior, security, or public API changes.

## Review principle
Implementation and verification should be independent when practical. A worker must not be considered verified solely because it reviewed its own output.
