# V6 Workstream execution coordinator

Each Workstream has one `WorkstreamExecutionCoordinator` Durable Object. The
object is addressed by the Workstream ID and serializes only `stateful`
Work Requests. `stateless` requests stay on the normal execution path and do
not wait behind the Workstream write queue.

## Authority and fencing

D1 remains authoritative for Work Request status and
`workstream_execution_leases`. The Durable Object provides per-Workstream
serialization, FIFO selection, alarm-driven reconciliation, and fencing. A
stateful request is moved from `queued` to `running` in the same D1 batch that
creates its active lease and monotonically increasing fencing token. The lease
snapshot contains the selected Workspace and Checkout.

Workers must include the Work Request ID, lease ID, and fencing token in
heartbeat and completion calls. Expired, released, or mismatched leases are
rejected, so a stale worker cannot complete a newer request. Lease expiry marks
the request failed and allows the next queued request to start.

## Operations

- `POST /enqueue`: idempotently observes a stateful Work Request and pumps the
  FIFO queue.
- `POST /cancel`: cancels a queued request and its not-yet-started Run.
- `POST /heartbeat`: extends a current lease.
- `POST /complete`: releases a current lease and records completion/failure.
- `POST /reconcile`: expires leases and pumps the next request.
- `GET /status`: returns the active lease and queued stateful requests.

The browser API exposes queued cancellation at
`POST /api/work-requests/:id/cancel`. The coordinator binding is required in
production; D1 rows remain inspectable and recoverable after Durable Object
restart.
