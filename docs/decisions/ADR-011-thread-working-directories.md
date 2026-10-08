# ADR-011: ID-Based Thread Working Directories

**Status:** Accepted

Workspace assignment handlers create a mutation coordinator whenever a
Thread directory lifecycle is supplied, unless an explicit coordinator is
provided. Desktop Work (`direct`) execution therefore always enforces the local lock
and lease fencing before invoking the Engine. A stale fencing token is rejected
before provider execution; scoped stateful execution never falls back to an
uncoordinated directory.
**Date:** 2026-09-25  
**Builds on:** ADR-008 and ADR-009

Work v1 and persistence details are defined by the
[Work v1 Contract](../specifications/WORK_V1_CONTRACT.md),
[Persistence Contracts](../specifications/PERSISTENCE.md), and
[Architecture v8](../architecture/ARCHITECTURE_V8.md). This ADR defines the
local directory and filesystem fencing rules those contracts use.

## Context

Conclave does not manage Git repositories or repository registration. Provider
CLIs, launched through the generic Engine, manage repositories inside a
Thread's stable local directory.

For the current product stage, that is more infrastructure than Conclave AX needs.

Provider CLIs can:
- clone public and private repositories;
- inspect local files;
- create branches;
- commit;
- fetch/pull;
- merge/rebase;
- push;
- work with multiple repositories in one task.

Conclave's essential filesystem responsibility is therefore smaller:

> give every Thread a stable, isolated local directory and execute its assignments through the generic Engine inside that directory.

The directory identity must survive:
- Space renames;
- Thread renames;
- repeated renames while work is active;
- Workspace revoke/delete/re-registration on the same machine;
- Workspace application reinstall when the local Work Root is preserved.

Names and Workspace registration identity are therefore unsuitable path keys.

## Decision

### 1. Workspace has one local Work Root

Each Workspace runtime has one local **Work Root**.

Example:

~~~text
<work-root>/
~~~

The runtime provides a safe default. An advanced local setting may allow the owner to change it.

The Work Root is local machine configuration. It is not a Cloud repository registry and does not identify a Space source.

### 2. Thread directory is derived only from immutable IDs

The canonical relative path is:

~~~text
<space-id>/<thread-id>/
~~~

The complete local path is:

~~~text
<work-root>/<space-id>/<thread-id>/
~~~

Only immutable IDs participate in path identity.

Do **not** include:
- Space name;
- Thread name;
- User display name;
- User email;
- Workspace ID;
- Worker name;
- repository name.

### 3. Names never rename local work

Space and Thread names are presentation metadata only.

A user may rename a Space or Thread any number of times, including while a Run is active.

Renaming must not:
- rename the directory;
- restart a Worker;
- invalidate an active assignment;
- change local path resolution;
- require migration.

The immutable Space ID and Thread ID remain authoritative.

### 4. Workspace ID is not local work identity

Workspace ID represents the current registered runtime identity.

It is appropriate for:
- Cloud connection;
- runtime authorization;
- Worker readiness;
- credentials;
- capacity;
- Space Workspace Grants;
- audit.

It is **not** part of Thread directory identity.

If a Workspace is revoked/deleted and the same local installation is later registered as a new Workspace with a different Workspace ID, it resolves the same Space/Thread path and may safely reuse existing local work after validation.

### 5. Do not fingerprint physical hardware

The supported product model remains:

> one normal Conclave Workspace runtime per local OS-user installation.

The runtime already uses one local configuration/data directory and an exclusive process lock.

Conclave does not need motherboard IDs, MAC-address fingerprints, serial-number matching or another hardware identity system merely to preserve Thread storage.

A technically advanced user may be able to run a second runtime with a different local data root; that is not the normal product workflow and does not change Thread path semantics.

### 6. Thread directories are created lazily

Creating a Thread in Cloud does not need to create local filesystem state.

The runtime creates/ensures the directory when the first Work Request for that Thread executes on that Workspace.

Algorithmically:

~~~text
receive Assignment
-> validate Space/Thread authorization
-> resolve Work Root
-> resolve <space-id>/<thread-id>
-> validate or create marker
-> launch generic CLI Worker Engine with that directory as its Thread root
-> Engine resolves the signed Tool Profile and launches the provider CLI
~~~

The directory then persists across Work Requests.

### 7. Local marker protects safe reuse

Each Thread directory contains an internal metadata marker such as:

~~~text
.conclave-thread.json
~~~

The marker contains only stable non-secret identity metadata, for example:
- schema version;
- Space ID;
- Thread ID;
- creation timestamp.

It must not contain Space/Thread names, email addresses or provider secrets.

Before reusing an existing directory, the runtime validates that the marker matches the requested Space and Thread IDs.

If the path exists with a conflicting or missing identity marker in a situation where safe adoption cannot be proven, execution fails closed rather than overwriting unknown data.

### 8. Provider CLI working directory is runtime-resolved

