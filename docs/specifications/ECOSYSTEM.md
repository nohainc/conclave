# Extensibility and Ecosystem

Conclave AX Architecture v3 uses **Worker Plugins** as the extension boundary.

## Worker Plugin model

A Worker Plugin is a signed/versioned executable package installed by the Dart Agent Engine.

A plugin declares:
- plugin identity/version;
- supported Agent Engine versions;
- supported OS/architectures;
- roles/capabilities;
- configuration schema;
- secret requirements;
- permissions;
- billing modes;
- executable entrypoint.

Cloud stores plugin metadata in D1 and plugin packages in R2.

## Language independence

The plugin protocol is language-independent.

Official plugins should use Dart when practical, but a plugin may use TypeScript/Node.js, Rust, Python, Go, or another language when that ecosystem is materially better for the integration.

The Agent Engine communicates with plugins through the Worker Plugin Protocol, preferably JSON-RPC over stdin/stdout for v1.

## Worker instances

A Worker is one configured instance of a plugin.

One plugin may produce multiple Workers with different:
- models;
- roles;
- permissions;
- prompts/instructions;
- billing modes;
- concurrency limits;
- session policies.

Cloud schedules Workers, never hidden provider pools.

## Extension safety

Plugins run outside the Agent Engine control process.

A plugin cannot:
- mutate Cloud orchestration state directly;
- bypass permissions;
- access unrelated Workspace secrets;
- silently install additional plugins;
- create follow-up Tasks.

All Worker results pass through normal Conclave validation/persistence.

## Workflow templates

Workflow templates remain data.

They select roles/capabilities/policies and cannot introduce unsigned/unregistered plugin code.

See:
- [Architecture v3](../architecture/ARCHITECTURE_V3.md)
- [Technology Stack](../architecture/TECH_STACK.md)
- [Multi-Worker Orchestration](MULTI_WORKER_ORCHESTRATION.md)
