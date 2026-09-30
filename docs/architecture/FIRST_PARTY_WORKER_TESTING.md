# First-party Worker testing and acceptance

This document defines the verification pyramid for the first-party ChatGPT and
Gemini Workers. Deterministic tests use fake CLIs and never need provider
accounts, tokens, or billable requests. Live-provider checks are explicitly
opt-in. Production support requires a separately approved real assignment
through the deployed Cloud and Workspace path for each provider.

## 1. Local Adapter Protocol contract

Run the adapter process with a fake `codex` or `agy` executable. These tests
exercise the same Local Adapter Protocol contract for both adapters, including
correlated request IDs, strict frame parsing, initialization, readiness probe,
safe probe fields, progress, result, and provider-error translation. Fixtures
include fake provider credentials in the adapter environment and verify that
they do not appear in protocol output.

```sh
pnpm worker-adapters:test
```

This command includes the first-party fake CLI suites and the shared contract
suite. It is part of ordinary CI. The broader adapter fixtures in the same
command are also deterministic.

## 2. OS process and process-tree tests

Workspace process tests launch real operating-system child processes while
using fake adapters and fake CLIs. They cover adapter/CLI crashes and hangs,
timeouts, cancellation, Workspace shutdown, child-spawned grandchildren,
stdout and stderr overflow, and cleanup of the full process tree.

The package-store suite also installs the shipped Antigravity package through
`V7AdapterAdmission`, resolves its production `WorkerProcessSpec`, and executes
it through the Workspace process launcher. It uses a minimal macOS-style GUI
environment and places fake `agy` under `$HOME/.local/bin`, verifying the
central PATH baseline and signed provider-variable filtering across the full
Workspace → package → CLI boundary.

```sh
cd apps/host
flutter test test/worker_executor_test.dart test/process_tree_test.dart test/worker_executor_limits_test.dart
```

The host Flutter test job runs the complete `apps/host` test suite on Linux,
macOS, and Windows in CI.

## 3. Cloud-to-Workspace E2E with fake provider CLIs

The acceptance harness creates a fake Cloud assignment, runs the real
Workspace process through the Workspace Gateway, admits and launches the
shipped Codex or Antigravity adapter, runs a fake provider CLI in the
Workstream CWD, and verifies that Cloud persists the result. It covers both
`chatgpt` and `gemini` product Worker types. No live provider account is used.

```sh
DART_EXECUTABLE="$(command -v dart)" pnpm exec vitest run \
  apps/cloud/test/v7-runtime-e2e.acceptance.test.ts
```

CI runs this acceptance test alongside Workspace inventory-recovery
acceptance. The three runtime transport fixtures remain in the matrix; the
two first-party adapter cases use WebSocket transport.

## 4. Opt-in live CLI acceptance

These local tests use the already configured provider CLI account and are
skipped unless the provider-specific opt-in switch is set. Each run performs a
passive probe, one stateless real assignment, then starts a durable session and
continues it from a fresh Worker Package process. This is three small live
requests and may consume provider usage. The session state is stored in a
temporary test directory and removed afterward.

```sh
CONCLAVE_TEST_REAL_CODEX=1 node --test \
  packages/worker-manifest/adapters/codex/test/codex-adapter.node.mjs

CONCLAVE_TEST_REAL_AGY=1 node --test \
  packages/worker-manifest/adapters/antigravity/test/antigravity-adapter.node.mjs
```

If a CLI is installed outside the current shell's `PATH`, add its install
directory to `PATH` before launching the adapter test. Worker Packages own CLI
discovery and do not accept executable-path overrides. Do not put provider
credentials in test variables, fixtures, CI secrets, or acceptance evidence.
The package receives only the runtime base environment and variables listed in
its signed manifest policy, so configured Codex home, Gemini API key, endpoint,
or ADC settings are exercised through the same package boundary used by
Workspace. Do not set either opt-in switch in routine CI.

