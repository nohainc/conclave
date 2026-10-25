# Worker Profile V9 rollout verification

Phase 11 verifies the V9 single-current-Profile contract across the real
Profile Lab and Workspace boundaries.

## Automated acceptance coverage

- Profile Lab runs the complete local test ladder through the bundled CLI
  Worker Engine binary, including restricted file-write, session, model,
  cancellation and timeout scenarios. Publication evidence is checked against
  the exact candidate digest.
- Workspace installs one signed current Profile for each of two logical
  Workers, verifies it, executes it through the bundled Engine binary, updates
  it by revision, retains one last-known-good snapshot, and preserves an
  active execution's pinned snapshot.
- Workspace uses the verified cache while offline and after a simulated
  service restart. An Engine-incompatible update leaves the safe current
  Profile active. Full Local Access is always on for every Worker and survives a
  Profile update.
- Revocation blocks the active snapshot without allowing last-known-good to
  bypass the policy. A newly signed restoration revision can replace the
  revoked snapshot atomically.
- Cloud migration, registry and route tests cover direct current-state lookup,
  history, validation, publication, restoration and expected-revision conflict
  handling.
- The Worker Engine execution and durable-session compatibility tests remain
  green, including fresh and resumed sessions.
- The Phase 4 Engine integration harness exercises controlled success, provider
  failure, missing terminal events, delayed output, high-frequency repeated
  tools, large responses, and two concurrent Worker processes. Workspace
  diagnostics expose a bounded correlation timeline plus missing-terminal,
  forwarding-failure, and stale-running counters.
- Realtime projection tests inject duplicate and reordered activity events and
  verify monotonic, bounded AX state. Cloud history remains the recovery source
  after reconnect; the terminal result remains authoritative.

## Focused verification commands

```text
flutter test apps/profile_lab/test/phase11_profile_lab_binary_acceptance_test.dart
flutter test apps/workspace/test/worker_profile_rollout_acceptance_test.dart
vitest run apps/cloud/test/worker-profile-v9-registry.test.ts
```

The acceptance tests use deterministic local provider fixtures. Full Local
Access host validation (`CONCLAVE_TEST_FULL_LOCAL_ACCESS=1`), real Profile
evidence (`CONCLAVE_TEST_REAL_PROFILE_CHATGPT=1` /
`CONCLAVE_TEST_REAL_PROFILE_GEMINI=1`), and live assignment workflows
(`CONCLAVE_TEST_ASSIGNMENT_PROFILE_CHATGPT=1` /
`CONCLAVE_TEST_ASSIGNMENT_PROFILE_GEMINI=1`) remain opt-in device tests because
they require the operator's provider installation and credentials; the automated
Workspace test verifies the authorization state and its preservation across
Profile publication.
