# ADR-008: Project-Centric Collaboration and Workspace Grants

**Status:** Accepted; **Date:** 2026-09-24

## Context

Conclave collaboration and local execution have different security boundaries.
Sharing a local execution environment as the collaboration boundary can grant
more machine access than a person needs to contribute to a Project.

## Decision

Projects are the collaboration boundary. People receive Project membership and
roles. A Project uses a Workspace only through an explicit
`WorkspaceProjectGrant`.

A Workspace is one owner's local execution environment. It contains the
Workspace runtime, local Worker configuration, Work Root, provider CLI access,
and process supervision. Workspace ownership controls local administration.
Project membership does not itself grant Workspace ownership or local machine
access.

Logical Workers belong to a Workspace and are not independently shared.
Project and Workstream policy select eligible Workers only through a grant and
the applicable execution authorization checks. Provider credentials remain
local to provider CLI software and are not shared through Project membership
or a Workspace grant.

## Security invariant

> A Project may execute through a Workspace only when an explicit grant and
> current authorization checks allow it. Collaboration membership alone does
> not grant local Workspace administration or provider credentials.

## Consequences

- Collaboration follows Project membership and roles.
- Workspace ownership remains the boundary for local administration.
- Project-to-Workspace Grants are security-critical and require audit and
  revocation behavior.
- Workstream policy narrows how granted Workspace capacity is used.
- A future multi-Workspace fleet abstraction requires a concrete product need
  and a separate decision.
