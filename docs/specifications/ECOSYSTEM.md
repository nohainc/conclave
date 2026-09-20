# Extensibility and ecosystem

Phase 14 turns Conclave into an extension platform while keeping Core responsible for validation, authorization, persistence, and state transitions.

## Extension types

- Providers adapt model or service APIs to versioned protocol payloads. A provider never writes Core state directly.
- Agents package a specialized execution strategy behind an objective/input/output contract.
- Tools expose bounded external operations and declare required permissions. Tool inputs and outputs are persisted as evidence.
- CI workers return machine evidence, including the command, revision, result, and checks.
- Human workers are represented by approval steps. The run pauses durably until an authorized person approves or rejects.
- Workflow templates are versioned DAGs of provider, agent, tool, CI, and approval steps.

## SDK and headless Runner

`@conclave/sdk` provides registries and a deterministic headless Runner. The Runner validates template versions, rejects unknown dependencies and cycles, executes only dependency-ready steps, emits lifecycle events, and pauses at approvals. A host supplies handlers; the SDK does not execute arbitrary shell commands or grant permissions.

The same Runner can be used by the Worker API, a CLI/CI process, or an integration service. Hosts should persist snapshots and events after every step, use idempotency keys, and resume with the same template version.

## Extension manifest rules

An extension must declare a stable id, semantic version, capabilities, execution environment, data access, required permissions, timeout, and failure behavior. Organization administrators approve installation. Extensions are tenant-scoped unless explicitly published as a reviewed global package. Secrets are referenced by credential id and never included in manifests or workflow payloads.

## Safety boundary

Templates are data, not code. A template can select registered capabilities, but cannot introduce an unregistered provider, agent, tool, CI command, or permission. Tool adapters must enforce their own allowlists and receive a cancellation signal. Human approvals are authorization decisions, not model outputs.

## Initial workflow examples

The Forge flow can be expressed as a template: research agent → plan provider → implementation agent → independent review agent → approval → CI worker → verification provider. Other teams can use the same primitives for documentation review, incident response, data validation, or release operations without adding Forge-specific Core logic.

## Roadmap

The first implementation deliberately uses host-supplied handlers and in-memory registries. Next steps are signed extension packages, a CLI SDK, persisted template management endpoints, CI webhooks, and a graphical designer that emits the same validated template format.
