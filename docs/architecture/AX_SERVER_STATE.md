# AX server state — Phases 1–7

The in-memory server-state API lives in `apps/app/lib/src/ax/sync/`.
Cloud remains authoritative. Phase 1 introduced the isolated engine. Phase 2
integrated Project Workstream collections into navigation and the sidebar.
Phase 3 adds focused Project details and separates navigation from bootstrap.
Phase 4 moves paginated Discussion history and optimistic writes into shared state.
Phases 5–6 add scroll pagination and infinite Work history. Phase 7 routes Work
events into individual cached requests and uses polling only during realtime
outages. Other resource UI migrations, persistence, and cache retention limits
belong to later phases.

## Query contract

Create `AxQuery<T>` with a structural `AxQueryKey`, an existing data-source
method as its loader, and a nonnegative stale duration (default: one minute).
Use one result type and stale duration per key; incompatible definitions fail.
Key parts are immutable and compared structurally, so IDs containing colons
cannot collide. Resource-specific keys and loaders remain at the integration
boundary rather than in the transport-independent engine.

- `ensure`: `cacheFirst` returns any cached data; `cacheAndNetwork` returns
  cached data immediately and revalidates only if stale; `networkOnly` awaits
  the network. Every policy fetches if data is missing.
- `refresh`: forces a read, sharing the outstanding Future by default.
  `supersede: true` starts a newer generation explicitly.
- `invalidate`: retains data, marks an exact key (or structural prefix) stale,
  and fences outstanding reads. It does not fetch by itself.
- `peek`: returns an immutable state observation and records access time.
  `hasData` distinguishes missing data from a valid nullable result.
- `watch`: subscribes only to a query, optionally delivers its initial state,
  and returns an idempotent cancellation function. It does not fetch. No root
  notifier exists. Staleness is calculated at observation time, without timers.
- `mutate`: optionally publishes optimistic data, fences previous reads,
  commits the authoritative result, or rolls back on failure. Only the latest
  query generation may commit or roll back. Indirectly affected queries must
  be invalidated by the integration after success.
- `remove` and `clear`: reset cached state and fence late reads/mutations.
  Active subscriptions remain attached to empty entries for subsequent loads.
  Entries without subscriptions are removed. Clear on session/account changes.

Detached reads still resolve/reject for their original callers; they cannot
write into the cache. Requests are not physically canceled. Background read
errors are captured in query state, while explicit reads/mutations propagate
errors to their callers. Refresh errors preserve useful data and mark it stale.
Observers cannot corrupt a successful operation; listener exceptions are
reported to the current Dart Zone.

## Normalization and realtime

`AxEntityStore<T>` supplies typed ID-indexed tables and immutable collection ID
lists. Use separate tables for Projects, Workstreams, and other entity types.
Replacing P2's collection preserves P1's IDs and entities. Removed collection
members stay in the entity table until explicitly removed/cleared. This phase does not wire
normalization into existing screens. Future normalized-query integration must
apply entity writes only after generation validation; loaders should return
data without mutating the table, because detached responses must not write
entities. UI observations must go through the
engine's query listeners, not direct entity-table mutation notifications.

`AxRealtimeSync` accepts deduplicated affected query keys for targeted
invalidation. Actual Cloud event mapping/subscriptions and patch semantics are
left to the later realtime integration phase.

Optimistic callbacks should treat cached values as immutable. Mutations are
not server-side serialized: the engine protects local cache commits, while
Cloud still validates persistent transitions. A newer read or mutation wins;
when concurrent writes require reconciliation, invalidate and refresh after
completion. Cache storage has no browser persistence and is currently unbounded.

## Verification

`apps/app/test/ax_sync_engine_test.dart` exercises HTTP-loader integration,
cache policies, nullable values, shared Futures, timestamp boundaries,
errors/retries, generations, targeted listeners, removals/session clears,
optimistic races/rollback, and normalized collection isolation. Existing AX
HTTP, navigation, and shell tests remain regression coverage before migration.
No schema, wire protocol, dependency, or compatibility migration is required.

## Phase 2: Project/sidebar ownership

