# V6 Security and recovery acceptance

V6-26 is covered by the Cloud scheduler and Workspace runtime acceptance
tests. The boundary is checked at both sides of dispatch:

- Cloud rechecks active Workspace Project Grants, Worker authorization, and
  internal credential availability;
- runtime rejects traversal, symlink escape, forged opaque checkout IDs,
  alternate Workstream IDs, stale fencing tokens, duplicate leases, and
  expected-revision mismatches;
- the checkout lock serializes mutations and survives process reopening;
- failed rollback produces a bounded diagnostic and quarantines the checkout;
- Worker permissions are intersected with the signed manifest and system
  administration is never admitted;
- credential material is rejected from assignment input and redacted from
  command evidence and diagnostics.

The acceptance suite intentionally tests revocation and recovery immediately
before dispatch or mutation, rather than relying on an earlier authorization
decision.
