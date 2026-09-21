# ADR-002: Architecture v2 — Cloud Orchestration, Agent Execution

**Status:** Accepted (Normative)
**Date:** 2026-09-21
**Supersedes:** ADR-001 (for connection/local runtime direct cloud execution concepts), legacy direct Cloud-to-provider execution

## Decision
Adopt **Architecture v2** as the authoritative and normative architecture for Conclave AX:

```text
Human User
   |
Conclave AX Studio
   |
Conclave AX Cloud
   |  (orchestration / state / policy / audit)
Conclave Agent
   |  (host daemon / isolated process execution)
Worker Plugin
   |  (versioned integration package)
Worker Instance
   |  (configured addressable execution unit)
External AI / Agent / Tool / CI / Service
```

### Core Invariant
> **Cloud orchestrates. Agents execute. Plugins integrate. Workers do the actual work. Studio controls and observes.**

## Key Rules
1. **Cloud Does Not Execute Directly:** Cloud never directly calls OpenAI, Anthropic, Gemini, Codex, Claude Code, Ollama, Git, shell, or CI. Every capability is exposed via a Worker hosted by a Conclave Agent.
2. **Sole Orchestration Authority:** Cloud owns durable Goal/Run/Task state, scheduling, policies, verification gates, and audit. Agents cannot branch orchestration.
3. **Worker Model:** Deprecate `ConnectionResource` at Cloud orchestration level. Cloud schedules against `Worker` instances bound to `(agentId, pluginId, pluginVersionPolicy, roles, capabilities, configuration, billingMode, independenceKey, status)`.
4. **Agent-Local Secrets (v1):** Execution secrets remain stored securely on the Agent host (OS secure storage) rather than plaintext or application tables in Cloud.
5. **Freeze Legacy Connections:** Stop adding new features to legacy `ConnectionResource` / direct provider connection implementations. All future integrations are built as Worker Plugins.

## References
- [Architecture v2 Specification](../architecture/ARCHITECTURE_V2.md)
- [Migration v1 to v2 Map](../architecture/MIGRATION_V1_TO_V2.md)
- [Architecture v2 Implementation Roadmap](../roadmaps/ARCHITECTURE_V2_IMPLEMENTATION.md)
