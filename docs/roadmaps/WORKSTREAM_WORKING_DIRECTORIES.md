# Workstream Working Directories — Implementation Roadmap

**Status:** WD-0 accepted; implementation in progress
**Architecture:** [ADR-011](../decisions/ADR-011-workstream-working-directories.md)  
**Builds on:** Architecture v6  
**Date:** 2026-09-25

## Target outcome

For every Workstream executing on a Workspace, Conclave provides exactly one stable local directory:

~~~text
<work-root>/<project-id>/<workstream-id>/
~~~

Project/Workstream display names and Workspace IDs never participate in the path.

Workers execute inside that directory and may clone/manage any repositories they need.

This roadmap intentionally avoids introducing Source registration, repository provisioning or Conclave-managed Git worktrees.

---

## WD-0 — Freeze filesystem invariants

### Goal

Make path ownership and identity unambiguous before implementation.

### Lock these rules

- one normal Workspace runtime per OS-user installation;
- Workspace has one local Work Root;
- directory identity = Project ID + Workstream ID;
- names are never path components;
- email/user display name is never a path component;
- Workspace ID is never a path component;
- repository names are never required path components;
- Workstream directory is persistent local state;
- Workers receive runtime-resolved CWD;
- repositories inside the directory are Worker-managed;
- one Workstream mutation at a time;
- different Workstreams may run in parallel.

### Exit

All implementation PRs can rely on one canonical path model.

---

## WD-1 — Work Root configuration

### Goal

Create a stable local root independent of Workspace enrollment identity.

### Runtime

Introduce a Work Root resolver with:
- platform-appropriate default;
- normalized canonical path;
- directory creation;
- local ownership/permission hardening;
- optional advanced override.

### Important separation

Do not place Work Root beneath ephemeral Workspace enrollment state if resetting/re-pairing the Workspace would remove or relocate it.

Runtime configuration and work data have separate lifecycle boundaries.

### UX

Normal users should not need to configure the path.

Workspace diagnostics/settings may expose:
- Work Root location;
- Open in Finder/File Explorer;
- advanced change action when no conflicting active work exists.

### Tests

- default resolution on macOS/Linux/Windows;
- custom root;
- nonexistent root creation;
- permission failure;
- root change validation;
- root survives Workspace re-enrollment.

### Exit

Workspace always has one safe Work Root.

### Implementation note

The Workspace runtime now resolves the platform default or the advanced
`--work-root` / `CONCLAVE_HOST_WORK_ROOT` override at startup, creates the root,
canonicalizes it, and applies local directory permissions. The Work Root is
separate from enrollment configuration and is not derived from Workspace ID.

---

## WD-2 — Deterministic ID-only path resolver

### Goal

Resolve Workstream directory without names or Workspace ID.

### Contract

Input:
- projectId;
- workstreamId.

Output:

~~~text
<work-root>/<project-id>/<workstream-id>
~~~

### Validation

Both IDs:
- required;
- immutable Cloud IDs;
- safe single path components;
- cannot be "." or "..";
- cannot contain path separators;
- cannot resolve outside Work Root.

### Explicit non-inputs

Resolver API must not accept:
- Project name;
- Workstream name;
- email;
- Workspace ID;
- arbitrary relative path from Cloud.

### Tests

- rename has zero path effect;
- malicious IDs/path traversal;
- Unicode/name changes irrelevant;
- Project IDs separate same Workstream-like values;
- deterministic result across process restarts.

### Exit

One pure resolver defines all Workstream local paths.

### Implementation note

`apps/host/lib/workstream_path.dart` is the sole WD-2 resolver. It accepts only
`projectId` and `workstreamId`, returns a non-created path beneath the
canonical Work Root, and fails closed for unsafe IDs or filesystem escapes.
Display names, email addresses, Workspace IDs, and Cloud-supplied relative
paths are intentionally absent from its API.

---

## WD-3 — Workstream identity marker

### Goal

Safely distinguish reusable Conclave directories from unknown filesystem content.

### Marker

Create:

~~~text
.conclave-workstream.json
~~~

with:
- schemaVersion;
- projectId;
- workstreamId;
- createdAt.

Optional safe runtime metadata may be added later.

Never store:
- names;
- email;
- provider secrets;
- raw credentials.

### Creation

Use atomic write semantics.

### Reuse

