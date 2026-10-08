# Chat and Work workflow regression coverage

Chat is a provider-neutral read-only Work Request with stateless mutation
coordination and a durable Thread provider conversation. Work is current
`direct:v2`, with writable stateful coordination and a separate durable session.
Historical `direct:v1` remains Direct. Tests cover these independent contracts:

| Contract | Executable coverage |
| --- | --- |
| Immutable versions, read/write Step policies and Full Cycle isolation | [Core workflows](../../packages/core/test/thread.test.ts) |
| Read-only Chat instructions, implementation Work intent, Markdown source | [Prompt profiles](../../apps/cloud/test/workflow-prompts.test.ts) |
| Actual Gateway dispatch execution class, read-only flag and binding/model | [Cloud workflow acceptance](../../apps/cloud/test/work-v1-v8-regression.acceptance.test.ts) |
| Stateless Chat without mutation lease, coordinated Work | [Request coordination](../../apps/cloud/test/work-request-coordination.test.ts) |
| Generic Workspace execution policies and fail-closed Profile admission | [Workspace policy](../../apps/workspace/test/assignment_execution_policy_test.dart) |
| Actual Codex argv, explicit approval policy, sandbox policy in normal/compatibility layouts and fresh/resumed sessions | [Profile interpreter](../../packages/tool-profile/test/interpreter.test.ts) |
| Durable Chat reuse, cross-Thread and Chat/Work session isolation | [Session keys](../../apps/cloud/test/work-session-key.test.ts) |
| Historical rows, snapshots, cancellation, foreign keys, indexes, triggers, rollback and Chat schema admission | [Migration alignment](../../apps/cloud/test/chat-workflow-migration.test.ts) |
| Canonical starter synchronization and preservation of existing templates/releases | [Starter provisioning](../../scripts/provision-profile-starter-templates.test.mjs) |
| Snapshot/version history names and unchanged Markdown through Cloud read models | [Storage/read contract](../../apps/cloud/test/markdown-storage-contract.test.ts) |
| Current dynamic Workflow menu, separate Chat/Work bindings, Markdown rendering and historical labels | [AX widget acceptance](../../apps/app/test/spaces_pages_test.dart) |
| Snapshot name precedence and compatibility with older read models | [AX history model](../../apps/app/test/work_request_history_test.dart) |

Provider argument tests expand canonical Profile data; they do not prove a live
provider obeys its sandbox. Signed Profile qualification and real-provider
acceptance remain separate release requirements. Antigravity's current starter
has no verified read-only capability and is rejected for Chat execution.

The compatibility approval correction uses forward migration
`0008_codex_compatibility_approval_policy.sql`, which updates only the unchanged
official development starter. It never edits signed releases or historical
acceptance evidence; existing releases require a newly qualified successor.

## Naming and identifier cleanup audit

The final repository search reviewed `Direct`, `direct:v1`, Direct workflow
branches, `bindings.direct`, `STEP_KINDS`, `WORKFLOW_IDS` and
`THREAD_BINDING_IDS`. The remaining version-1 names belong to immutable
catalog definitions, historical snapshots/evidence and compatibility tests.
Stable `direct` branches resolve Work's binding, session scope and explicit
retry/prompt behavior; they are not presentation-name lookups. Domain unions
include Chat once and leave the persisted Work ID unchanged. Generic uses of
“direct” database access and generated platform documentation are unrelated.
Current operator guidance and generic new-Work test fixtures use Work.
