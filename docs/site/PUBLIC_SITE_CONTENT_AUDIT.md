# Public Site Content Audit

**Reviewed:** 2026-09-23  
**Scope:** `apps/site/src/` marketing copy and generated public-site claims  
**Basis:** current repository behavior and tests; re-run before each production
content change.

## Claim review

| Claim area | Public wording | Status | Evidence |
| --- | --- | --- | --- |
| Workers | Workers are installable AI/tool integrations managed by Hosts. | Verified | `apps/host/lib/worker_manager.dart`, `packages/worker-manifest`, `workers/*` |
| Current Workers | Codex, Claude Code, OpenAI, and Anthropic are shown in the catalog. | Verified | `workers/codex`, `workers/claude_code`, `workers/openai`, `workers/anthropic`; `apps/site/src/pages/workers.astro` |
| Platforms | macOS is first; Windows and Linux are supported by the Host product. | Verified | `apps/host/lib/cloud_connection.dart`, `.github/workflows/ci.yml`, `docs/architecture/ARCHITECTURE_V4.md` |
| Host capabilities | A Host is an execution machine that manages Worker processes and protects local credentials. | Verified | `apps/host/lib/host.dart`, `apps/host/lib/worker_executor.dart`, `apps/host/lib/secure_credentials.dart` |
| Multi-user sharing | A Host can serve authorized Workspace users and multiple Workspace bindings. | Verified | `packages/security/src/index.ts`, `apps/cloud/src/routes/handlers.ts`, `packages/persistence/test/schema-v4.test.ts` |
| Account sharing | Accounts are private by default; explicit grants allow use without secret visibility. | Verified | `apps/cloud/src/routes/handlers.ts`, `packages/security/src/index.ts`, `apps/host/test/credential_profiles_test.dart` |
| Verification | Runs support completion criteria, independent verification, findings, artifacts, and evidence. | Verified | `apps/cloud/src/forge-execution.ts`, `packages/persistence/src/d1.ts`, `apps/cloud/src/workflow.ts` |
| Realtime | The App receives authenticated Cloud realtime events, including active execution updates. | Verified | `apps/cloud/src/realtime-gateway.ts`, `apps/cloud/src/event-publisher.ts`, `apps/app/lib/src/realtime/` |
| AI providers | OpenAI and Anthropic API Workers, plus Codex and Claude Code integrations, are represented as Workers. | Verified | `workers/openai`, `workers/anthropic`, `workers/codex`, `workers/claude_code` |
| Forge | Forge is a current software-development workflow covering research, implementation, review, correction, and verification. | Verified | `apps/cloud/src/forge-execution.ts`, `apps/host/lib/forge_pipeline.dart`, `apps/cloud/test/forge-v4.test.ts` |

## Claims intentionally not presented as generally available

- Gemini, Ollama, ChatGPT Web, and Git/Test integrations remain architecture or
  implementation targets and are not listed as current public catalog entries.
- Cloud secret vault portability is not promised; local Host secure storage is
  the current credential location.
- The public site does not promise a direct Host installer, signed download
  flow, pricing, uptime, performance multiplier, or universal provider access.
- “More Workers coming” is deliberately used instead of implying that every
  architecture-level Worker is production-ready.

## Review rule

A claim may remain in public copy only when its implementation and a focused
test or production path are identifiable in the repository. Otherwise rewrite
it as **Preview**, **Planned**, or **Coming soon**, or remove it. The automated
site content, accessibility, responsive, security, analytics, and performance
checks must continue to pass after any copy change.
