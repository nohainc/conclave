# CI Checks and Evidence

GitHub Actions is the source of truth for repository CI results. The workflow runs the configured TypeScript, Cloud startup, Workspace, Flutter, and site checks. GitHub retains each result with its workflow run and commit revision.

Conclave Cloud no longer accepts per-run CI evidence. The former `/api/runs/:runId/ci-evidence` endpoint and its credential are removed because they depended on the pre-v8 run and evidence tables. Do not configure a CI ingest URL or token.

For release reviews, link the GitHub Actions run and its commit SHA in the release record.
