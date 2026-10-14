# Service and Engine Startup V9 (Phase 5)

Goal: once a command is accepted and a slot is available, the Worker Engine
launches without network calls or background maintenance on the hot path.

## 1. Launch plan cache (5.1)

`WorkerLaunchPlanCache` (`apps/workspace/lib/worker_launch_plan.dart`) holds
validated, executable Profile snapshots in memory.

- Key: `workerType | profileDefinitionId | providerCliVersion | engineVersion`.
- Validity: the key's entry stores `store.profileStateFingerprint(workerType)`
  (file stats of the active and last-known-good snapshots plus the trust
  policy `revocationRevision`). A lookup compares it with the current value, so
  a Profile activation, rollback, revocation, Engine or provider CLI change is
  noticed on the next lookup. Permission changes arrive as different inputs.
- The cache never contacts Cloud. A missing Profile is reported, never fetched
  on the hot path; a background `ensureWorkerProfileAvailable` repairs it.
- Warm-up runs at Service start and on every catalog coordinator event.
- Each accepted assignment pins its plan (`pinnedLaunchPlan`) at admission;
  later activations do not change a queued assignment.
- No compatible plan returns promptly `worker_not_ready` (or
  `unsupported_provider_tool_version`) with a diagnostic `reason`
  (`noProfile`, `incompatibleEngine`, `catalog_not_synchronized`,
  `worker_type_not_in_catalog`, ...).
- Unsigned development drafts bypass the cache.

## 2. Local execution queue (5.2)

`CliWorkerEngineSupervisor`:

- Synchronous queue insertion before the first await; cancelling a queued
  assignment prevents process creation.
- Effective per-Worker limit (`maxConcurrentAssignments >= 1`), re-evaluated
  when raised; atomic reserve/release; waiters promoted oldest-first.
- A queued assignment never blocks other Workers.
- Durable-session assignments sharing a native session are serialized by a
  session gate; independent sessions run in parallel. A gate-blocked waiter
  holds no slot.
- Teardown (bounded 10 s) precedes slot release on every path.
- `onSlotReserved` is observation only (not awaited, cannot leak a slot).
- The process record is written concurrently with `initialize` and awaited
  before `ExecuteRequest`.
- The Space mutation lock stays lock-first but is a visible, cancellable stage
  (`waiting_for_space`) bounded by the queue allowance. The remaining allowance
  is passed to the supervisor as `queueWaitTimeoutMs`.
- The two-minute allowance is unchanged (`defaultAssignmentQueueAllowance`).

## 3. Startup stages (5.3)

`worker_resolved → profile_ready → [waiting_for_space] → [queued_for_slot] →
slot_reserved → engine_spawned → engine_initialized → provider_started`.

| Stage | Latency-trace name |
| --- | --- |
| worker_resolved, profile_ready, waiting_for_space, queued_for_slot, engine_initialized | auxiliary, new |
| profile_resolved (T7) | stamped after the Space wait |
| slot_reserved (T8) | unchanged |
| engine_spawned | T9 `engine_process_created` |
| provider_started (T10) | unchanged |

Supervisor failure diagnostics carry `stage` (`queue_wait`, `slot_reserved`,
`engine_spawn`, `engine_initialize`, `provider_execution`), `failureLayer`
(`local_startup` or `provider_execution`), `providerStarted`, and, for exits,
`processExitCode`. A deadline reached before the provider began is a
`startup_timeout` local failure. Local startup timeouts are distinct from Cloud
command-delivery timeouts, which end at acknowledgement.

## 4. Cloud publication

Additive message `assignment.startup`, enabled by capability
`assignment.startup.v1` announced in `hello.ack.cloudCapabilities`. The Service
sends it only after the announcement. Stages: worker_resolved, profile_ready,
waiting_for_space, queued_for_slot, slot_reserved, engine_spawned,
engine_initialized (provider start is reported by existing execution events).
Cloud (`apps/cloud/src/assignment-startup.ts`) stores the furthest stage in
`worker_assignments.startup_stage/_at/_detail_json` (migration 0060) with a
compare-and-set, only while the assignment is `dispatched` or `acknowledged`.

Deploy order: migration 0060, then Cloud, then the Service.
