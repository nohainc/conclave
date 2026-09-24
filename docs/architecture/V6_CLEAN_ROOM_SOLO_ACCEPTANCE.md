# V6 Clean-room solo acceptance

The V6 solo acceptance path is an executable contract and a clean SQLite schema
fixture. It starts with an empty database and requires this lifecycle:

1. sign in and create an execution Workspace;
2. connect a Worker and Account;
3. create a Project and grant the Workspace;
4. create a Workstream and provision its managed checkout;
5. record Discuss content;
6. create an explicit Work Request and complete its Workflow;
7. create a Checkpoint;
8. start the second iteration from that Checkpoint;
9. create a pull request integration record.

The second iteration must carry the first Checkpoint revision as its base. A
normal discussion message never satisfies the Work Request phase, and an
integration cannot be accepted without a pull-request URL.

The execution bridge required by this path is defined in
`migrations-v6/0005_execution_foundation.sql`: Worker versions and installations,
Workspace Project Grants, Project Account Grants, and assignment grant
correlation. It is a clean v6 migration and introduces no v4 compatibility
objects.
