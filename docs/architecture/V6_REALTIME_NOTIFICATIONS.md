# V6 Realtime and Notifications

## Subscription scopes

The realtime client supports four v6 read scopes:

- Project;
- Workstream;
- Run;
- owned execution Workspace.

Workstream access is checked through current Project membership. A membership
removal causes the gateway to reject the subscription and close the connection
when it revalidates the connected client's scopes. This prevents a removed
collaborator from continuing to receive events through an existing tab.

## Event families

Durable events cover Discussion messages, Work Requests, checkout state, lease
state, checkpoints, integration state, membership revocation, and Run/task
changes. Durable sequence cursors remain scoped to the affected read model;
reconnect gaps request resynchronization rather than a full application
snapshot reload.

Ephemeral progress and stream updates remain coalescible and bounded. Queue
pressure must not discard durable state transitions.

## Notifications

The notification layer emits user-visible notifications only for actionable or
meaningful states:

- needs input;
- Work completed or failed;
- Worker, credential, or Project Grant problems;
- recovery required.

Discussion, queue, checkout, lease, and ordinary progress events update the
active read model without interrupting the user. Two tabs and multiple users
may therefore observe the same Workstream safely while notifications remain
focused on decisions and intervention.
