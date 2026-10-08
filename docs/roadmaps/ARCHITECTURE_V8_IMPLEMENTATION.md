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
  the current Space, Workspace, Thread, Work, Worker, and Profile model.
- The clean v8 schema is in `apps/cloud/migrations-v8/0001_conclave_v8.sql`.
- Until the v8 release declaration, any change to that baseline requires a
  fresh production D1 bootstrap and verified data carry-forward. Schema freeze
  is recorded with the release; after freeze, migrations are immutable and
  schema changes use new forward migration files only.
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
| Dynamic Worker E2E | A Worker unknown to source is created through Profile Lab, qualified against the bundled Engine and fixture CLI, admitted by Workspace from the Cloud catalog, projected for AX, and executes a Work assignment | **Passed with fixtures on 2026-10-03.** The full journey creates a unique Worker ID at test runtime, uses the real bundled Engine and Workspace HTTP catalog/Profile endpoints, calls AX's real Work Request API, dispatches the bound request to Workspace, and loads the result in AX. Cloud signing and Cloud storage are represented by an in-process test boundary with a test-only Ed25519 key. See the [Phase 13 acceptance record](../acceptance/dynamic-worker/2026-10-03/README.md). |
| Real provider assignments | Chat, Work, Plan & Implement, Implement & Verify, and Full Cycle through qualified Profiles and the generic Engine | **Open.** On 2026-10-03, Codex passed all four workflows. Gemini passed Direct; Plan & Implement passed once and failed on rerun, while Implement & Verify and Full Cycle failed with provider errors. Antigravity's headless CLI reported auto-denying a shell command without an explicit `command` permission. Both Profile evidence suites passed. See the [2026-10-03 evidence record](../acceptance/real-provider/2026-10-03/README.md). |
| Work v1 full path | Each built-in Workflow exercises Cloud scheduling, Workspace assignment, Engine execution, persistence, results, and evidence | **Open.** Dynamic Worker Work execution (`direct`) is covered with the Phase 13 fixture acceptance. Each built-in Workflow still needs fresh full-path acceptance and real-provider evidence. |
| Profile release lifecycle | Signed release validation, promotion, rollback, and revocation across Cloud and Workspace | **Implementation complete; operational release acceptance open.** The manual Profile control path and fixture-backed dynamic Worker acceptance are complete. Deployed Cloud, real-provider workflow coverage, and a Testing Workspace rollout remain separate release gates. See the [manual lifecycle status](../specifications/PROFILE_LAB.md) and dated acceptance records. |
| Failure and security behavior | Process-tree cleanup, timeout, cancellation, inventory recovery, session resumption, scheduler authorization, reconnect, and Profile rollback | **Partially covered.** Link the current CI results and any remaining end-to-end recovery evidence. |
| Clean v8 database | Fresh database migration, seed separation, and production deployment/cutover evidence | **Implemented.** The production provisioning record reports the v8 database initialized and production rows copied and checked. Attach the immutable deployment and validation record to the release. |
| Workspace release validation | Signed package install, lifecycle, reconnect/fallback, ownership, and Work Root preservation scenarios | **Open.** Complete the [Workspace lifecycle release validation](../operations/WORKSPACE_DESKTOP_LIFECYCLE_RELEASE_VALIDATION.md) against a candidate package and Cloud deployment. |

Do not infer release readiness from implementation, fixture tests, or a clean
schema alone. When all gates pass, update this table with the release
version/date and link the immutable acceptance evidence.

## Next work

1. Configure a narrowly scoped Antigravity headless command permission for the
   isolated acceptance workspace, then rerun Gemini Implement & Verify and
   Full Cycle. Keep the terminal sandbox enabled and do not use the all-tools
   permission bypass.
2. Publish the accepted Profile digest to the dedicated Testing Workspace and
   verify live execution there.
3. Complete full-path Work v1 acceptance for every built-in Workflow through the generic Engine and both providers.
4. Record operational Profile promotion, rollback, and revocation evidence.
5. Run the candidate Workspace desktop lifecycle matrix, including reconnect,
   cancellation, and Work Root preservation.
6. Attach Cloud/database deployment and security/recovery evidence to the
   release record; then make the release decision.

## Change discipline

- Keep Work v1 and logical Worker identity stable above the runtime boundary.
- Add Engine capabilities only when they are generic and bounded.
- Keep Tool Profiles data-only, signed, immutable, and schema-validated.
- Keep provider credentials in local provider CLI configuration.
- Update the canonical architecture, protocol, security, or release contract
  when behavior changes; do not create versioned parallel concepts for
  historical implementation stages.
