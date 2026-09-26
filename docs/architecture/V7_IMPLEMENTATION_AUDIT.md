# Architecture v7 Implementation Audit — Desktop Runtime Convergence

**Reviewed baseline:** `main@721fa3702e70e3d4d6ae817aacc5d3bbda79f98d`  
**Audit date:** 2026-09-26  
**Target:** [Architecture v7](ARCHITECTURE_V7.md)

## Executive assessment

v7 is substantially implemented, but the baseline was not yet a complete
desktop-product vertical slice.

The strongest implemented parts are:
- Workspace-local Worker registry;
- V7 adapter manifest/protocol/package admission;
- per-assignment child-process execution;
- Codex, Antigravity and API adapter implementations;
- safe Worker inventory sync;
- Workspace-owned Worker scheduler candidate data;
- ID-only Workstream directories;
- Execution inventory UX.

The baseline gaps that prevented a normal downloaded Conclave Workspace from
working end to end were:

1. the Flutter desktop app did not compose the same real Cloud-connected runtime
   as the headless entrypoint;
2. the desktop pairing button did not redeem the one-time Workspace enrollment
   created by Conclave AX;
3. `workspace_enrollments` and the Workspace Gateway runtime credential model
   were not connected by a current enrollment endpoint;
4. there was no macOS release build/package script and CI did not build the
   macOS app;
5. Conclave AX still exposed a legacy Cloud-side Add Worker/binding surface;
6. the Antigravity adapter used an obsolete/noncanonical executable and
   Codex-style CLI arguments instead of the supported `agy` headless contract;
7. adapter trust is still HMAC-secret based and therefore is not yet suitable
   for a public desktop release without replacing it with asymmetric package
   signing.

This audit treats those as v7 convergence work, not a new architecture.

## Product boundary

### Conclave AX

Conclave AX is the **web application**.

It owns:
- human sign-in;
- Projects and Workstreams;
- Discuss and Work;
- Workspace creation/grants;
- remote Worker inventory;
- scheduling/authorization;
- results, artifacts and audit;
- downloads/onboarding.

It does not create/authenticate local Workers.

### Conclave Workspace

Conclave Workspace is the **desktop application/runtime** installed on the
execution computer.

It owns:
- pairing;
- persistent Cloud connection;
- machine facts;
- Work Root and Workstream directories;
- local Worker creation/edit/removal;
- provider authentication/API credentials;
- local permissions;
- adapter packages;
- child process execution;
- diagnostics and updates.

All configured Workers originate here.

## Desktop pairing contract

The intended flow is:

~~~text
Conclave AX web
-> Create Workspace (name only)
-> Connect machine
-> create one-time workspace_enrollment
-> show pairing code

Conclave Workspace desktop
-> enter pairing code
-> POST /api/workspace-runtime/enroll
-> receive runtime ID + bearer token
-> store bearer token in OS secure store
-> store non-secret registration locally
-> connect /api/workspace-gateway/connect
-> workspace.hello
-> inventory sync
~~~

The Workspace runtime bearer token is never stored in the normal registration
JSON and Cloud stores only its hash.

Re-pairing revokes the older active runtime identity for the Cloud Workspace.
Local Workstream files are unaffected because ADR-011 paths do not contain the
Workspace/runtime ID.

## Worker Type naming

Worker Type names identify the **execution integration**, not the subscription
brand and not a model family.

### Correct

- **Codex** — invokes Codex CLI. Authentication may be a ChatGPT account.
- **Antigravity** — invokes Google Antigravity CLI (`agy`). Authentication may
  be a Google account/Google AI plan.
- **Claude Code** — invokes Claude Code.
- **OpenAI API** — direct provider API.
- **Gemini API** — direct Gemini API.
- **Anthropic API** — direct Anthropic API.
- **Ollama** — local Ollama service.

### Incorrect / misleading

- **ChatGPT Worker** for the Codex CLI integration;
- **Gemini Worker** when the actual integration is Antigravity CLI;
- one Worker Type per model such as Gemini Pro, GPT-5.x or Claude Sonnet.

If Conclave later integrates a distinct Gemini CLI product directly, that may
be a separate **Gemini CLI** Worker Type. It should not be conflated with
Antigravity or Gemini API.

## Adapter contract audit

### Codex