If directory exists:
1. read marker;
2. validate schema;
3. match Project ID;
4. match Workstream ID;
5. only then reuse.

### Conflict

If path contains unknown/conflicting data:
- fail closed;
- show actionable diagnostics;
- never delete/overwrite automatically.

### Tests

- valid reuse;
- mismatched Project;
- mismatched Workstream;
- corrupt marker;
- missing marker;
- interrupted marker creation.

### Exit

Reusing existing work directories is safe and deterministic.

### Implementation note

`apps/host/lib/workstream_marker.dart` creates the v1 identity marker with a
temporary file and atomic rename under a creation lock. Reuse requires a valid
schema, UTC creation timestamp, and exact Project/Workstream ID match. Missing,
corrupt, mismatched, non-empty-adoption, and interrupted-creation states fail
closed without overwriting local data.

---

## WD-4 — Lazy Workstream directory lifecycle

### Goal

Create local state only when execution actually needs it.

### Trigger

First executable Work Request for the Workstream on the Workspace.

Do not create a local directory merely because:
- Project exists;
- Workstream exists;
- user is discussing;
- user renamed something.

### Runtime flow

~~~text
Assignment
-> authorize
-> resolve IDs
-> ensure directory
-> validate marker
-> acquire Workstream mutation lock when stateful
-> execute
~~~

### Persistence

Directory remains after a Run completes.

### Tests

- Discuss creates no local directory;
- first Work creates directory;
- second Work reuses it;
- restart reuses it;
- Workstream rename during active Run causes no filesystem action.

### Exit

Local storage follows execution, not Cloud object creation.

### Implementation note

`apps/host/lib/workstream_directory.dart` exposes the execution-only
`ensureForExecution` entry point. It creates the ID-derived directory lazily,
writes the marker before returning it, and validates the marker on every later
use or runtime restart. Discussion and Cloud object lifecycle code do not call
this service.

---

## WD-5 — Assignment protocol and runtime CWD

### Goal

Make Project/Workstream identity sufficient for process working-directory selection.

### Assignment context

Stateful assignments must carry:
- projectId;
- workstreamId;
- run/workRequest identity;
- configured Worker identity;
- authorization snapshot.

They do not carry an arbitrary absolute CWD.

### Runtime

Before Worker launch:
- resolve Workstream directory;
- verify marker;
- set Worker process CWD to that directory.

Every configured Worker used by the same Workstream on the same Workspace receives the same CWD.

### Worker protocol

Expose logical context where useful:
- Project ID;
- Workstream ID;
- Work Request ID.

Do not require the Worker to reconstruct the path itself.

### Tests

- Codex then Claude see same files in one Workstream;
- another Workstream receives different CWD;
- Cloud-injected path ignored/rejected;
- active rename has no effect.

### Exit

CWD is a runtime guarantee, not a Worker convention.

### Implementation note

`WorkerAssignmentHandler.prepareProcessSpec` now resolves scoped assignment
CWD through `WorkstreamDirectoryLifecycle` and replaces any package-default
working directory before launch. Stateful assignments require Project and
Workstream IDs; Cloud-supplied `cwd`, `workdir`, and working-directory fields
are rejected. The Worker receives logical Project/Workstream/Work Request
correlation in its execution payload, not a path-construction contract.

---

## WD-6 — Preserve Workstream mutation serialization

### Goal

Keep safe concurrent execution without relying on Git-worktree ownership.

### Rule

One Workstream directory has at most one active mutating/stateful Work Request.

### Keep/adapt

Retain the Workstream execution coordinator/lease concept for:
- queue ordering;
- cancellation;
- stale assignment rejection;
- one active mutator;
- recovery after runtime disconnect.

Rename checkout-specific terminology where necessary.

### Parallelism

Allowed:

~~~text
Project
  Workstream A -> directory A -> stateful execution
  Workstream B -> directory B -> stateful execution
~~~

Not allowed:

~~~text
Workstream A -> two simultaneous mutators of directory A
~~~

### Tests

- same Workstream serializes;
- different Workstreams run concurrently;
- stale lease rejected;
- Workspace reconnect does not double-run mutation.

### Exit

Filesystem simplicity does not create race conditions.

### Implementation note

