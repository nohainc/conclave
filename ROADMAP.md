# Conclave AX Roadmap

Architecture V9 is the current design target. The V8 implementation plan remains the historical implementation baseline and records evidence for the existing generic Engine path while V9 is implemented phase by phase. The canonical V9 Profile contract is [WORKER_PROFILE_V9.md](docs/specifications/WORKER_PROFILE_V9.md).

~~~text
Conclave AX
-> Conclave Cloud
-> Conclave Workspace
-> CLI Worker Engine
-> signed Tool Profile
-> provider CLI
~~~

## Product contract

Work v1 remains the constrained, product-owned collaboration and execution model. Its Steps, built-in Workflows, bindings, snapshots, and user-visible behavior are defined by the [Work v1 Contract](docs/specifications/WORK_V1_CONTRACT.md).

Spaces and Threads define collaboration. Workspaces provide machine execution. Logical Workers remain stable user-facing identities; one centrally published Profile per Worker defines its behavior for the generic Engine.

## Release declaration

The V8 release declaration remains a historical implementation gate until its plan records evidence for real ChatGPT and Gemini execution, Work v1 full-path execution, failure and security acceptance, and production operations. V9 removes Profile testing/beta/stable promotion and channel rollback from the target architecture; future release evidence must follow the singular publication and activation contract.

Consult the [Workspace release runbook](docs/deployment/WORKSPACE_RELEASES.md), [release trust guidance](docs/security/RELEASE_TRUST_AND_ROTATION.md), and [desktop lifecycle validation](docs/operations/WORKSPACE_DESKTOP_LIFECYCLE_RELEASE_VALIDATION.md) for operational evidence.

## How to plan new work

Use the V9 Profile contract for new Profile architecture work. Keep the V8 implementation plan as historical evidence and update the owning current contract when behavior changes. Do not create a parallel Profile lifecycle specification.

### Gemini AGY discovery candidate

Engine 1.2.0 supports signed generic CLI model discovery, reviewed model/effort
normalization, Service background refresh, and version/Profile-bound
caching, Service inventory projection and explicit live-readiness gating. Gemini
release 2 is an authoring candidate, not a promoted stable release. Real AGY
1.3.3 discovery, selected-model execution and durable resume evidence are in
`docs/acceptance/real-provider/2026-10-11/gemini-discovery.json`.
Protected release qualification/signing, signed LaunchAgent execution and
verified read-only isolation remain gates; Gemini Chat eligibility is withheld.
See `docs/architecture/GEMINI_AGY_PROFILE.md`.
