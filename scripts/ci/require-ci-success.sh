#!/usr/bin/env bash
# Passes only when ci.yml succeeded on main for the commit being deployed or released.
# Used as the gate in front of production deploys and release builds.
set -euo pipefail

: "${GITHUB_REPOSITORY:?}" "${GITHUB_SHA:?}" "${GITHUB_REF:?}" "${GH_TOKEN:?}"

if [[ "$GITHUB_REF" != "refs/heads/main" ]]; then
  echo "Deployments and releases must run from main (got ${GITHUB_REF})." >&2
  exit 1
fi

count="$(gh api "repos/${GITHUB_REPOSITORY}/actions/workflows/ci.yml/runs?head_sha=${GITHUB_SHA}&per_page=100" \
  --jq '[.workflow_runs[] | select(.event == "push" and .head_branch == "main" and .status == "completed" and .conclusion == "success")] | length')"

if [[ "$count" -lt 1 ]]; then
  echo "No successful CI run on main for ${GITHUB_SHA}. Wait for CI to pass, then retry." >&2
  exit 1
fi

echo "CI passed for ${GITHUB_SHA} (${count} successful run(s))."
