# ADR-004: Simplify execution to Host + Worker

**Status:** Accepted  
**Date:** 2026-09-22  
**Supersedes:** ADR-003 execution topology

## Context

Architecture v3 separated:
- Agent App;
- Agent Engine;
- Worker Plugin;
- configured Worker instance.

This provided strong boundaries but produced unnecessary product/domain complexity for a pre-production system.

It also mixed three concerns:
- machine identity;
- installable integration;
- user-specific account credentials.

## Decision

Adopt:

```text
Studio -> Cloud -> Host -> Worker
```

with **Credential Profile** as the account/auth context used by an Assignment.

### Host
One installation per machine.

### Worker
One installable AI/tool integration.

### Credential Profile
One user/workspace account identity for a Worker.

### Assignment
One execution snapshot resolving Host + Worker + Credential Profile.

## Additional decisions

1. Studio is web-first only for v4.
2. Agent App and Agent Engine merge into one Flutter/Dart Host application.
3. Worker processes remain separate child processes.
4. A Worker package is installed once per Host and supports parallel assignments.
5. Credential Profiles are private by default and may be shared explicitly.
6. Host identity is independent from human User identity.
7. Hosts may bind to multiple Workspaces.
8. Worker installation/update/removal is desired-state driven from Cloud/Studio.
9. There is no persistent configured Worker-instance entity in v4.
10. Development D1 is reset to a clean v4 schema rather than compatibility-migrated.

## Consequences

### Positive
- fewer concepts;
- simpler UX;
- less duplicated schema/protocol state;
- no per-user Host installation;
- clean cost/credential attribution;
- automatic Worker lifecycle;
- easier multi-user sharing;
- simpler repository.

### Tradeoffs
- Host UI/runtime failure is one process boundary;
- quitting Host interrupts local work;
- migration touches protocol, schema, Studio, Host, and orchestration;
- Credential Profile authorization becomes security-critical.

Worker child processes preserve the most important execution isolation.

## Revisit conditions

Reintroduce a separate Host background daemon only if measured requirements show a strong need for:
- assignments surviving Host UI crashes;
- always-on service behavior independent of desktop session;
- privileged OS separation.

Do not pre-emptively preserve the v3 Agent Engine split.
