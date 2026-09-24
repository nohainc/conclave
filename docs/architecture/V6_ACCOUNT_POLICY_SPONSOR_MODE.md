# V6 Account Policy and Sponsor Mode

Each Workstream declares an Account policy that narrows the Project's existing
Account grants:

- `requester` — use an Account the requester is authorized to use;
- `sponsor` — use only Accounts explicitly authorized by a Project Account
  Grant and permitted by the sponsor policy;
- `project_shared` — use Project-shared Accounts within the grant scope;
- `explicit_accounts` — use only the listed authorized Accounts;
- `auto_authorized` — select from Accounts authorized by the Project and the
  Workstream policy.

Workstream policy never creates Account authorization. Project Account Grants,
provider sharing restrictions, and local Account readiness remain authoritative.
The policy can only narrow the eligible set.

## Cost and identity

A Workstream may define an optional budget. Each Work Request may carry an
estimated cost before Run. Scheduler admission rejects a request when the
Workstream budget is exceeded or when no eligible Account remains.

Usage records both the requester and the Account owner, in addition to Project,
execution Workspace, Worker, provider/model, tokens, duration, and cost. This
keeps sponsored execution attributable without exposing Account secrets.

For stateful work, the selected Account must also be installed and ready on the
Primary Workspace. Provider private-only policies and revoked Project Account
Grants reject execution even when the Workstream policy would otherwise allow
the mode.
