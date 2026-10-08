# Workspace, Engine, and Tool Profile Releases

Workspace application releases use the Cloud API under `/api/workspace-releases`. Architecture v8 has three release classes:

1. **Workspace application:** signed and notarized desktop application.
2. **CLI Worker Engine:** generic executable bundled with a Workspace release; it has no separate Cloud release catalog.
3. **Tool Profile:** immutable signed provider integration payload with its own lifecycle and promotion channels.

Provider CLI software is installed and updated by its provider.

## Tool Profile release flow

~~~text
create immutable Profile release
-> schema/security validation and fixture tests
-> publish Draft and promote to Testing
-> real provider acceptance
-> optional Beta, then Stable
~~~

The signature binds the canonical Profile payload and release identity. Workspace verifies the digest, identity, trust roots, and refreshed revocation state before caching a release. Promotion changes lifecycle metadata; it does not alter signed payload bytes. Rollback selects a prior trusted and compatible release.

Real acceptance evidence is produced by [the Profile acceptance suite](../../apps/workspace/test/tool_profile_real_acceptance_test.dart). It covers passive/live probes, a Thread write, durable session start/resume, timeout, and process-tree cancellation. Stable promotion requires evidence for the immutable release digest. The current release gates are listed in the [v8 implementation roadmap](../roadmaps/ARCHITECTURE_V8_IMPLEMENTATION.md#release-gates).

## Workspace and Engine releases

Each Workspace release contains one platform-specific CLI Worker Engine build. Workspace verifies the bundled executable and checks its identity during Local Worker Protocol initialization. Updating or rolling back the Engine means updating or restoring the complete signed Workspace release.

Use the manually dispatched [Workspace macOS release workflow](../../.github/workflows/release-workspace-macos.yml) to build, sign, notarize, publish, download, and verify a macOS release. The workflow uses Workspace signing credentials and public trust roots.

Dispatch it from `main`. Before accessing release credentials or building, the
workflow requires a successful push-triggered repository CI run for the exact
selected commit. A passing run for another revision or a pull request does not
authorize the release.

The Workspace app does not yet perform a complete automatic update transaction with active-work drain, staging, restart, health check, and rollback. Until that passes end-to-end acceptance, install a downloaded and verified notarized archive manually while Workspace is stopped.

## Trust and incident operations

Use [Release Trust and Rotation](../security/RELEASE_TRUST_AND_ROTATION.md) for key separation, overlap rotation, revocation, and recovery constraints. Never store release signing seeds or publication tokens in the repository, package archives, desktop artifacts, or workflow output.
