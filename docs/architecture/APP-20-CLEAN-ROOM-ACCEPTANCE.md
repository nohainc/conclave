# APP-20 — Clean-room first-user acceptance

`apps/cloud/test/application-e2e.test.ts` is the executable Cloud-side
acceptance for a new Conclave AX user. It creates an empty v4 D1 database,
applies the current migrations, and seeds only the globally available Codex
Worker catalog entry and signed version metadata. It does not seed a user,
Workspace, Project, Host, Account, installation, or assignment.

The test then uses the same authenticated HTTP boundary used by the app to
verify this order:

1. create an account and receive a Better Auth session;
2. provision the personal Workspace;
3. enroll a Host;
4. enable the Codex Worker for that Host;
5. connect a private Codex Account without placing a secret in D1;
6. create a Project and Chat;
7. submit `Review this repository and improve authentication`;
8. observe a bounded progress event and durable run/task/verification events;
9. reload the Project, Chat, and Run read models and verify the completed
   result;
10. invite a second user and verify Host visibility and private Account
    isolation.

The workflow binding is replaced only by a deterministic test execution
adapter. It uses the production event publisher and the production D1 schema,
so the acceptance verifies the Cloud contract without contacting an external
AI provider. It is not a substitute for a rendered Flutter browser test or a
real macOS Host/Worker installation test; those remain release-gate coverage
for the Host and application environments.

Run it with:

```bash
pnpm app:e2e
```

No database manipulation, manual API call, development fixture, or command-line
workaround is required when running the automated acceptance.
