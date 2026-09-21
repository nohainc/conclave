# Conclave AX

**AI execution and orchestration ecosystem where models and agents plan, delegate, build, review, test, and iterate toward verified outcomes.**

Conclave AX turns a user request into a persistent **Goal** rather than a single prompt. It coordinates configured AI models, agents, tools, local runtimes, and CI systems through small tasks and independent verification loops.

Primary domain: **conclaveax.com**

## Ecosystem

- **Conclave AX Core** — provider-independent orchestration domain and state machine.
- **Conclave AX Studio** — Flutter desktop application.
- **Conclave AX Cloud** — hosted control plane and Flutter web application.
- **Conclave AX Local Runtime** — TypeScript runtime for repositories, Git, files, shell, tests, and local agents.
- **Conclave AX Forge** — first workflow/application: AI-assisted software development.
- **Conclave AX SDK** — extension and workflow integration surface.

Internal package names remain `@conclave/*`; AX is the public product brand.

## Initial stack

- Flutter for Studio and Cloud UI
- TypeScript for Core, Cloud API, providers, and Local Runtime
- Cloudflare Workers + Workflows
- Cloudflare D1 for structured orchestration state
- Cloudflare R2 for large artifacts
- GitHub Actions for CI
- Cloudflare Workers Static Assets for the web application

## Development approach

Conclave AX itself should be built the way it expects AI teams to work:

1. define architecture and contracts;
2. divide work into small phases;
3. implement;
4. independently review;
5. run real checks/tests;
6. resolve findings;
7. update documentation.

Start with [ARCHITECTURE.md](ARCHITECTURE.md), [ROADMAP.md](ROADMAP.md), and [AGENTS.md](AGENTS.md).

Deployment guidance is in [docs/deployment/CLOUDFLARE.md](docs/deployment/CLOUDFLARE.md).

The first meaningful product milestone is **Conclave AX Forge MVP**: given a real Git repository and a development goal, Conclave AX uses at least two independent AI workers, decomposes the goal, delegates implementation, independently reviews the result, runs real tests, iterates on failures, and returns a completion report with evidence.
