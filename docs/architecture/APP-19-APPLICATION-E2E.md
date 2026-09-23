# APP-19 — Real application E2E coverage

The Cloud application flow suite in `apps/cloud/test/application-e2e.test.ts`
uses the production Worker router, Better Auth email sessions, the v4 schema,
and a D1-compatible SQLite database. It models separate browser sessions with
HttpOnly session cookies and validates the application boundary rather than
calling handlers directly.

The covered path includes:

- first-user signup and personal Workspace provisioning;
- Project and Chat creation;
- Chat execution intent and Run creation/completion;
- Host enrollment and Worker desired state;
- private and Workspace Accounts;
- project read-model and Chat/Run refresh reads;
- invitation acceptance, Workspace switching, shared Host visibility, and
  private Account isolation for a second user.

The Workflow binding is the only execution boundary replaced by a deterministic
test double. External AI execution remains outside this test and should be
covered by Worker-level contract tests.

The `0006_workflow_execution_records.sql` migration is part of the v4 chain and
stores the idempotent Cloudflare Workflow identity used to recover Runs after a
Cloud restart. Project read-model requests use focused v4 queries and do not
depend on removed v3 plugin tables.

Run the suite with `pnpm app:e2e`. It is also run as a dedicated CI job step in
addition to the regular Cloud test collection.