Project catalog/read-model loads and `ProjectStore` retain only Project fields,
with empty nested Workstream lists. `AxProjectWorkstreams` owns each immutable
collection under structural key `['project', projectId, 'workstreams']`.
`AxSnapshot.projects[*].workstreams` is no longer the source for sidebar rows
or selected Workstream resolution. Project-page and search inputs may compose
nested lists from the cache as view projections only.

Expanded `ProjectTree` rows use `AxQueryBuilder` subscriptions. Cold collections
show a local loading row and retry on failure. Cached rows render on the first
frame, remain visible during stale refreshes/failures, and rebuild only their
query consumer. Collapsing unsubscribes the row but retains its collection.
Selecting another expanded Project preserves expansion; clicking the focused
Project explicitly toggles it. Deep links initially expand their parent.

Both internal and browser navigation ensure the target collection rather than
reloading Projects/session/Workspaces. Project views share the same query;
opening a Workstream does not trigger a duplicate snapshot load. Project-view
collaboration loading shares the query and cannot overwrite cached collections.
Changes to a collection do not reload unrelated collaboration/Workspace data.
Workstream create/update/delete actions refresh only the owning collection.
Shell Workstream creation uses its authoritative Cloud method rather than
fabricating a local entity.
Logout/session loss clears the collection cache; archive/delete remove only
the affected Project collection. Other legacy snapshot refresh paths remain
for later migration and cannot replace cached Workstream collections.

`ax_project_cache_test.dart` provides deterministic delayed-response tests for
cross-Project navigation, immediate cached rows, stale refreshes, local retry,
subscription isolation, and collapse during a pending refresh. Existing shell
fixtures explicitly supply keyed collections rather than implicitly reading
nested Projects. There are no Cloud schema or endpoint changes; callers of
`loadReadModels` must load Workstreams through their separate resource query.

## Phase 3: Navigation versus bootstrap

`_navigateTo`, `_onBrowserNavigation`, and `_openWorkstream` apply navigation
synchronously. Both navigation paths call the same `_ensureNavigationResources`
helper after updating the route; the Workstream opener delegates exactly once.
The helper independently ensures `['project', projectId]` details and
`['project', projectId, 'workstreams']` collections through one shared
`AxSyncEngine`. It neither awaits network responses nor reloads the catalog,
session, or bootstrap state. Matching history callbacks skip already-applied
navigation. Fresh cache entries avoid HTTP; stale entries revalidate in the
background while retaining data. Query generations and resource keys fence
late writes, and a response never changes the active route.

`AxProjectDetails` delegates to the additive typed `AxDataSource.loadProject`
method for the existing `GET /projects/:id` endpoint. The HTTP loader validates
the response identity and strips nested Workstreams. Project list summaries
serve as immediate view fallbacks but never mark detail queries hydrated.
Project content subscribes to details independently of the root shell. A deep
link whose Project is absent from the catalog shows local loading/retry until
its detail query resolves, rather than rendering another Project. Successful
Project create/update responses populate the detail query and fence old reads.
Session loss/logout clear both resource kinds; archive/delete remove only the
owning Project's entries.

`loadReadModels()` keeps its current public name temporarily. Its conceptual
role is **load bootstrap state**: initial/recovery catalog, Workspaces, and
session data. Production bootstrap no longer fetches selected Project details
or Workstreams; deep links ensure those focused queries separately after
bootstrap. Its `projectId` argument remains accepted but does not select or
hydrate resources. Legacy realtime/polling snapshot refreshes remain pending
later migration. Other page-local resource loaders (collaboration, Worker
inventory, Workflow catalog, etc.) also remain for their respective phases.

`ax_project_navigation_test.dart` verifies immediate route changes, one detail
and collection request per key, matching history-event deduplication,
back/forward cache reuse, late cross-Project responses, Workstream opening
without a second bootstrap, deep-link retry, and authoritative-write fencing.
HTTP tests cover detail-only requests and malformed/mismatched response
rejection. Browser navigation is injectable for deterministic history tests;
the default browser adapter and public data-source bootstrap name are retained.
There are no Cloud endpoints, schemas, dependencies, or protocol migrations.
Custom Dart `AxDataSource` implementations must implement the new focused
`loadProject` read; all repository implementations and fixtures are updated.


