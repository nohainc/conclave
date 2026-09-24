# ADR-008: Project-Centric Workspaces

**Status:** Proposed
**Date:** 2026-09-24
**Supersedes when accepted:** ADR-004 multi-Workspace Host sharing decisions

## Context

Architecture v4 uses Workspace as both a collaboration tenant and the authorization boundary for shared Hosts.

A Workspace member may receive `host.use`. Since Workers can have filesystem, shell, repository, browser, network and tool capabilities, joining a shared Workspace can grant indirect execution access to another user's machine.

This is broader than the intended collaboration action: share a Project.

The term Host is also infrastructure-oriented and exposes a low-level concept in the product.

## Decision

Adopt a Project-centric collaboration model and rename the user-facing Host concept to Workspace.

### Workspace

One execution environment backed by one enrolled machine/runtime.

A Workspace contains:
- Workers;
- runtime capacity;
- repository/path registrations;
- local permissions;
- local credential material;
- update/runtime state.

A Workspace has one owner User in v5.

### Project

The collaboration boundary.

Users are invited to Projects, not Workspaces.

A Project can use a Workspace only through an explicit `WorkspaceProjectGrant`.

### Worker

Installed inside a Workspace. Workers are not separately shared.

### AI Account

Separately authorized. A Workspace Grant never grants AI Account use.

### Runtime identity

The machine credential and connection identity remain internal even though the product noun becomes Workspace.

## Consequences

### Positive
- collaboration matches user intent;
- much smaller blast radius when inviting someone;
- execution resources are explicitly scoped;
- cleaner sidebar and navigation;
- no Workspace switching;
- simpler human authorization;
- strong reuse of current runtime security;
- Project memberships already exist as a useful foundation;
- Workers remain naturally attached to one execution environment.

### Tradeoffs
- substantial schema migration;
- Host terminology touches Cloud, Flutter, Dart, protocols and docs;
- Project Workspace Grants become security-critical;
- path/permission scoping must become production-grade;
- some team-wide administration moves to a future Organization concept.

## Rejected alternatives

### Keep collaborative Workspace and add Project visibility only

Rejected because Workspace membership would still be tied to shared execution infrastructure and remain too broad.

### Make Workspace personal but keep it as a hidden 1:1 user container

Rejected because a permanent User -> personal Workspace container adds an unnecessary domain layer.

### Direct User -> Host sharing

Rejected as the primary model because it creates resource-by-resource sharing graphs and does not align with Project collaboration.

### Workspace as a multi-machine fleet

Deferred. v5 keeps one Workspace = one runtime identity. A future Pool/Fleet may aggregate Workspaces if measured requirements justify it.

## Security principle

> A Project member may execute only through resources explicitly granted to that Project, and only within the effective permission intersection for that Assignment.