## 5. Opt-in Cloud-to-CLI production-path acceptance

The final local release-gate test exercises the production Cloud dispatcher and
Workspace Gateway, a real Workspace runtime process, signed Worker Package
admission, the installed provider CLI, and result persistence back in Cloud. It
uses an in-memory Cloud database and local Gateway/Workspace processes; it does
not deploy to production. The real CLI scenarios are excluded unless their
provider-specific opt-in switch is set. They may consume provider quota.

Run one provider at a time after confirming its CLI is installed, configured,
and available in the invoking shell's `PATH`:

```sh
CONCLAVE_TEST_REAL_CLOUD_CODEX=1 DART_EXECUTABLE="$(command -v dart)" \
  pnpm exec vitest run apps/cloud/test/v7-runtime-e2e.acceptance.test.ts

CONCLAVE_TEST_REAL_CLOUD_AGY=1 DART_EXECUTABLE="$(command -v dart)" \
  pnpm exec vitest run apps/cloud/test/v7-runtime-e2e.acceptance.test.ts
```

Each real scenario submits one bounded prompt using the CLI's configured
default model, verifies progress and successful result frames, and confirms
that the Cloud assignment and workflow task are completed with the response.
The test does not include provider CLI stderr or credentials in Cloud records.
The Workspace process receives only the variables authorized by the signed
package environment policy. Routine CI must not set these opt-in switches.

Do not mark ChatGPT or Gemini production-supported until its own full-path
scenario passes on the intended machine and the release record below is
completed. The separate local durable-session tests do not substitute for this
Cloud-to-Workspace result-persistence gate.

## 6. Manually approved production assignment

Do not declare either first-party Worker production-supported until its own
opt-in Cloud-to-CLI acceptance scenario passes and its production acceptance
record shows a successful real assignment across the complete path:

```text
Cloud → Workspace Gateway → Workspace → first-party adapter → real CLI → Cloud result
```

Run one small, bounded assignment for ChatGPT and one for Gemini. Obtain
explicit operator approval immediately before each real assignment. Confirm
the correct product Worker (`chatgpt` or `gemini`), intended Workspace and
Workstream CWD, local readiness, expected permissions, successful completion,
and result visibility in Cloud. Verify cancellation/timeout behavior using
deterministic tests rather than spending live requests on failure cases.

Keep the release record in this matrix and link the approved assignment/run
evidence from the applicable record. A provider remains **Not run** until a
real result is confirmed in Cloud.

| Product Worker | Status | Approver / operator | Workspace and CLI versions | Assignment / Workstream | Cloud result evidence |
| --- | --- | --- | --- | --- | --- |
| ChatGPT (`chatgpt`) | Not run | — | — | — | — |
| Gemini (`gemini`) | Not run | — | — | — | — |

Record, without secrets or raw provider stderr:

- provider product Worker type and acceptance date;
- approver and operator;
- Workspace build/version and detected CLI version;
- assignment identifier and Workstream identifier;
- confirmation that the result reached Cloud;
- pass/fail outcome and any stable Conclave error code.

Never record prompts or result text if they contain sensitive content. Do not
record provider tokens, credential paths, raw provider diagnostics, or account
details. A failed or unrun provider remains unaccepted; fake CLI coverage and
opt-in local live CLI tests do not substitute for this full production path.
Do not claim first-party production support until both rows above are accepted
with evidence.

## CI boundary

Routine CI runs protocol, fake process, and Cloud-to-Workspace fake-CLI tests.
It does not set `CONCLAVE_TEST_REAL_CODEX`, `CONCLAVE_TEST_REAL_AGY`,
`CONCLAVE_TEST_REAL_CLOUD_CODEX`, or `CONCLAVE_TEST_REAL_CLOUD_AGY`, and makes
no real provider assignments. Production acceptance is a manual release gate
and must be completed independently for both providers before support is
claimed.
