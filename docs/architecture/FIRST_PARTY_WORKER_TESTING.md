# First-Party Worker Testing

Provider integrations are tested through the generic CLI Worker Engine and
signed Tool Profiles.

## Deterministic acceptance

The generic Engine tests use fixture CLIs and provider event fixtures. Run the
relevant suites with:

~~~sh
cd engines/cli_worker && dart test
cd packages/tool-profile && pnpm test
cd apps/workspace && flutter test
~~~

These tests do not require provider accounts or use provider allowance.

## Real provider acceptance

The opt-in [Profile acceptance suite](../roadmaps/ARCHITECTURE_V8_IMPLEMENTATION.md#release-gates)
uses the installed Codex and Antigravity CLIs. It writes digest-bound evidence
for passive/live probes, a Workstream write, durable session start/resume,
timeout, and process-tree cancellation. Set only the corresponding opt-in
variable and an evidence directory when an operator is ready to run it:

~~~sh
CONCLAVE_TEST_REAL_PROFILE_CHATGPT=1 \
CONCLAVE_PROFILE_ACCEPTANCE_EVIDENCE_DIR=/path/to/evidence \
  flutter test test/tool_profile_real_acceptance_test.dart

CONCLAVE_TEST_REAL_PROFILE_GEMINI=1 \
CONCLAVE_PROFILE_ACCEPTANCE_EVIDENCE_DIR=/path/to/evidence \
  flutter test test/tool_profile_real_acceptance_test.dart
~~~

From `apps/workspace`, the live assignment suite covers Direct, Plan & Implement,
Implement & Verify, and Full Cycle for both logical Workers. It uses provider
allowance and does not replace the evidence-producing release acceptance
suite.

~~~sh
CONCLAVE_TEST_REAL_PROFILE_CHATGPT=1 \
CONCLAVE_TEST_REAL_PROFILE_GEMINI=1 \
  flutter test test/tool_profile_assignment_acceptance_test.dart
~~~

Live-provider acceptance remains a release gate. The generic Engine fixture
suite provides deterministic coverage without provider accounts or allowance.
