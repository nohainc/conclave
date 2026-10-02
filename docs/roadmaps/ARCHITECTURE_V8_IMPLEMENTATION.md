# Architecture v8 Implementation Roadmap

**Status:** Architecture implemented; release declaration withheld pending acceptance evidence. **Architecture:** [Architecture v8](../architecture/ARCHITECTURE_V8.md). **Decision:** [ADR-018](../decisions/ADR-018-generic-cli-worker-engine-and-tool-profiles.md). **Profile contract:** [Tool Profile v1](../specifications/TOOL_PROFILE_V1.md).

## Target

Conclave uses one generic isolated CLI Worker Engine for approved local CLI
integrations. Signed Tool Profiles describe bounded provider CLI behavior.
Cloud owns shared state, authorization, catalog and releases; Workspace
resolves the logical Worker and Profile, supervises the Engine, and owns the
local process tree.

```text
Conclave AX -> Conclave Cloud -> Conclave Workspace
                                  -> CLI Worker Engine
                                  -> signed Tool Profile
                                  -> provider CLI
```

The initial official mappings are ChatGPT → `chatgpt-codex` → `codex` and
Gemini → `gemini-antigravity` → `agy`. Work v1 remains above the runtime
boundary and continues to target logical Workers.

## Convergence status

The current source tree has converged on the v8 architecture:

- Assignment execution resolves the logical Worker and Profile through the
  current readiness path, then calls the CLI Worker Engine supervisor.
- One generic CLI Worker Engine is the production CLI runtime.
- Current Cloud routes, authorization, protocol schemas, and persistence use
  the current Project, Workspace, Workstream, Work, Worker, and Profile model.
- The clean v8 schema is in `apps/cloud/migrations-v8/0001_conclave_v8.sql`.
- Current protocol definitions are generated from the canonical protocol
  packages.
- Superseded Worker binaries, releases, compatibility paths, schema snapshots,
  and historical architecture documents have been removed from the active
  tree.

This convergence status describes implementation direction. It is not itself
evidence that every real-provider, production-device, or release operation has
passed.

## Release gates

Architecture v8 remains unreleased until each gate has dated, reviewable
evidence linked from the release record.

| Gate | Required evidence | Current recorded state |
| --- | --- | --- |
| Real provider assignments | Direct, Plan & Implement, Implement & Verify, and Full Cycle with ChatGPT and Gemini through the generic Engine | **Open.** The last recorded run on 2026-10-01 passed all four ChatGPT scenarios and two Gemini scenarios; Gemini Plan & Implement and Implement & Verify failed. Rerun after fixes. |
| Work v1 full path | Each built-in Workflow exercises Cloud scheduling, Workspace assignment, Engine execution, persistence, results, and evidence | **Open.** Fixture-backed coverage exists; fresh full-path real-provider evidence is still required. |
| Profile release lifecycle | Signed release validation, promotion, rollback, and revocation across Cloud and Workspace | **Open.** Domain/store coverage exists; operational release evidence is not recorded here. |
| Failure and security behavior | Process-tree cleanup, timeout, cancellation, inventory recovery, session resumption, scheduler authorization, reconnect, and Profile rollback | **Partially covered.** Link the current CI results and any remaining end-to-end recovery evidence. |
| Clean v8 database | Fresh database migration, seed separation, and production deployment/cutover evidence | **Implemented.** The production provisioning record reports the v8 database initialized and production rows copied and checked. Attach the immutable deployment and validation record to the release. |
| Workspace release validation | Signed package install, lifecycle, reconnect/fallback, ownership, and Work Root preservation scenarios | **Open.** Complete the [Workspace lifecycle release validation](../operations/WORKSPACE_DESKTOP_LIFECYCLE_RELEASE_VALIDATION.md) against a candidate package and Cloud deployment. |

Do not infer release readiness from implementation, fixture tests, or a clean
schema alone. When all gates pass, update this table with the release
version/date and link the immutable acceptance evidence.

## Next work

1. Resolve the recorded Gemini workflow failures and rerun the four-scenario
   real-provider matrix for both official Workers.
2. Complete full-path Work v1 acceptance through the generic Engine and both
   providers.
3. Record operational Profile promotion, rollback, and revocation evidence.
4. Run the candidate Workspace desktop lifecycle matrix, including reconnect,
   cancellation, and Work Root preservation.
5. Attach Cloud/database deployment and security/recovery evidence to the
   release record; then make the release decision.

## Change discipline

- Keep Work v1 and logical Worker identity stable above the runtime boundary.
- Add Engine capabilities only when they are generic and bounded.
- Keep Tool Profiles data-only, signed, immutable, and schema-validated.
- Keep provider credentials in local provider CLI configuration.
- Update the canonical architecture, protocol, security, or release contract
  when behavior changes; do not create versioned parallel concepts for
  historical implementation stages.
