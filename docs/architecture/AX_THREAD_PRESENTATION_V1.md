# AX Thread Presentation Controller V1

## Purpose

`ThreadPresentationController` is a presentation-layer coordinator for the AX
Thread page. It consumes the existing discussion cache, Work history cache and
Worker activity store. It does not own server data, replace the query cache or
introduce a second persistence layer.

## Independent UI slices

The controller exposes immutable `ValueNotifier` snapshots for:

- Chat history and pagination state;
- Work request ordering, request content and submission state;
- execution status and terminal request IDs;
- composer changes; and
- per-request activity selectors backed directly by the existing activity
  store.

Work activity cards continue to use
`AxWorkActivityStore.listenableForRequest(request)` (also exposed by the
controller as a forwarding selector), so activity for one assignment does not
notify unrelated Work cards or the Chat timeline.

## Scheduling rules

Cache callbacks capture a monotonically increasing Thread generation. When the
Thread, cache or data source changes, the previous callbacks are cancelled and
their later deliveries are ignored. Cosmetic Chat and Work cache bursts are
coalesced through a zero-delay timer, which moves publication outside the
current cache/build notification stack. Repeated snapshots are compared before
notifying listeners.

Terminal status changes are treated as authoritative lifecycle updates. They
publish the Work and execution snapshots immediately; cosmetic history updates
remain batchable. Execution status is derived from Work history, never inferred
from activity arrival.

## Build safety

Widgets consume controller snapshots during build. Snapshot construction reads
the existing cache projection but does not mutate it or notify the cache. The
controller owns only notifier lifecycle and subscription cancellation.

## Compatibility and migration

This is an internal AX presentation change. Existing cache APIs, realtime
transport and per-assignment activity selectors remain compatible. The legacy
page-level Work history/composer counters are no longer used by `ThreadPage`;
they can be removed from follow-up code only after focused UI tests confirm
that no other page consumes them.

## Acceptance evidence

Focused tests cover duplicate cosmetic cache updates, immediate terminal
publication and stale callbacks from a previous Thread generation. Existing
activity-store selector tests cover the requirement that an activity update
notifies only the matching assignment timeline.
