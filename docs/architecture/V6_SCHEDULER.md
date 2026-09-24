# V6 scheduler execution classes

The v5 Project execution selector now receives the workflow step execution
class.

For `stateless_read`, it may select any online Workspace with an active
Project Grant, ready Worker, authorized Account, and available capacity. The
selected checkpoint revision is carried in the immutable permission snapshot;
the selector itself does not create or mutate Workstream state.

For `stateful_workstream`, selection first resolves the active Work Request,
Primary Workspace policy, ready Checkout, and active Workstream lease from D1.
Only then are Worker, Account, Grant, permission, and capacity filters
applied. A caller-provided Workspace override is rejected unless it is the
resolved Primary Workspace; auxiliary Workspaces are never fallback targets.

The resulting target includes the lease snapshot required by V6-10, including
Checkout ID, Lease ID, fencing token, and expected revision.
