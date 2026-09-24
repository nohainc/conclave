# V6 Team concurrency acceptance

The team acceptance topology contains one Project owner, three collaborators,
and a viewer. Workstreams A and B share one Mac Workspace; Workstream C uses a
second Workspace.

The executable acceptance contract verifies:

- every Project member can Discuss;
- only configured Workstream members can execute;
- stateful Requests in one Workstream serialize;
- different Workstreams overlap in time;
- managed checkout paths never overlap;
- failure in Workstream A does not fail Workstream B;
- viewer execution is rejected;
- Account sponsor and Account-owner attribution are preserved;
- removing a member blocks new Work Requests immediately.

The contract consumes immutable execution observations, so it can be run by the
Cloud/D1 acceptance harness and by lower-level scheduler tests without making
authorization depend on UI state.
