# Local and production environments

Syntila has two environments. They never share a database, Cloud URL or Workspace state.

| | Local | Production |
|---|---|---|
| Cloud API | `wrangler dev` on `http://localhost:8787` (`apps/cloud/wrangler.jsonc`) | Worker `conclave-ax-app` (`infra/cloudflare/app.wrangler.jsonc`) |
| Database | Local D1 `conclave-development` in `apps/cloud/.wrangler/state` | Remote D1 `conclave-v8-production` |
| Web app | Flutter `run` on `http://localhost:3000` | `https://app.conclaveax.com` |
| Workspace binary | `syntila-workspace-local` (built with `--local`) | `syntila-workspace` |
| Workspace state (macOS) | `~/Library/Application Support/Conclave Local/Workspace/State` | `~/Library/Application Support/Conclave/Workspace/State` |

The Workspace environment is chosen at build time (`SYNTILA_WORKSPACE_ENVIRONMENT`). A local build uses the separate `Syntila Local` state folder and, when `workspace.nano` is created (`config init`, first run, or after `reset`), writes `cloud.url http://localhost:8787`. After that the service always connects to whatever `cloud.url` says, so check it with `syntila-workspace-local config show`. If the file was created by a different build, edit `cloud.url` or run `reset`.

## Local stack

1. `pnpm db:migrate:local` once, and after pulling new migrations.
2. `pnpm start:local` opens two terminals: the API (local D1) and the web app.
3. Workspace, pick one:
   - `pnpm workspace:run:local` runs the service from Dart source.
   - `pnpm workspace:build:macos:local --install`, then `syntila-workspace-local service install|start`.
4. Talk to the local service: `syntila-workspace-local status`, or from source `pnpm workspace:cli:local status`.

`pnpm db:cleanup:local` clears stuck execution state from the local D1 (stop the API first).

## Production

- `pnpm app:run:prod` runs the web app locally against the **production** Cloud through `scripts/local-cloud-proxy.mjs`: live accounts and data.
- `pnpm deploy:api` deploys the Worker; build `apps/app/build/web` first. CI normally does this (`deploy-cloud.yml`).
- `CONFIRM_PRODUCTION_MIGRATION=YES pnpm db:migrate:production` applies remote D1 migrations.
- `pnpm tail:api` streams production Worker logs.
- Workspace: `pnpm workspace:build:macos:prod --install`, then `syntila-workspace service install|start`.
