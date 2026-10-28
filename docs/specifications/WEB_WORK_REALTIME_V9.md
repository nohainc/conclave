# Web Work Realtime and UX Contract V9

## Scope

The Web App presents Work execution from one authoritative Work Request
projection. Cloud status owns lifecycle state; realtime Worker Activity is an
ordered observation stream used for current activity, elapsed-time hints and
retained execution history.

## Projection rules

- A Work Request status is never promoted by activity. `queued`, `starting` and
  `acknowledged` remain startup states until Cloud reports `running`.
- Activity cannot create, reopen or terminally complete a request. Terminal
  outcomes come from the authoritative request detail and stop elapsed timers.
- Activity from an older attempt is ignored after a newer
  `execution.started` marker is accepted for the assignment.
- Each request card subscribes only to the activity signals for its own
  assignments. Activity updates are incremental and do not reload the entire
  Work history.
- The card shows the current Worker identity when a Worker execution is
  selected or running. Waiting/system states remain attributed to Syntila.
- Active activity and completed activity history are separate visual groups.
  Provider percentages are not synthesized from tool counts.

## Realtime recovery

`AxWorkRealtimeSync` exposes `AxWorkRealtimeStatus` to the Work surface. During
transport loss, a scoped gap or authoritative recovery read, unfinished cards
pause live timers without adding any connection message to the response body. Recovery refreshes authoritative request detail and retained activity;
it does not infer a terminal result from a missing event.

## Failure presentation

Worker and process failures are rendered from the request or failed step error
classification. If no known classification exists, the server-provided error
message is used only when no failed step classification is present; otherwise
unknown/internal diagnostics remain generic. A terminal request remains
terminal even when delayed activity arrives afterward.

## Compatibility and migration

Existing activity history and realtime envelopes remain readable. Legacy
progress events continue to update the Work history synchronizer during the
transition, but they do not override the authoritative request status. The
legacy progress display can be removed after all supported clients consume the
normalized activity stream.
