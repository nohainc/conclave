# V6 Architecture Cleanup Gate

The V6 gate searches active TypeScript, JavaScript, and Dart source for
forbidden architectural remnants:

- collaborative Workspace-role authorization and Host Workspace bindings;
- configured Worker fallback;
- Chat-driven Goal/Run creation;
- mutable assignment paths based on registered repositories;
- arbitrary user-supplied worktree paths.

V4 migrations, explicitly historical source modules, documentation, and tests
are excluded from the active-source scan. The gate is exposed as
`v6:architecture-gate` and must pass before the V6 release gate. Any remaining
compatibility implementation must first be removed from the active path or be
relocated and explicitly marked historical.
