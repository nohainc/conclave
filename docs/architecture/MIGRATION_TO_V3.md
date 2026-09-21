# Migration to Architecture v3

Architecture v3 keeps the Cloud-first design but changes the host/client implementation stack.

## Current -> target

| Current | Target |
| --- | --- |
| Flutter Studio | keep Flutter Studio |
| TypeScript Cloud Worker | keep TypeScript Cloud |
| TypeScript plugin SDK/runtime | replace runtime dependency with language-independent plugin protocol |
| TS first-party plugins | migrate selectively to Dart; keep TS where ecosystem advantage is meaningful |
| Local Runtime product concept | internal Agent Engine runtime primitives only |
| direct Worker/Connection legacy | remove from production path |
| duplicate TS/Dart protocol definitions | schema-first generated bindings |

## Transitional repository layout

Target:

```text
apps/
  flutter_app/          # Studio; later rename to studio/
  agent_app/            # Flutter Agent UI
  agent_engine/         # Dart headless engine
  worker/               # Cloud control plane (TypeScript)

packages/
  ... existing Cloud TypeScript packages
  dart/
    agent_protocol/
    plugin_protocol/
    shared_models/

worker-plugins/
  codex/
  claude-code/
  openai/
  anthropic/
  git/
  test-runner/
```

The exact directory rename is not a release blocker.

## Migration status

The Dart Agent App and Agent Engine are now the only supported host stack.
The former TypeScript Agent has been removed after the Dart path gained:

- Cloud enrollment/configuration and reconnect recovery;
- durable assignment journaling;
- signed plugin installation and updates;
- Codex, Claude Code, OpenAI, Anthropic, and Forge plugin packages;
- Agent App and Agent Engine CI tests;
- end-to-end Forge execution through Agent Workers.

## Reuse

Reuse current TypeScript Agent behavior as specification/test cases:
- enrollment;
- reconnect;
- assignment journal;
- plugin install/update;
- worker status;
- self-update;
- assignment lifecycle;
- web worker relay.

Do not mechanically port implementation details that conflict with Dart/process architecture.