`WorkstreamMutationCoordinator` serializes stateful Worker execution by the
Project/Workstream directory, with an in-process queue and an OS file lock for
cross-process protection. It persists a Workstream fencing token and rejects
older or conflicting leases after restart/reconnect. Different Workstream
directories remain independent; the existing assignment journal and checkout
fencing continue to protect replay and checkout-specific recovery paths.

---

## WD-7 — Remove Source/checkout provisioning from the required flow

### Goal

Stop making repository knowledge a prerequisite for Work.

### Remove from required execution path

- Project repository requirement;
- Source registration;
- Source selection;
- repository mapping needed only to choose CWD;
- Workstream checkout provisioning;
- Conclave-managed Git worktree creation;
- automatic Workstream branch creation.

### Cloud

A Workstream can execute with an empty directory.

The user's request/Worker decides what to create or clone.

### Migration

Existing checkout/repository metadata may remain temporarily for compatibility but cannot be required by the new path resolver.

Because Conclave is pre-production, prefer removing obsolete schema/flows once the new path is proven.

### Exit

"Run work in this Workstream" does not require repository configuration.

### Implementation note

Stateful assignment dispatch now falls back to the marker-backed Workstream
directory when no complete checkout snapshot is present. Checkout provisioning
and checkout fencing remain optional compatibility/recovery layers; they are no
longer prerequisites for executing Work in an empty Workstream directory.

---

## WD-8 — AI-managed repository guidance

### Goal

Define consistent Worker behavior without turning Git into a Conclave product subsystem.

### System execution context

Tell Worker:
- this directory is the Workstream's persistent isolated working area;
- reuse existing files/repositories when present;
- clone repositories here when needed;
- do not assume the directory is disposable;
- use normal Git safety practices.

### Git recommendation

For parallel Workstreams using the same repository:
- prefer a dedicated branch per Workstream;
- fetch before integrating remote changes;
- commit/push meaningful state before moving to another physical Workspace.

This is guidance, not a Conclave-managed branch lifecycle.

### Private repositories

Use Workspace-local Git/SSH/GitHub CLI/provider authentication.

Cloud should not require repository credentials.

### Tests

Prompt/context tests only where applicable; do not implement a Git orchestration engine.

### Exit

Workers know how to use the persistent directory safely.

### Implementation note

The Host adds provider-independent `workstreamExecutionGuidance` to the
logical Worker context. It explains persistence, reuse, cloning, normal Git
safety, parallel Workstream branches, and Workspace-local authentication. No
repository path, credential, branch lifecycle, or Git orchestration is added
to the Cloud contract.

---

## WD-9 — Workspace revoke/re-enrollment continuity

### Goal

Ensure a new Workspace ID on the same local installation can reuse existing work.

### Scenario

1. Workspace A executes Project P / Workstream W.
2. Directory exists at `<root>/P/W`.
3. Workspace A is revoked/deleted.
4. local app is paired again and receives Workspace B ID.
5. Project P / Workstream W executes again.
6. runtime resolves the same `<root>/P/W`.
7. marker validates and work continues.

### Explicit rule

No mapping from old Workspace ID to new Workspace ID is needed.

### No hardware fingerprint

Do not add device serial/MAC/motherboard matching for this feature.

### Tests

- re-pair with new Workspace ID;
- runtime config reset while Work Root preserved;
- marker reuse;
- credential/Worker state may require setup again while work files remain.

### Exit

Workspace identity can change without orphaning local Workstream data.

### Implementation note

Continuity is provided by the Work Root plus Project/Workstream IDs only.
Re-pairing with a new Workspace runtime identity reuses the same marker-backed
directory without any old-to-new Workspace mapping or hardware fingerprint.
Worker package and credential readiness may require setup again independently;
local Workstream files remain available.

---

## WD-10 — Primary Workspace change / another machine

### Goal

Handle the case where logical Workstream moves to a different physical machine.

### Behavior

Destination Workspace computes the same relative:

~~~text
<project-id>/<workstream-id>
~~~

but under its own local Work Root.

If absent:
- create a new empty directory + marker;
- do not pretend local files were migrated.

### UX warning

Before changing Primary Workspace while local mutable state may exist:

> Local files are not transferred automatically. Commit/push or otherwise preserve required state before continuing on another Workspace.

### Recovery

Worker may reconstruct state by:
- cloning repository;
- fetching branch;
- downloading artifacts;
- following explicit user instructions.

### Exit

Cross-machine behavior is explicit rather than magical.

### Implementation note

