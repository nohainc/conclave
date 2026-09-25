# ADR-011: ID-Based Workstream Working Directories

**Status:** Accepted
**Date:** 2026-09-25  
**Builds on:** ADR-008, ADR-009, ADR-010, Architecture v6  
**Supersedes:** the Conclave-managed repository checkout/worktree portions of ADR-009 and Architecture v6

## Context

Architecture v6 originally modeled mutable Workstream state as a Conclave-managed Git checkout/worktree. That design gives strong source provenance, rollback and repository governance, but it also makes Conclave responsible for repository registration, source selection, branch/checkpoint lifecycle and checkout provisioning.

For the current product stage, that is more infrastructure than Conclave AX needs.

AI Workers such as Codex and Claude Code already understand how to:
- clone public and private repositories;
- inspect local files;
- create branches;
- commit;
- fetch/pull;
- merge/rebase;
- push;
- work with multiple repositories in one task.

Conclave's essential filesystem responsibility is therefore smaller:

> give every Workstream a stable, isolated local directory and always execute Workstream Workers inside it.

The directory identity must survive:
- Project renames;
- Workstream renames;
- repeated renames while work is active;
- Workspace revoke/delete/re-enrollment on the same machine;
- Workspace application reinstall when the local Work Root is preserved.

Names and Workspace enrollment identity are therefore unsuitable path keys.

## Decision

### 1. Workspace has one local Work Root

Each Workspace runtime has one local **Work Root**.

Example:

~~~text
<work-root>/
~~~

The runtime provides a safe default. An advanced local setting may allow the owner to change it.

The Work Root is local machine configuration. It is not a Cloud repository registry and does not identify a Project source.

### 2. Workstream directory is derived only from immutable IDs

The canonical relative path is:

~~~text
<project-id>/<workstream-id>/
~~~

The complete local path is:

~~~text
<work-root>/<project-id>/<workstream-id>/
~~~

Only immutable IDs participate in path identity.

Do **not** include:
- Project name;
- Workstream name;
- User display name;
- User email;
- Workspace ID;
- Worker name;
- repository name.

### 3. Names never rename local work

Project and Workstream names are presentation metadata only.

A user may rename a Project or Workstream any number of times, including while a Run is active.

Renaming must not:
- rename the directory;
- restart a Worker;
- invalidate an active assignment;
- change local path resolution;
- require migration.

The immutable Project ID and Workstream ID remain authoritative.

### 4. Workspace ID is not local work identity

Workspace ID represents the current enrolled runtime identity.

It is appropriate for:
- Cloud connection;
- runtime authorization;
- Worker readiness;
- credentials;
- capacity;
- Project Workspace Grants;
- audit.

It is **not** part of Workstream directory identity.

If a Workspace is revoked/deleted and the same local installation is later paired as a new Workspace with a different Workspace ID, it resolves the same Project/Workstream path and may safely reuse existing local work after validation.

### 5. Do not fingerprint physical hardware

The supported product model remains:

> one normal Conclave Workspace runtime per local OS-user installation.

The runtime already uses one local configuration/data directory and an exclusive process lock.

Conclave does not need motherboard IDs, MAC-address fingerprints, serial-number matching or another hardware identity system merely to preserve Workstream storage.

A technically advanced user may be able to run a second runtime with a different local data root; that is not the normal product workflow and does not change Workstream path semantics.

### 6. Workstream directories are created lazily

Creating a Workstream in Cloud does not need to create local filesystem state.

The runtime creates/ensures the directory when the first Work Request for that Workstream executes on that Workspace.

Algorithmically:

~~~text
receive Assignment
-> validate Project/Workstream authorization
-> resolve Work Root
-> resolve <project-id>/<workstream-id>
-> validate or create marker
-> launch Worker with that directory as CWD
~~~

The directory then persists across Work Requests.

### 7. Local marker protects safe reuse

Each Workstream directory contains an internal metadata marker such as:

~~~text
.conclave-workstream.json
~~~

The marker contains only stable non-secret identity metadata, for example:
- schema version;
- Project ID;
- Workstream ID;
- creation timestamp.

It must not contain Project/Workstream names, email addresses or provider secrets.

Before reusing an existing directory, the runtime validates that the marker matches the requested Project and Workstream IDs.

If the path exists with a conflicting or missing identity marker in a situation where safe adoption cannot be proven, execution fails closed rather than overwriting unknown data.

### 8. Worker CWD is always runtime-resolved

Cloud sends logical execution identity:
- Project ID;
- Workstream ID;
- Assignment/Run context.