Target contract:
- prerequisite executable: `codex`;
- local authentication: ChatGPT/Codex local sign-in;
- non-interactive execution: Codex supported exec/headless interface;
- Workstream directory supplied as CWD.

Product copy should say:
> Codex — authenticate with your ChatGPT account.

Do not rename this adapter to ChatGPT.

### Antigravity

Target contract:
- prerequisite executable: `agy`;
- local authentication: Google account/keyring or explicitly configured Gemini
  API-key mode;
- non-interactive execution: documented `agy` headless mode;
- output: JSON/stream-json;
- model: optional `--model`;
- Workstream directory supplied as CWD.

Do not call a nonexistent `antigravity` executable from the adapter.

### API adapters

API adapters remain separate because authentication, streaming, tool calling,
model discovery and error semantics differ by provider. Shared helper code is
appropriate; a giant provider-switch adapter is not required.

## macOS release audit

The product target is direct macOS distribution, not Mac App Store sandboxing.

That is important because Conclave Workspace must:
- maintain outbound Cloud/provider connections;
- execute Codex/Antigravity/Claude/local tools;
- supervise child process trees;
- read/write persistent Workstream directories;
- use local secure credentials.

The repository requires a reproducible build entrypoint that:
- runs Flutter package resolution;
- analyzes/tests unless explicitly skipped;
- builds release macOS;
- injects Workspace app version;
- optionally signs with Developer ID + hardened runtime;
- optionally notarizes;
- creates a distributable ZIP.

CI must build the native macOS app on `macos-latest`, not merely compile the
headless Dart entrypoint.

## Cloud connection acceptance

A useful smoke test must verify both halves:

1. HTTP enrollment redemption succeeds;
2. the resulting runtime credential opens the Workspace Gateway and receives a
   valid Workspace session.

A test that only calls the enrollment endpoint is insufficient.

The smoke test should use a disposable Workspace because pairing creates/replaces
a real active runtime identity.

## Remaining v7 convergence after this desktop slice

### 1. Remove legacy Cloud Worker persistence/API

Current compatibility state still includes v6 configured Worker/binding tables
and APIs. They may remain during migration but must not be exposed in normal
Conclave AX UX.

Target cleanup:
- remove Cloud Add Worker;
- remove Worker<->many-Workspace binding CRUD;
- remove per-binding credential setup;
- remove binding tables after scheduler/fixtures no longer depend on them.

### 2. Remote scheduling controls

The Worker inventory needs explicit Cloud-owned operational fields such as:
- enabled;
- disabled;
- draining.

Those may narrow local readiness but never change local credentials/permissions.

### 3. First-party adapter release pipeline

Packaging and Cloud publication exist, but a repeatable first-party release
workflow should package, sign, publish and optionally revoke adapter releases.

### 4. Production adapter signing

Current HMAC trust is suitable for development fixtures but not a distributable
desktop application because verification would require shipping the signing
secret.

Release requirement:
- private signing key exists only in release infrastructure;
- Conclave Workspace embeds/trusts public verification key(s);
- adapter manifest + package digest are signed asymmetrically;
- key rotation/revocation is documented and tested.

This is a **v7 release gate**.

### 5. Background desktop UX

The runtime should survive window close. A tray/menu-bar surface, reopen
behavior and explicit drain/quit UX remain product maturity work.

### 6. Live-provider acceptance

Fake CLI/API tests are necessary but not sufficient.

Before declaring each first-party adapter production-ready, run opt-in acceptance
against:
- a real Codex local session;
- a real Antigravity local session;
- provider API test credentials.

These tests must not run in normal CI or expose secrets.

## Definition of v7 complete

v7 can be considered implemented when:

1. a new user creates a Workspace in Conclave AX web;
2. installs the macOS Conclave Workspace build;
3. pairs with the one-time code;
4. AX reports the machine online and its real platform/version;
5. user creates/authenticates a Worker only in desktop app;
6. Worker appears automatically in AX;
7. Project/Workstream policy can select it;
8. scheduler dispatches it to its owning Workspace;
9. adapter executes in the ID-only Workstream directory;
10. result reaches Cloud/AX;
11. no provider secret enters Cloud;
12. web app exposes no Cloud-side Worker setup;
13. legacy v6 Worker bindings are no longer required for execution;
14. production adapter verification uses public-key trust;
15. macOS build/sign/notarize and desktop↔Cloud smoke procedures pass.
