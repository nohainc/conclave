# Conclave AX Roadmap

Architecture v8 is the current implementation target. Its single active plan is [Architecture v8 Implementation](docs/roadmaps/ARCHITECTURE_V8_IMPLEMENTATION.md), which records completed work, remaining release gates, and required evidence.

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

Spaces and Threads define collaboration. Workspaces provide machine execution. Logical Workers remain stable user-facing identities; the Engine and signed Tool Profiles implement them locally.

## Release declaration

The v8 release declaration is withheld until the current implementation plan records evidence for real ChatGPT and Gemini execution, Profile promotion and rollback, Work v1 full-path execution, failure and security acceptance, and production release operations. Fixture tests establish deterministic behavior but do not replace live-provider or production evidence.

Consult the [Workspace release runbook](docs/deployment/WORKSPACE_RELEASES.md), [release trust guidance](docs/security/RELEASE_TRUST_AND_ROTATION.md), and [desktop lifecycle validation](docs/operations/WORKSPACE_DESKTOP_LIFECYCLE_RELEASE_VALIDATION.md) for operational evidence.

## How to plan new work

Use the v8 implementation plan for architecture and release gates, then update the owning current contract when behavior changes. Do not create a new versioned architecture snapshot or a parallel implementation roadmap for work already covered there.

### Gemini AGY discovery candidate

Engine 1.1.0 supports signed generic CLI model discovery, version/Profile-bound
caching, Service inventory projection and explicit live-readiness gating. Gemini
release 2 is an authoring candidate, not a promoted stable release. Real AGY
1.3.3 discovery, selected-model execution and durable resume evidence are in
`docs/acceptance/real-provider/2026-10-11/gemini-discovery.json`.
Protected release qualification/signing, signed LaunchAgent execution and
verified read-only isolation remain gates; Gemini Chat eligibility is withheld.
See `docs/architecture/GEMINI_AGY_PROFILE.md`.
