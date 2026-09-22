# V2-29 — Legacy architecture deletion gate

> **Historical V2 deletion gate.** This remains a record of migration history;
> Architecture v3 is the normative source for all new work.

## Status

Deletion is intentionally blocked. V2-25 through V2-27 have policy and relay tests, but the repository has not yet passed the real external acceptance run with:

- a real repository and bug request;
- a connected Agent and Local Runtime;
- persisted D1/R2 evidence;
- independent implementation/review results;
- real tests and completion criteria;
- Studio displaying the terminal result after restart.

Deleting the compatibility layer before that proof would remove the only fallback needed to diagnose a failed migration and would make the acceptance result ambiguous.

## Deletion order after acceptance

1. Freeze and export a complete v2 run/tenant backup.
2. Migrate all production worker records from `connections`/`worker_connections` to Agent + Plugin + Worker records.
3. Remove Cloud provider API adapters and permit only Agent/Plugin execution in Forge.
4. Replace `RuntimeConnection` with the final Agent Gateway transport, preserving the internal runtime operation utilities.
5. Rename user-facing “Local Runtime” product text to “Agent Runtime” while retaining internal package terminology where it describes safe filesystem/process utilities.
6. Remove legacy migrations and compatibility types only after a clean migration rehearsal and restore test.
7. Delete superseded documentation and update architecture ADRs.

## Required exit evidence

- `rg` shows no production references to `ConnectionResource`, `worker_connections`, direct provider execution, or `RuntimeConnection`.
- A clean database migration reconstructs the same run and ordered events.
- Single-Agent, two-Agent, and Web AI Worker acceptance suites pass without compatibility adapters.
- Backup restore and tenant-isolation tests pass.
