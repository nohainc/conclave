# ADR-003: Architecture v3 — Flutter/Dart Host Stack

**Status:** Accepted (Normative)  
**Date:** 2026-09-21  
This is the current Agent implementation decision for Architecture v3.

## Decision

Keep the Cloud-first orchestration model, but standardize the host/client stack as:

- Studio: Flutter/Dart;
- Agent App: Flutter/Dart;
- Agent Engine: Dart AOT native executable;
- Cloud: TypeScript on Cloudflare;
- Worker Plugins: language-independent executable processes.

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
