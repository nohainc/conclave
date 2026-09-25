# V6 Configured Worker Policy and Sponsor Mode

Each Workstream declares a configured-Worker policy that narrows the Project's
authorized Worker set:

- `requester` — use a Worker the requester is authorized to use;
- `sponsor` — use only Workers explicitly authorized by the sponsor and
  Project policy;
- `project_shared` — use Project-shared Workers within the grant scope;
- `explicit_workers` — use only the listed authorized Workers;
- `auto_authorized` — select from Workers authorized by the Project and the
  Workstream policy.

Workstream policy never creates Worker or credential authorization. Project
Worker grants, provider sharing restrictions, and local credential readiness
remain authoritative.
The policy can only narrow the eligible set.

## Cost and identity

A Workstream may define an optional budget. Each Work Request may carry an
estimated cost before Run. Scheduler admission rejects a request when the
Workstream budget is exceeded or when no eligible Worker remains.

Usage records the requester, Worker owner, and credential owner where needed,
in addition to Project, execution Workspace, Worker, provider/model, tokens,
duration, and cost. This keeps sponsored execution attributable without
exposing credential secrets.

For stateful work, the selected Worker must also be bound, installed, and ready
on the Primary Workspace. Provider private-only policies and revoked Worker or
credential grants reject execution even when the Workstream policy would
otherwise allow the mode.
