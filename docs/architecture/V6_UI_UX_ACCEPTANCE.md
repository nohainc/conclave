# V6 UI/UX acceptance

The normal app vocabulary is intentionally product-facing:

- Execution is the top-level area for runtime resources;
- Workspaces are execution environments;
- Workers are configured AI/tool identities;
- a Project is the team’s shared space;
- a Workstream is one thing the team is working on;
- Discuss is where people talk and share context;
- Work is where AI acts after an explicit Run;
- a Workspace is the computer/runtime that provides execution capacity;
- a Workflow describes how AI work is performed.

There is no primary AI Accounts or Credential Profiles surface. Authentication
and provider readiness are shown only as Worker setup/status details, while
secret material remains local to the relevant Workspace.

Normal Project and Workstream screens do not expose lease, fencing token,
Durable Object, or checkout-key terminology. Those implementation details
remain runtime and diagnostics concepts only.