## Phase 4: Shared Discussion history

`AxStore.discussion` owns `AxDiscussionCache` under structural keys
`['workstream', workstreamId, 'discussion']`. `AxDiscussionBuilder` subscribes
only to that history. Destroying a Workstream page cancels its subscription;
cached history and pending writes survive. Reopening renders cached messages
immediately and synchronizes in the background. Session loss/logout clears
history and fences late reads and writes.

The [Discussion paging contract](../specifications/DISCUSSION_PAGING.md)
provides bounded chronological pages. Synchronization catches up all pages after
the last server cursor, then reconciles the newest window, preserving previously
loaded older history. Loading older messages shares an outstanding request and
preserves the scroll position. Refresh failures retain cached messages and
expose retry locally. Existing Discussion/reconnect events request this same
scoped synchronization.

Optimistic sends and edits are per-message overlays, so independent writes do
not roll each other back. Sends publish temporary IDs immediately and replace
them with validated server responses. Edits retain references and reconcile the
server result; failures restore the previous message and use the existing error
notification. Pending temporary messages cannot be edited. The engine's
synchronous `update` operation fences old reads by default; pagination may
explicitly retain an active read because its loader merges current history
before committing. Updates preserve read timestamps rather than claiming a
fresh server read.

`ax_discussion_cache_test.dart` covers deduplication, catch-up, older pages,
concurrent writes, rollback, session clearing, scoped subscriptions, and widget
recreation during pending reads/writes. HTTP and Cloud tests verify bounded
pages, cursor validation, authorization, stable ordering, and exact Markdown.
Remote edits outside the newest page are not proactively fetched; targeted
entity patches remain a later realtime phase. Storage remains in memory and
unbounded, with no IndexedDB or database migration.


## Phase 5: Scroll pagination and incremental reconnects

Initial Discussion reads request the newest 50 messages. Scrolling upward to
within 24 pixels of the beginning loads the preceding page of 50; the explicit
load button remains available for short histories and retry. Each successful
page advances its older cursor, and requests share one outstanding Future.
Previously loaded older pages are retained and never requested again during
normal synchronization. Prepending preserves the viewport; programmatic jumps
do not trigger pagination, and late responses cannot move another Workstream's
scroll position.

Reconnect and connected events use `synchronize(reconcileNewest: false)`.
When a newest server cursor exists, only forward pages are fetched until caught
up, advancing the anchor even across multiple pages. Empty forward responses
retain the anchor. Cold reconnects fall back to initial latest-page loading.
Reopening and Discussion change events retain newest-window reconciliation for
edits, which are not represented by creation-order cursors. The opaque `before`
and `after` parameters already implement the v1 contract; no additional wire
or schema migration is introduced by Phase 5.


## Phase 6: Infinite Work history

`AxStore.workHistory` owns `['workstream', workstreamId, 'work-requests']`.
`loadWorkstreamWorkRequestPage` delegates to the existing Work Requests endpoint
with a typed `(createdAt, id)` cursor and a default limit of 50. The HTTP loader
performs exactly one request, validates the envelope/cursor and request IDs,
and returns chronological immutable results. The old list method is retained
as a bounded newest-page wrapper; it no longer walks all history. Custom Dart
data sources must implement the new page method.

Work history is no longer owned by the Workstream widget. Its scoped listener
renders cached requests immediately, retains history across disposal, and
merges recent head refreshes without dropping older pages. Scrolling near the
beginning or choosing **Load older Work history** fetches one older page and
preserves the viewport. Cursor pages have their own immutable cache entries
under the history key and are reused until explicitly invalidated. When a long
absence creates a gap before retained history, cursor frontiers let on-demand
pagination fill that gap and resume the original older frontier.

Five-second polling and matching Work events continue to request active/recently
changed data through `activeOnly`, including its continuation pages when needed;
they do not traverse immutable history. Cloud's active filter includes requests
updated in the last fifteen minutes, so completions are reconciled. Head reads,
older reads, retries, optimistic submission placeholders and authoritative
responses all merge into shared history. Accepted submissions reconcile their
cached placeholder even after page disposal, while cleared sessions reject late
local writes. Retry/cancel refreshes use active data so old requests can update
outside the newest page. Overlapping older pages preserve newer
cached status data. Cache generations fence obsolete head reads; session clear
and explicit history invalidation also fence older reads. Invalidating history
discards its pages so subsequent scrolling can reload them. Widget disposal
only unsubscribes and stops its polling timer.

