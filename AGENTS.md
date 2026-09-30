# Conclave AI Development Instructions

These rules are canonical for AI-assisted development in this repository.

## Working method
1. Read `ARCHITECTURE.md`, `ROADMAP.md`, and relevant ADRs/specifications before changing architecture or public contracts.
2. Work in small, independently reviewable phases. Do not combine unrelated refactors with feature work.
3. Prefer explicit domain types and interfaces over provider-specific logic.
4. Treat Conclave Core as provider-independent. Provider, local-model, coding-agent, and CI integrations execute behind Worker boundaries; humans contribute through product workflows.
5. For Worker Runtime v2, use **Worker release/package**, **Worker runtime version**, **Worker process**, and **Local Worker Protocol**. Use adapter terminology only when identifying existing legacy implementation, migration history, or a literal legacy symbol that has not yet been renamed. Do not introduce new adapter-named Runtime v2 code, tests, APIs, or documentation.
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
- Keep schemas/contracts versioned.
- Keep persistence behind interfaces so D1 can be replaced later.
- Avoid premature infrastructure: add Durable Objects, Queues, vector databases, or extra providers only when a concrete requirement exists.
- Update documentation whenever architecture, data model, protocol, workflow behavior, security, or public API changes.

## Review principle
Implementation and verification should be independent when practical. A worker must not be considered verified solely because it reviewed its own output.
