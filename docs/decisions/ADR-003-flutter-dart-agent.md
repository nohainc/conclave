# ADR-003: Architecture v3 — Flutter/Dart Host Stack

**Status:** Accepted (Normative); reaffirmed for first-party Worker executables by [ADR-017](ADR-017-standalone-dart-worker-executables.md)  
**Date:** 2026-09-21  
This is the current Agent implementation decision for Architecture v3.

## Decision

Keep the Cloud-first orchestration model, but standardize the host/client stack as:

- Studio: Flutter/Dart;
- Agent App: Flutter/Dart;
- Agent Engine: Dart AOT native executable;
- Cloud: TypeScript on Cloudflare;
- Worker Plugins/Workers: language-independent executable processes; first-party Workers standardize on standalone Dart AOT console executables under ADR-017.

## Rationale

The Agent has a real cross-platform UI and also needs a long-running execution service.

Separating those concerns gives:

- one Flutter UI codebase across desktop platforms;
- shared Dart models between Agent App and Engine;
- a self-contained compiled Agent Engine;
- independent UI and execution lifecycles;
- process isolation for plugins;
- no mandatory Node.js runtime on user hosts;
- freedom to implement plugins in Dart, TypeScript, Rust, Python, Go, or another language.

## Core invariant

> Cloud orchestrates. Agent Engine executes. Worker Plugins integrate. Workers do the work. Flutter apps control and observe.

## Process boundary

The Agent App and Agent Engine must be separate OS processes.

The Agent Engine and every Worker Plugin must also be separate processes for v1.

Dart isolates may be used internally for concurrency but are not the primary lifecycle/isolation boundary.

## References

- [Architecture v3](../architecture/ARCHITECTURE_V3.md)
- [Technology Stack](../architecture/TECH_STACK.md)
- [Migration to v3](../architecture/MIGRATION_TO_V3.md)
- [Implementation Roadmap](../roadmaps/ARCHITECTURE_V3_IMPLEMENTATION.md)

## Worker Runtime v2 refinement

ADR-017 applies this earlier native-process direction to the current Architecture v7 Workspace Worker model. The Workspace remains Flutter/Dart; first-party ChatGPT and Gemini Workers are independently versioned standalone Dart executables. They are not Flutter plugins and do not run inside the Workspace process. Third-party Worker implementations may remain language-independent if they satisfy the same signed release and Local Worker Protocol contracts. This is the accepted architecture; full Workspace assignment-path convergence and production acceptance are tracked in the [Worker Runtime v2 implementation plan](../roadmaps/WORKER_RUNTIME_V2_IMPLEMENTATION.md).