`WorkstreamDirectoryLifecycle` resolves the same Project/Workstream relative
location under each destination Work Root. A destination with no existing
directory receives only a new empty directory and identity marker; local files
are never represented as migrated. `WorkstreamWorkspaceChangePolicy` exposes
the required warning when mutable local state exists.

---

## WD-11 — Simplify Cloud persistence

### Goal

Avoid storing local absolute paths in Cloud.

### Cloud stores

- Project ID;
- Workstream ID;
- Primary Workspace/policy;
- execution state;
- authorization;
- Runs/Work Requests.

### Cloud does not need initially

- absolute work directory;
- local folder name;
- repository clone path;
- Source record solely for CWD;
- checkout path.

Optional runtime readiness may be reported as:

~~~text
workingDirectoryState = absent | ready | conflict | unavailable
~~~

without exposing the local path to collaborators.

### Exit

Cloud models logical identity, runtime models local filesystem location.

---

## WD-12 — Repository observability as optional follow-up

### Goal

Gain useful visibility without reintroducing Source management.

### Runtime may discover

Within a Workstream directory:
- Git repositories;
- remotes;
- current branch;
- HEAD;
- dirty state.

### Product behavior

Read-only/diagnostic only initially.

Example Work summary:

~~~text
Repositories
- nohainc/conclave · branch auth-passkeys · 3 files changed
~~~

### Constraints

- discovery must not determine Workstream path;
- no repository must be registered to execute;
- Conclave does not silently change branch/remote.

### Exit

Observability improves without adding setup burden.

### Implementation note

`apps/host/lib/workstream_repository_observability.dart` provides the
read-only `WorkstreamRepositoryDiscovery` service. It accepts only a directory
already resolved by the runtime and reports repository-relative path, remotes,
branch, HEAD and dirty-file count. Remote locations are sanitized so userinfo,
query parameters and fragments are not exposed. Discovery skips symlinked
directories outside the Workstream and has no effect on execution, branches,
remotes or Cloud persistence.

---

## WD-13 — Local cleanup lifecycle

### Goal

Avoid accidental data loss.

### Defaults

- completed: retain;
- archived: retain;
- Cloud-deleted: retain locally;
- Workspace revoked: retain locally;
- app update: retain.

### Explicit cleanup

Future/local Workspace control may:
- show orphaned/archived Workstream directories;
- estimate disk usage;
- delete only after explicit confirmation.

### Safety

Before deletion:
- marker must validate;
- no active assignment;
- no active Workstream lock;
- clear warning that unpushed data may be lost.

### Exit

Conclave never silently deletes meaningful local work.

### Implementation note

`apps/host/lib/workstream_cleanup.dart` provides an explicit local cleanup
review and deletion service. It discovers only marker-backed ID-derived
Workstream directories, reports best-effort disk usage, and accepts an
optional Cloud/read-model classification such as archived or Workspace
revoked. Deletion requires the exact Workstream confirmation text, an active
assignment check, marker revalidation, and an exclusive Workstream lock. The
locked directory is moved aside before the lock is released, then removed;
normal execution, archive, revoke and app-update paths never call this
service.

---

## WD-14 — Rename stress acceptance

### Scenario

While one Worker is actively editing files:

1. rename Workstream;
2. rename Project;
3. rename Workstream again;
4. continue Work;
5. switch to another configured Worker;
6. complete Work Request.

### Verify

- process remains alive;
- CWD unchanged;
- marker unchanged;
- subsequent Worker sees same files;
- Cloud/UI shows new names;
- no directory migration task is created.

### Exit

Display names are proven independent from execution identity.

### Implementation note

`apps/host/test/workstream_rename_acceptance_test.dart` exercises the rename
scenario with two real local Worker processes. The first Worker edits the
persistent directory while Project and Workstream display names change; the
second Worker resolves the same CWD and continues from the same files. The
test also verifies that the identity marker and directory topology remain
unchanged.

---

## WD-15 — Parallel same-repository acceptance

### Scenario

Two Workstreams in the same Project both work on `nohainc/conclave`.

Each independently clones/uses the repository:

~~~text
<project-id>/
  <workstream-a>/conclave/
  <workstream-b>/conclave/
~~~

Verify:
- both run concurrently;
- files never overlap;
- different branches may be used;
- one Workstream cannot mutate the other's directory through normal assignment CWD;
- normal Git push/pull/PR is sufficient to integrate work.