`ax_work_history_test.dart` covers page deduplication, cursor frontiers, overlap,
active updates, errors/retries, invalidation, clearing, cached reopening, and
scroll anchoring. HTTP tests cover bounded requests, chronological ordering,
exact authored Markdown, parameters, and malformed responses. No Cloud endpoint,
wire schema, persistent schema, dependency, or database migration changes are
required. Storage remains in memory and unbounded. Realtime event-to-entity patch
migration and centralized polling ownership remain later phases.


## Phase 7: Realtime-first Work reconciliation

`AxWorkRealtimeSync` is shared by the session store and Workstream views through
one instance per history cache. Stream leases process shell/view delivery only
once. The shell keeps routing events into retained caches even when a Workstream
view is destroyed; visible Workstream scopes own fallback synchronization. There
is no page-owned five-second timer or event-driven history-list refresh.

| Event payload | Cache action |
| --- | --- |
| Known queued/running request or Step with sufficient status | Patch that entity, preserving its other fields |
| Complete request payload | Merge the authoritative request |
| Created request absent from cache, terminal event, missing Step, or retry of a terminal entity | Fetch `GET /work-requests/:id` and merge only that request |

Cloud currently emits IDs/statuses for these events; terminal results and Step
metadata therefore require the existing detail endpoint. Created, started,
completed, failed and cancelled Work Request events, and queued, running,
completed, failed and cancelled Step events are routed by Workstream/request ID.
Sequence/event-ID deduplication rejects duplicate and obsolete delivery.
Per-entity revisions keep late head reads and older detail responses from
replacing event state. A burst shares one pending detail request and queues at
most one newer reconciliation. Session resets fence pending reads/recovery.
Detail failures retain cached data and expose targeted retry. An HTTP failure
alone does not enable polling while the socket remains healthy.

Healthy realtime disables polling. Reconnecting, disconnected, stale, or replay-gap
states enable a fifteen-second fallback for visible scopes. Fallback reads only
active/recently changed pages and fetches cached active/failed-read entities not
present in those pages by ID. Slow requests share one recovery operation;
timer ticks do not queue more operations. After restoration, one bounded latest
page (50 requests) discovers IDs missed during an outage, and known active or
dirty requests outside that page resynchronize by ID. Recovery neither traverses
nor reloads immutable history. If discovery leaves a gap before retained pages,
the infinite query retains its on-demand cursor frontier. Successful restoration
stops the fallback timer. Leaving a view releases its scope and stops polling
when no visible scopes remain; its cached history stays available.

The browser client sends the existing Cloud `ping` every twenty seconds and
requires `realtime.pong` within ten seconds. A missing pong marks the connection
stale and reconnects. An idle Workstream with healthy pongs does not become stale.
Timers stop on socket close/reconnect and app disposal; callbacks from replaced
sockets cannot change the current transport. `realtime.ready` now reaches consumers.

Submission acknowledgements, retries and cancellation reconcile the affected
request directly. Confirmed server IDs clear local progress placeholders without
disabling Run details after reconciliation. A server event that arrives before
the create response is retained instead of being replaced by the local placeholder.

`ax_work_realtime_sync_test.dart` covers status patches, single-request reads,
complete payloads, scope isolation, duplicate/out-of-order events, bursts, late
head reads, session clearing, failed details, stream leases, health transitions,
slow recovery and reconnect discovery. `realtime_health_test.dart` verifies idle
healthy pongs, silent failures and timer cancellation. HTTP tests check detail
identity and exact authored text. No Cloud protocol/schema or database migration
is required; the client uses existing events, detail reads and ping/pong.
Browser transport behavior is verified through its extracted monitor and web
compilation, rather than a live Cloud disconnect test. Other resource realtime
handlers and the legacy shell recovery path remain outside this Work migration.