Cloud does not send an arbitrary absolute working path.

A Worker cannot select a CWD outside the runtime policy.

The Workspace runtime resolves the local Workstream directory and launches the Worker with that path as the process working directory.

All configured Workers participating in the same Workstream on the same Workspace use the same Workstream directory.

### 9. Repositories are Worker-managed, not Conclave-managed

Conclave does not require a Project Source registry for the initial model.

Inside a Workstream directory, a Worker may:
- clone zero, one or many repositories;
- create files;
- generate build outputs;
- use local tools;
- clone public or private Git repositories using locally available credentials.

Example:

~~~text
<work-root>/
  <project-id>/
    <workstream-id>/
      .conclave-workstream.json
      conclave/
      backend/
      notes/
~~~

Conclave does not automatically register, provision or own those repositories.

### 10. Git is the synchronization mechanism between Workstreams/machines

Two Workstreams may independently clone the same repository into their separate directories and execute in parallel.

Example:

~~~text
<project-id>/
  <workstream-a>/
    conclave/
  <workstream-b>/
    conclave/
~~~

They do not share mutable filesystem state.

Coordination happens through normal Git mechanisms:
- branches;
- commits;
- fetch/pull;
- merge/rebase;
- push;
- pull requests.

Conclave may recommend a dedicated branch per Workstream, but the initial architecture does not require Conclave to create or manage branches.

### 11. Changing Workspace does not transfer files

The same logical Project/Workstream path may exist on multiple physical machines, but the data is local to each machine.

If a Workstream changes Primary Workspace:
- the destination Workspace resolves the same relative ID path;
- if absent, it creates a new empty Workstream directory;
- Conclave does not copy local files automatically;
- the Worker/user reconstructs required state through Git, downloads or explicit instructions.

The UI should warn that changing Workspace does not migrate uncommitted local state.

### 12. Workstream mutation remains serialized

Removing Conclave-managed Git checkouts does not remove the concurrency invariant.

At most one stateful/mutating Work Request may actively mutate a Workstream directory at a time.

Different Workstreams may run concurrently because their directories are distinct.

The execution coordinator/lease remains useful as a Workstream-level mutation lock; it no longer represents exclusive ownership of a Conclave-managed Git checkout.

### 13. Conclave does not guarantee Git rollback/checkpoints initially

Because repository contents are Worker-managed, Conclave does not initially promise:
- automatic checkpoint commits;
- automatic rollback of failed Work;
- automatic branch creation;
- automatic repository cleanliness;
- repository-specific recovery.

Workers and users may use Git for those operations.

Conclave may later observe Git repositories and report branch/HEAD/dirty metadata without turning repositories into user-managed Source objects.

### 14. Lifecycle favors data preservation

- active Workstream: retain local directory;
- completed Workstream: retain;
- archived Workstream: retain;
- deleted Cloud Workstream: do not immediately delete local files automatically.

Local cleanup is an explicit operation.

This avoids destroying unpushed or otherwise valuable local work.

## Security invariants

1. Path identity uses immutable IDs only.
2. Project/Workstream names never affect path resolution.
3. Workspace ID never affects Workstream path identity.
4. User email/name never appears in the canonical path.
5. IDs are validated as safe single path components before path construction.
6. The resolved Workstream directory must remain beneath Work Root.
7. Cloud cannot supply an arbitrary local absolute path.
8. Workers cannot escape CWD policy merely by changing Project/Workstream display names.
9. Existing directories are reused only after marker validation.
10. Re-enrollment must not silently adopt a directory belonging to different Project/Workstream IDs.

## Consequences

### Positive

- simpler Conclave product and runtime;
- no Source/repository-management UI required;
- rename-safe by construction;
- Workspace re-enrollment does not orphan local work;
- multi-repository work requires no special product feature;
- parallel work on the same Git repository is naturally isolated by Workstream;
- private repository credentials stay local;
- repository behavior remains in tools already designed to manage Git.

### Tradeoffs

- Conclave does not initially know authoritative repository provenance;
- automatic rollback/checkpoint guarantees are reduced;
- Workers/users are responsible for Git synchronization;
- multiple Workstreams may duplicate repository clones;
- changing physical machine requires reconstructing local state;
- enterprise source governance can be added later if proven necessary.

## Core invariant

> **Local work belongs to Project + Workstream identity, not to names, Workspace enrollment identity, or repositories. The Workspace supplies the machine; the Workstream ID path supplies stable isolation; Workers manage what lives inside it.**