### Exit

Parallel feature work needs no Source/worktree subsystem.

### Implementation note

`apps/host/test/workstream_parallel_repository_acceptance_test.dart` creates
two independent `conclave` repositories under separate ID-derived Workstream
directories in one Project. Two Worker processes edit them concurrently,
then commit and push separate branches to a local bare remote. The acceptance
asserts distinct runtime CWDs, non-overlapping files and ordinary Git branch
integration without Source registration or Conclave-managed worktrees.

---

## WD-16 — Security acceptance

Test:
- `..` IDs;
- slash/backslash IDs;
- symlinked Work Root edge cases;
- marker mismatch;
- missing/corrupt marker;
- arbitrary Cloud CWD attempt;
- malicious Project/Workstream rename;
- Workspace ID change;
- concurrent mutation replay;
- delete while active;
- permissions on newly created directories.

### Exit

ID-only path resolution is safe against traversal, confusion and accidental reuse.

### Implementation note

`apps/host/test/workstream_security_acceptance_test.dart` covers traversal and
separator IDs, escaping symlinks, marker adoption failures, arbitrary CWD
injection, rename/re-enrollment continuity, stale mutation replay and active
cleanup protection. Existing Work Root tests cover permission hardening and
newly-created root behavior; the runtime CWD tests cover assignment-level
path rejection.

---

## WD-17 — Architecture cleanup

Remove or mark historical where superseded:
- WorkstreamCheckout as mandatory repository worktree;
- checkout provisioning control plane;
- repository-required stateful Work;
- automatic checkpoint commit/rollback guarantees;
- Source/repository path as primary execution identity.

Retain:
- Workstream;
- explicit Work Requests;
- configured Workers;
- Primary Workspace;
- execution serialization/lease;
- authorization;
- Run/Artifact/Usage correlation.

### Exit

One filesystem model remains active in v6 docs and source.

### Implementation note

The active architecture now treats Checkout provisioning, repository-required
Work, automatic checkpoint commits and automatic rollback as historical
compatibility behavior. The canonical execution path is the ID-derived
Workstream directory, Workstream mutation lease, explicit Work Request and
Worker-managed repository state. Legacy checkout types and protocol names are
annotated as compatibility-only while their removal is coordinated with the
next clean schema reset.

---

## WD-18 — End-to-end acceptance

From an empty development environment:

1. sign in;
2. enroll Workspace;
3. configure Worker;
4. create Project;
5. create Workstream;
6. rename Project;
7. rename Workstream;
8. run Work;
9. runtime creates `<project-id>/<workstream-id>`;
10. Worker clones a repository;
11. second Worker continues in same directory;
12. create a second Workstream and work on same repo in parallel;
13. revoke/re-enroll Workspace locally;
14. continue first Workstream from the existing directory;
15. verify names and Workspace ID never affected path identity.

### Exit

The complete flow proves the three-line model:

> Workspace = machine.  
> Workstream = isolated persistent work directory.  
> Workers manage repositories inside it.

### Implementation note

`apps/host/test/workstream_end_to_end_acceptance_test.dart` exercises the
clean-room local runtime path with a temporary Work Root and a local Git
remote. It verifies repository cloning by one Worker, continuation by a second
Worker, isolation for a parallel Workstream, display-name renames, and reuse
after a new Workspace runtime identity is enrolled. The test intentionally
keeps sign-in, Cloud Project creation, and Worker configuration at the
acceptance boundary; those are control-plane prerequisites, while the
filesystem guarantee is owned by the runtime.

## Recommended delivery order

1. WD-0 invariants
2. WD-1 Work Root
3. WD-2 path resolver
4. WD-3 marker
5. WD-4 lazy lifecycle
6. WD-5 assignment CWD
7. WD-6 mutation serialization
8. WD-7 remove required checkout/source flow
9. WD-8 Worker repository guidance
10. WD-9 re-enrollment continuity
11. WD-10 cross-machine behavior
12. WD-11 Cloud persistence simplification
13. WD-12 optional observability
14. WD-13 cleanup
15. WD-14..18 acceptance and cleanup

## Sequencing rule

> First make ID-only Workstream CWD resolution reliable end-to-end. Only then remove the old managed-checkout/source code paths. Do not make repository provisioning a prerequisite for the replacement flow.
