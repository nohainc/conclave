# V6 runtime lease fencing — Historical Checkout Draft

> **Historical / superseded:** This document describes fencing tied to the
> former Workstream Checkout control plane. Active fencing is per Workstream
> directory and is implemented by the Workstream execution coordinator and
> local mutation lock.

Stateful assignment snapshots carry the complete Workstream execution lease:
`workstreamId`, `workRequestId`, `checkoutId`, `leaseId`, `fencingToken`,
`expectedRevision`, and `executionClass`.

Before a stateful Worker starts, the Workspace runtime resolves the opaque
Checkout ID through `WorkstreamCheckoutManager` and verifies:

1. the Checkout exists and belongs to the Workstream;
2. the fencing token is not older than the locally persisted token;
3. the lease ID is consistent for an equal token;
4. the Checkout revision equals `expectedRevision`; and
5. the Checkout is clean.

The runtime holds an OS file lock for the entire Worker callback. A local
per-process queue is layered over the OS lock because advisory locks do not
reliably serialize two handles from the same Dart process on every platform.
The result is one mutation critical section per Checkout across reconnects,
duplicate assignments, and multiple runtime processes.
