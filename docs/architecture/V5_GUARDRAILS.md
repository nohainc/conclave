# Architecture v5 Guardrails

**Status:** Normative  
**Applies to:** all new code, schemas, protocols, UI copy, diagrams, tests, and documentation

Architecture v5 has one deliberate split:

> **Project is collaboration. Workspace is execution.**

Projects own shared history, membership, roles, instructions, runs, artifacts,
and Workspace Grants. Workspaces are user-owned execution environments backed
by one enrolled machine or runtime. A Project member does not receive execution
access unless an explicit Workspace Grant permits it.

## Terms that are forbidden in new v5 surfaces

Do not introduce any of the following as active concepts:

- Workspace membership as execution authorization;
- `host_workspace_bindings` or an equivalent Host-to-collaborative-Workspace binding;
- new `host.use` checks or Workspace-role permission inheritance;
- user-facing Host labels for execution environments;
- Workspace switching, Workspace invitations, or Workspace-owned Projects;
- Workspace-owned credential logic;
- Project authorization derived from collaborative Workspace membership.

The terms may appear in historical v4 documents, migration notes, source-audit
tables, or compatibility-removal tests only when clearly marked as historical
or forbidden.

## Required v5 vocabulary

Use these terms for active architecture:

| Concern | Canonical term |
| --- | --- |
| Collaboration boundary | Project |
| Shared people and roles | Project Membership |
| Execution environment | Workspace |
| Project-to-execution authorization | Workspace Grant / `WorkspaceProjectGrant` |
| Machine and connection identity | Workspace Runtime Identity |
| Installed AI/tool capability | Worker |
| External provider identity | AI Account / `CredentialProfile` internally |

The runtime implementation may remain under `apps/host` during migration, but
that path does not authorize the Host noun in user-facing copy or new domain
contracts.

Active product copy, diagrams, desktop labels, and navigation must use
Workspace for the execution environment. `host.*` protocol names, generated
bindings, package paths, and other low-level migration aliases may remain
until the protocol/runtime migration is complete, but they must not surface in
the product UI.

## Review questions

Every new v5 change must answer yes to all applicable questions:

1. Is collaboration authorized from Project membership?
2. Is execution authorized from an explicit Workspace Grant?
3. Is AI Account use granted independently from Workspace access?
4. Are historical v4 terms isolated from the active model?
5. Does the change preserve the effective permission intersection defined by
   Architecture v5?
