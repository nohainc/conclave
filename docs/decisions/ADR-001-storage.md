# ADR-001: D1 + R2 as initial Conclave storage

**Status:** Superseded
**Date:** 2026-09-20

**Superseded by:** [Architecture v8](../architecture/ARCHITECTURE_V8.md) and
[Persistence Contracts](../specifications/PERSISTENCE.md).

This ADR is retained as decision history. Its initial entity inventory,
repository-interface examples, and proposed prompt/log storage are not the
current persistence contract. The fresh v8 D1 baseline and local Workspace
ownership rules are defined by the linked documents.

## Decision
Use Cloudflare D1 as the initial relational system of record and Cloudflare R2 for large/unstructured artifacts.

## D1 stores
- organizations/users/memberships;
- projects;
- worker definitions, capabilities, roles, and configuration metadata;
- workflow/verification policies;
- goals, runs, phases, tasks, dependencies, attempts;
- structured model-call metadata and compact structured results;
- findings, verification records, decisions;
- artifact metadata/references;
- append-only run events;
- usage/cost accounting;
- local runtime metadata and connection state where appropriate.

## R2 stores
- complete large prompts/responses where retention is enabled;
- logs and test output;
- patches/diffs;
- screenshots/reports;
- build/deployment artifacts;
- other payloads unsuitable for relational rows.

## Credentials
Secrets must not be stored in plaintext D1 columns. Platform credentials belong in Cloudflare secrets. Future BYOK credentials require encryption before persistence with keys held separately.

## Rationale
Conclave MVP has moderate transactional metadata volume and long-running AI/tool operations rather than sustained high concurrent database writes. D1 keeps the Cloudflare architecture simple. Large data is naturally externalized to R2.

## Portability requirement
Conclave Core must not issue raw D1 queries directly. Persistence is accessed through repository interfaces such as:
- GoalRepository
- TaskRepository
- WorkerRepository
- RunRepository
- ArtifactRepository
- EventRepository

This preserves a practical migration path to PostgreSQL if future scale or feature requirements justify it.

## Revisit when
- sustained write contention becomes measurable;
- required SQL capabilities are unavailable;
- relational data approaches practical D1 limits;
- operational analytics require a different database architecture.
