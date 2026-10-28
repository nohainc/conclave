# GitHub Actions

Syntila runs five workflows. Everything that gates a merge, a deploy, or a release goes through one aggregate check, `CI passed`.

| Workflow | Runs when | Purpose |
| --- | --- | --- |
| `ci.yml` | Pull requests, pushes to `main`, manual runs | Static guard, then only the domains a change touches. `CI passed` is the required check. |
| `deploy-cloud.yml` | Manual, from `main` only | Deploys the Cloud Worker to app.conclaveax.com. Requires passing CI for the commit. Environment `production`. |
| `deploy-site.yml` | Site pull requests, site pushes to `main`, manual | Preview Worker per pull request, deleted when it closes. Production site on `main`. |
| `release-macos.yml` | Manual, from `main` only | Signed and notarized Workspace, or an internal Profile Lab build. Requires passing CI. |
| `nightly.yml` | Daily 02:00 UTC, manual | Native macOS builds that are too slow for every pull request. |

Shared setup lives in `.github/actions/` (`setup-workspace`, `setup-flutter`, `check-site`). Helper scripts live in `scripts/ci/`. Repository protection is defined in `scripts/github/apply-repo-settings.sh`.

## Rules for changing workflows

Every action is pinned to a commit SHA with its version in a comment. Dependabot proposes updates weekly. Changes to `.github/`, `scripts/ci/`, `scripts/github/`, `scripts/release/`, and `infra/` require the code owner's review.

Production secrets are only available to jobs in the `production`, `production-site`, `workspace-release`, and `profile-lab-release` environments. Pull requests from forks never receive secrets. Forks need approval before any workflow runs.

Path filters are computed in `scripts/ci/detect-changes.sh`. A change to shared tooling (`.github/`, `scripts/`, root configs, lockfile) runs every CI domain, so the filters cannot skip tests they are responsible for.

## Applying repository settings

Run `scripts/github/apply-repo-settings.sh` as a repository admin. It is a dry run until you pass `--apply`, and it is safe to run again. The settings it applies are described in the script header.
