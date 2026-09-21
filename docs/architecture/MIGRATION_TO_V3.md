# Migration to Architecture v3

Architecture v3 keeps the Cloud-first design but changes the host/client implementation stack.

## Current -> target

| Current | Target |
| --- | --- |
| Flutter Studio | keep Flutter Studio |
| TypeScript Cloud Worker | keep TypeScript Cloud |
| TypeScript `apps/agent` | migrate to Flutter Agent App + Dart Agent Engine |
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

## Migration rule

Do not delete the existing TypeScript Agent until the Dart Agent Engine passes parity/E2E tests.

Migrate vertically:
1. establish Dart Agent protocol bindings;
2. create Agent Engine skeleton;
3. connect Agent Engine to Cloud;
4. implement plugin process protocol;
5. migrate deterministic plugin;
6. migrate local CLI plugins;
7. migrate API plugins;
8. add Agent App;
9. achieve E2E parity;
10. remove legacy TypeScript Agent.

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