Cloud sends logical execution identity:
- Space ID;
- Thread ID;
- Assignment/Run context.

Cloud does not send an arbitrary absolute working path.

A provider CLI process cannot select a working directory outside the runtime
policy.

Workspace resolves the local Thread directory and passes it to the generic
CLI Worker Engine. The Engine launches the provider CLI with that directory as
its working directory under the signed Tool Profile's execution policy.

All logical Workers participating in the same Thread on the same
Workspace use the same Thread directory.

### 9. Provider CLI-managed repositories

Conclave does not require a Space Source registry for the initial model.

Inside a Thread directory, a provider CLI may:
- clone zero, one or many repositories;
- create files;
- generate build outputs;
- use local tools;
- clone public or private Git repositories using locally available credentials.

Example:

~~~text
<work-root>/
  <space-id>/
    <thread-id>/
      .conclave-thread.json
      conclave/
      backend/
      notes/
~~~

Conclave does not automatically register, provision or own those repositories.

### 10. Git is the synchronization mechanism between Threads/machines

Two Threads may independently clone the same repository into their separate directories and execute in parallel.

Example:

~~~text
<space-id>/
  <thread-a>/
    conclave/
  <thread-b>/
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

Conclave may recommend a dedicated branch per Thread, but the initial architecture does not require Conclave to create or manage branches.

### 11. Changing Workspace does not transfer files

The same logical Space/Thread path may exist on multiple physical machines, but the data is local to each machine.

If a Thread changes Primary Workspace:
- the destination Workspace resolves the same relative ID path;
- if absent, it creates a new empty Thread directory;
- Conclave does not copy local files automatically;
- the provider CLI/user reconstructs required state through Git, downloads or
  explicit instructions.

The UI should warn that changing Workspace does not migrate uncommitted local state.

### 12. Thread execution uses a request-scoped lease

Removing managed checkouts does not remove the concurrency invariant. Each
Work Request containing a stateful Step acquires one runtime lease for its
Thread. The lease reserves the Primary Workspace and remains active until
that Work Request completes, fails, or is cancelled. Its fencing token is
checked before stateful execution mutates the Thread directory.

At most one stateful Work Request may run for a Thread at a time. This
request-level lock prevents another stateful request from interleaving between
Steps. Implement may write the directory. Test and Verify are stateful so they
run against the same Primary Workspace and filesystem state, but their
effective permissions are read-only.

Research and Plan are stateless read-only Steps. They may run concurrently on
other eligible granted Workspaces and do not mutate the Thread directory.
A multi-Step Work Request that contains any stateful Step retains its lease
throughout the request, including while its Research or Plan Step runs.
Different Threads may execute concurrently because their directories and
leases are distinct.

The request-scoped runtime lease orders stateful Work Requests and fences
filesystem mutations. It is independent of Git repository ownership.

### 13. Git recovery remains local

Because repository contents are provider CLI-managed, Conclave does not create
commits or restore Git state after failed Work. Git recovery remains with the
user and provider CLI.

Provider CLIs and users may use Git for those operations.

Conclave may later observe Git repositories and report branch/HEAD/dirty metadata without turning repositories into user-managed Source objects.

### 14. Lifecycle favors data preservation

- active Thread: retain local directory;
- completed Thread: retain;
- archived Thread: retain;
- deleted Cloud Thread: do not immediately delete local files automatically.

Local cleanup is an explicit operation.

This avoids destroying unpushed or otherwise valuable local work.

## Security invariants

1. Path identity uses immutable IDs only.
2. Space/Thread names never affect path resolution.
3. Workspace ID never affects Thread path identity.
4. User email/name never appears in the canonical path.
5. IDs are validated as safe single path components before path construction.
6. The resolved Thread directory must remain beneath Work Root.
7. Cloud cannot supply an arbitrary local absolute path.
8. Provider CLI processes cannot escape the working-directory policy by changing Space/Thread display names.
9. Existing directories are reused only after marker validation.
10. Re-registration must not silently adopt a directory belonging to different Space/Thread IDs.

## Consequences

### Positive

- simpler Conclave product and runtime;
- no Source/repository-management UI required;
- rename-safe by construction;
- Workspace re-registration does not orphan local work;
- multi-repository work requires no special product feature;
- parallel work on the same Git repository is naturally isolated by Thread;
- private repository credentials stay local;
- repository behavior remains in tools already designed to manage Git.

### Tradeoffs

- Conclave does not initially know authoritative repository provenance;
- automatic Git-state recovery is not provided;
- provider CLIs/users are responsible for Git synchronization;
- multiple Threads may duplicate repository clones;
- changing physical machine requires reconstructing local state;
- enterprise source governance can be added later if proven necessary.

## Core invariant

> **Local work belongs to Space + Thread identity, not to names, Workspace registration identity, or repositories. Workspace resolves the ID-derived path; a request-scoped lease fences stateful execution; the generic Engine and signed Tool Profile run the provider CLI inside that boundary.**
