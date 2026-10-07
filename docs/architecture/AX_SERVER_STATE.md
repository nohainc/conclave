# AX server state — Phases 1–24

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
`loadBootstrapState` must load Workstreams through their separate resource query.

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

`loadBootstrapState()` keeps its current public name temporarily. Its conceptual
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

## Phase 8: Navigation-independent cache routing

`AxRealtimeCacheRouter` receives the shared browser event envelope before shell
notification/rendering handlers. Project events revalidate registered Project
queries; Workstream events revalidate the owning Project's cached Workstream
collection. The parent can come from the envelope or be found in cached
collections. Discussion events synchronize the keyed Discussion query even when
its page has been destroyed. No selected Project is an input to this router.

Reconnect gaps revalidate cached or observed queries in the affected Project or
Workstream scope; user scope and realtime ready revalidate all hydrated Project
and Discussion queries. Cached data remains visible during refresh and failures.
Unknown resources are not fetched eagerly. Generation fencing rejects pre-event
and pre-session responses, and bounded event-ID deduplication prevents repeated
transport delivery. Work Request/Step events continue through the shared
`AxWorkRealtimeSync` single-request reconciliation path; immutable history pages
are excluded from generic reconnect revalidation.

Project catalog notifications still refresh the shell's catalog, and unmigrated
execution/workspace resources retain their existing focused refresh handlers.
The selected-Project synchronization filter and mutable last-event Project ID
are removed. Reconnect recovery for migrated queries no longer loads a snapshot
for a background Project into the selected view. No HTTP or schema changes are
introduced. Updates require server event delivery; routes which do not publish
an entity event are recovered on reconnect or explicit refresh.

## Phase 9: Collaboration synchronization signals

Cloud now emits the durable Project, Workstream, Discussion and Workspace Grant
signals in the [realtime synchronization contract 1.1](../specifications/REALTIME_SYNCHRONIZATION.md).
Collaboration has its own Project/user stream identity; `workspaceId` continues
identifying real execution Workspaces on existing execution events only.

The browser connects and subscribes to user scope without requiring execution
infrastructure. Transport cursors distinguish stream kinds even when their IDs
match. `discussion.created` follows forward pages from the shared cache's newest
cursor. `discussion.updated` loads and merges a single cached message by ID, so
remote edits to older loaded pages do not trigger full history fetches. Project
catalog recovery includes missed creation/deletion signals. Project tombstones
remove cached Project queries and reject their late reads; collaboration gaps
do not activate execution polling. Older execution envelopes and cursor maps
remain supported. Existing D1 installations require the documented one-time
stream-schema alignment; fresh databases use the updated v8 baseline.

## Phase 10: Scoped reconnect recovery

`AxSyncScope` resolves the explicit transport scope, falling back to the durable
stream identity and legacy execution `workspaceId`. A user subscription can
therefore recover one Project stream without treating it as a user-wide gap.
Malformed narrow scopes never trigger broad recovery. Navigation is not an input.

`AxSyncEngine.invalidateScope` marks affected query entries stale, fences older
reads, and retains data. Immutable Work cursor-page entries are excluded.
The cache router refreshes registered relevant queries in explicit scopes;
user-wide recovery invalidates retained resources but eagerly refreshes only
observed queries. Inactive Project queries revalidate when next ensured.
Repeated recovery frames for one scope share the pending recovery operation.

| Gap scope | Recovery |
| --- | --- |
| Project | Project details and its Workstream collection, without child Chat reads |
| Workstream | Forward Discussion pages from the newest cursor; active/recent Work discovery and known active/dirty requests by ID |
| Execution Workspace | Workspace state and Worker inventory; existing visible execution recovery remains bounded |
| User/ready | Observed migrated resources and catalog recovery; no bootstrap snapshot reload |

Discussion reconnect handling belongs to the session cache router rather than
individual Workstream widgets. Cold observed Discussions recover with one latest
page. Existing messages, optimistic overlays, expanded sidebar rows and older
history stay visible during recovery and failures. Transport stale/disconnected
states use the existing subtle reconnect status. A completed gap cannot clear a
newer connection status, and session clearing fences delayed cache writes.

Workspace HTTP APIs currently return user-wide lists. Recovery shares those
reads under Workspace-specific query keys and merges only the affected Workspace
and its Workers into the existing view projection. This does not introduce a
new endpoint or reload `loadBootstrapState`. Catalog recovery remains a focused list
read for user/ready frames; Project/Workstream gaps do not reload the catalog.
Unmigrated execution mutation events retain their existing read-model handler,
which is separate from reconnect recovery.

Router, Work realtime, Discussion widget and Workspace recovery tests cover scope
isolation, in-flight generations, shared recovery, cache preservation, immutable
pages, incremental cursors, failures and session clearing. Phase 10 introduces
no Cloud schema, protocol, dependency or compatibility migration. Live browser
WebSocket outage testing remains separate from deterministic tests and web builds.

## Phase 11: Shared Workflow catalog and Worker inventory

`AxStore.catalogs` owns `AxSessionCatalogs` on the session's existing sync engine.
The immutable `['workflow-catalog']` query has a 45-minute stale window;
`['workers']` has a 30-second stale window. Both survive Workstream disposal and
navigation, share in-flight reads, and clear with other server state on logout
or session loss. Fresh empty responses are valid cached results. There is no
IndexedDB, cache eviction timer or background polling for these queries.

The shell, Workstream pages and execution Workspace recovery all use the same
Worker query. `/workers` remains the existing user-wide HTTP read. A Workstream
projects that inventory through its own Project Workspace grants and applies
activation, readiness and catalog eligibility filters locally. The Project
grant read remains separate; grant-change signals reload the affected view's
grants without bypassing the Worker cache. A delayed grant read uses the latest
cached inventory, rather than restoring an older inventory response.

Workstream query subscriptions populate cached Workflow choices immediately and
update Worker choices when a stale background refresh or realtime invalidation
completes, including already-open settings dialogs. Page disposal unsubscribes
without evicting shared data. Shell inventory rendering observes the same query.
Explicit scopes and user/ready recovery invalidate the Worker inventory where
appropriate; reconnect does not expire the rarely-changing Workflow catalog.

`worker.inventory.*` signals revalidate only the global Worker query, independently
of the selected Project/Workspace. The legacy shell handler no longer requests
another inventory copy. `invalidateWorkflows()` is an explicit cache hook for
publication/admin integrations: observed catalog views refresh immediately,
while detached queries revalidate on the next ensure. No new Workflow publication
wire event is introduced; such a publisher can call this hook when available.

`ax_session_catalogs_test.dart` covers stale-time boundaries, retained stale data,
immutable results, in-flight sharing, observer updates, explicit invalidation,
errors, session fencing, reconnect behavior and Workstream recreation. Existing
Workspace recovery and Project/Workstream widget tests remain regression coverage.
No HTTP contract, Cloud schema, protocol or compatibility migration is required.
Standalone Workstream consumers may inject the session catalog cache; the default
source-associated fallback shares reads for consumers using the same data source.

## Phase 12: Project Workspace grant collections

`AxStore.projectWorkspaceGrants` owns structural
`['project', projectId, 'workspace-grants']` queries with a one-minute stale
window. Workstreams in one Project and the Project's Workspace settings share
this immutable collection and in-flight reads. Cached grants render immediately;
stale ensures retain them while revalidating. Worker choices combine the current
shared inventory with this Project collection, rather than each Workstream
requesting both resources. Suspended grants do not supply Worker choices.

Create, permission-edit and revoke actions use shared per-operation optimistic
overlays. All observers see those changes immediately. A failed write removes
only its own overlay, preserving concurrent writes and realtime updates. A
successful write commits its local change, invalidates the Project grant key,
and revalidates the existing HTTP collection. Confirmed writes survive read
failures, which remain in query state for retry. Temporary create IDs disable
edit/revoke controls until the authoritative collection supplies server IDs.
No mutation changes the underlying data-source HTTP signatures.

`project_workspace_grant.updated` revalidates only its Project's grant collection;
query observers update Worker choices and Project settings. Project scope gaps
include this collection. Session clearing and Project deletion fence late writes,
remove optimistic overlays and preserve other Projects' collections. A detached
view retains data without retaining its subscription.

Grant cache tests cover cold/stale read sharing, nested immutability, create/edit/
revoke reconciliation, failures, concurrent overlays, realtime during a write,
reconciliation retry, session clearing and Project tombstones. Workstream widget
coverage verifies that multiple views in a Project share one grant HTTP read.

## Phase 13: Aggregate Workspace grant counts

The Workspace list now includes `activeProjectGrantCount`, as specified by the
[Workspace Project Grants read model 1.1](../specifications/WORKSPACE_PROJECT_GRANTS.md).
Cloud aggregates counts in the same authorized D1 list statement. Counts are
distinct Projects with active, unexpired grants to non-archived Projects; they
include contributions even when the Workspace owner is not a Project member.
Only the authenticated owner's non-revoked Workspaces are returned.

AX maps that field into `AxWorkspace.projectGrantCount` and renders it directly.
The `_refreshWorkspaceProjectGrantCounts` Project loop and separate mutable
count map are removed. Bootstrap reads do not trigger count-specific Project
requests. Catalog/grant signals and shell grant writes refresh the Workspace
summary with one Workspace list read; errors retain previous counts. A grant
signal does not reload the Project catalog.

Actual-SQL Cloud tests verify status, expiration, archival, duplicates, ownership
and zero counts. A 30-Project case makes one aggregate database read; a shell
widget with 30 Projects makes zero per-Project grant reads for counting. HTTP
client tests verify the additive field and legacy/default parsing. There is no
D1 migration, new endpoint, dependency, runtime protocol or provider change.
Deploy Cloud's additive field before AX to populate full counts; older responses
remain parseable using the legacy field or zero fallback.


## Phase 14: lazy Project tabs

`AxProjectTabQueries` shares session-scoped Project resources in the sync engine.
ProjectPage observes and ensures only its selected tab: Workstreams use
`project:<id>:workstreams`; Workspaces use `project:<id>:workspace-grants`;
Members use `project:<id>:members` and `project:<id>:invitations`. Tab switches
remove listeners without removing cached data. Reopening a tab or Project shows
cached results immediately and refreshes stale results in the background.
Members/invitations use the default one-minute stale interval. Project gap
recovery recognizes these queries and the audit query alongside existing keys.

Owned Workspace inventory (`workspaces`, 30-second stale interval) is ensured
only when Connect Workspace opens. The current Project page has no visible audit
section, so it no longer fetches audit on entry. `project:<id>:audit` is available
for an explicit future consumer; membership and Workstream writes invalidate it
without fetching it. Membership writes revalidate only the affected Members or
Invitations collection. Successful Workstream mutations record their results in
the shared collection; the shell no longer refreshes it on every Project edit.
Project snapshot nested Workstreams are never a fallback authority.

Loading and errors are scoped to the selected tab. Failed refreshes preserve
cached data, with retry controls for tab reads. Session clearing fences pending
requests and removes all tab data. Existing HTTP methods and Cloud contracts are
unchanged; this phase requires no schema migration.

Widget and query tests cover request isolation, cache reuse across navigation,
stale background refresh, completion after leaving a tab, error recovery, lazy
Workspace inventory, targeted membership reconciliation, and session-clear race
protection. Live-browser interaction is not part of this automated verification.


## Phase 15: selective rendering

`AxStore` owns the bootstrap/recovery projection and observable Project and
Workspace lists. The shell retains navigation, expansion, authentication flow,
and presentation state, with read accessors for the store rather than independent
server-data copies. Worker inventory is read from the shared query; the shell
has no Worker subscription that calls root `setState`.

ProjectTree subscribes to the Project list and each expanded Project's Workstream
query. The collapsed rail's Project menu subscribes locally without fetching
unopened Workstreams. Home and Workspaces subscribe to the lists and Worker
inventory they display. Focused execution views subscribe to their retained
execution projection, which does not emit for Project/Workspace-only writes.
Search observes existing Workstream collections without eagerly loading them.
Navigation and bootstrap loading/error transitions may still rebuild the shell.
Background Project/Workspace refreshes and successful recovery update their
stores without shell rebuilds; existing HTTP APIs remain unchanged.

Within WorkstreamPage, Discussion observes its own cached query. Work history
and Workflow/Worker/grant controls have separate local listenables. Catalog,
inventory, and grant updates do not rebuild Chat or Work history. History updates
do not rebuild Chat, and Discussion updates do not rebuild Work history.
Composer alignment updates only its spacing listenable. Open Work settings still
observe choices, including realtime inventory changes. Reconnect notices,
notification badges, execution-health popovers, and account-security data have
local subscriptions instead of root server-update `setState` calls.

Session clearing removes list projections, notifications, security data, and
query caches. Delayed list/bootstrap reads are fenced across clearing/disposal;
failed refreshes retain existing data. Build-count widget tests verify update
isolation for Worker inventory, Workflow publication, Project lists, Chat, Work
history, Workspace consumers, reconnect notices, and notification counts.
Existing navigation, optimistic write, reconnect, and responsive-layout tests
remain regression coverage. No HTTP, database, or protocol migration is needed.
Live-browser profiling remains outside this automated verification.

## Phase 16: optimistic mutations

`AxMutationRunner` owns the explicit `optimisticUpdate`, `execute`, `commit`,
`rollback`, and `invalidate` lifecycle. Execution runs once; there is no retry
queue or persisted mutation replay. Optional mutation keys reject simultaneous
writes to the same entity before another optimistic change or HTTP request.
Session clearing releases leases and fences late completions.

`AxCollaborationMutations` coordinates Project and Workstream writes across shared
queries. Temporary entities appear immediately and are replaced by server IDs.
Pending temporary entities cannot be selected. Independent optimistic layers
remain visible during reads; rollback removes only its own layer and preserves
newer canonical data and unrelated writes. Discussion and Workspace grant writes
use the same lifecycle with their retained collection overlays.

Work Request creation, eligibility progress, temporary IDs, and reconciliation
now belong to `AxWorkHistoryCache`, surviving view destruction. A successful POST
is followed by a targeted read; a failed read never rolls back accepted work.
If a submission response is lost, AX retains the failed local representation and
reports that submission status is unknown. Phase 17 permits explicit retries of unchanged input with the retained operation key. Reconnect, polling, cache refresh, and navigation never repeat
the POST. Eligibility failures occur before submission.

This phase changes client state ownership only. Existing `AxDataSource` HTTP
methods and wire contracts remain intact; no database migration is required.

## Phase 17: durable mutation identities

Work Request creation, Discussion sends, and Workstream creation carry opaque
client-generated `Idempotency-Key` headers. In-memory attempt identities survive
response loss and view destruction. Sending the same unchanged input explicitly
after failure retains its key; successful completion starts a new identity for
a subsequent intentional action. Session clearing discards retained identities.
This map contains no executable callbacks, timers, offline queue, or automatic
replay. Work submission progress uses the key as its temporary row identity, so
a retry replaces the failed local row instead of duplicating it.

An explicit Work submission retry skips browser eligibility preflight, since the
original request may already be running. Cloud still authorizes every attempt
and validates any uncommitted submission; a committed receipt is recognized
before evaluating mutable Worker readiness or configuration again. Confirmed
active work in the cache still prevents another submission.

Cloud atomically commits the receipt with the domain write and returns the same
IDs for repeated attempts, including concurrent requests. Work dispatch can be
resumed explicitly with its original Run/Workflow identity; terminal work is
never restarted. See the [v1 mutation idempotency contract](../specifications/MUTATION_IDEMPOTENCY.md).

## Phase 18: optional browser read persistence

`AxPersistentReadCache` observes authoritative query values without affecting
rendering subscriptions. The web backend uses native IndexedDB through
`package:web`; other platforms have no persistence unless a backend is injected.
`AX_PERSIST_READ_CACHE=false` disables it. Storage failure or blocked startup
falls back to in-memory state; startup storage reads have a bounded timeout.

Cloud session authentication determines the Conclave user ID before hydration.
The database `conclave-ax-read-cache-v1` stores versioned safe read DTOs per user,
never the session, viewer email, tokens, account security, credentials, grants,
pending forms, mutation keys, local optimistic entities, or executable operations.
Project settings, Workstream configuration and Workflow snapshots use explicit
field allowlists; arbitrary maps are not serialized. Existing user-authored
Project/Chat/Work text is cached as product data, not interpreted as credentials.
Cached roles and Worker readiness are display hints, never authorization.

Hydration restores Projects, per-Project Workstreams, Project detail, recent Chat
and Work, Workflow catalog, Workspace summaries, and safe Worker descriptors.
All restored queries are stale. Their data renders before bootstrap completes;
active navigation queries and bootstrap revalidate in the background. Failed
reads retain cached UI. Hydration cannot overwrite a newer value or a pending
Cloud read. The authenticated user, generation, and query fences reject late
restoration after logout or an account change.

Persistence coalesces writes and saves only the most recently used 20 Workstream
histories, at most 50 confirmed messages and requests per collection. This bounds
the persisted history independently of the Phase 19 RAM retention policy. Work cursors
resume at the retained oldest request. Truncated Chat must revalidate its recent
head before enabling older pagination, preserving the opaque cursor contract.

Logout clears memory and that user's persisted data. A revision tombstone
contains no user data and prevents stale writers, including other tabs, from
repopulating the cleared cache. Schema versions/corrupt records are discarded,
not migrated into auth or server state. Storage errors are retained diagnostically
as `lastError`; persistence is optional, so an unavailable browser storage API
does not disable the app. Retry identities remain memory-only as in Phase 17.
There is no Cloud schema, HTTP, or runtime protocol change.


## Phase 19: bounded in-memory retention

`AxSyncEngine` retains the 20 most recently accessed Workstream histories by
structural Workstream ID, grouping Discussion, Work, and immutable page queries.
Query activity and subscription release schedule one coalesced retention sweep.
Eviction cancels internal bridge subscriptions and releases each cache owner's
pagination, revision, error, and reconciliation metadata. Engine removal fences
late writes. It never deletes Cloud entities or issues a network request.

Visible histories, in-flight reads, and pending optimistic mutations are protected.
The limit is temporarily soft when protected histories exceed it; completion or
subscription release schedules another sweep. Internal bridge listeners do not
pin an inactive history. Hydrated histories participate in the same limit without
requiring a screen to visit them first. Retry operation identities survive history
eviction so an ambiguous Work submission cannot become a duplicate operation.
They remain session-only and are not replayed automatically.

Each inactive retained collection keeps at most 200 recent rows by default.
Active screens may retain explicitly loaded older pages until they are released.
Work compaction releases immutable page entries and consumed-cursor bookkeeping,
retains reconciliation metadata only for surviving rows, and resumes older reads
at the retained oldest request. Discussion compaction keeps visible recent rows,
marks the head stale, and resets the opaque older cursor until head revalidation
returns a valid frontier. Revisiting an evicted history fetches one recent page;
older pages are fetched again only on demand after compaction/eviction.

Projects, Workstreams, and the Workflow catalog are outside this retention policy
and remain available for the authenticated session. Unobserved `run:*` query
entries expire after five idle minutes at the next retention sweep. The legacy
Run projection already holds only the current Run rather than a multi-Run cache.
The history count, inactive row limit, and Run duration are constructor options.
IndexedDB continues to keep its separate 20-history/50-row read snapshot; RAM
eviction can remove a history from the next persisted snapshot as well. Logout
still clears all session state.


## Phase 20: browser lifecycle synchronization

The browser navigation adapter emits lifecycle notifications only when the
Document becomes visible, plus optional online/offline connectivity notifications.
Existing non-browser navigation adapters require no connectivity implementation.
Native browser listeners and shell subscriptions are removed on disposal.

The shell retains its session check on foreground return, then asks the
session-owned `AxLifecycleSync` to revalidate active stale queries. Network
restoration requests the same targeted read synchronization. Staleness includes
each query's configured age as well as explicit invalidation. Fresh queries,
inactive histories, internal cache bridges, and immutable older cursor pages do
not trigger lifecycle reads. Visible expanded Projects, active Project tabs,
Discussion/Work heads, and subscribed shared catalogs use their existing loaders.

Lifecycle synchronization does not clear, invalidate, or replace cached data and
does not call snapshot/bootstrap APIs for a normal authenticated session. Only a
real authentication transition follows the existing bootstrap/logout paths.
Repeated notifications share one synchronization flight and existing per-query
request deduplication. A pending read that fails after network restoration can
be retried once by that restoration signal; this is read-only recovery, never a
mutation queue or Work replay. Logout/reset and disposal fence pending status
updates and deferred recovery reads.

A narrow status banner reports background refresh, offline connectivity, or
stale cached data after read failure. It is independent of the WebSocket notice,
so socket events cannot hide an offline/cache-stale warning. Cached content
remains visible throughout. Browser online status is only a connectivity hint;
HTTP failures still remain on the affected query and retain its previous value.


## Phase 21: narrow APIs and conditional stable reads

Discussion and Work Request history already use bounded cursor pages rather than
unbounded downloads. Their initial AX reads remain 50 rows and older history is
requested only on demand. The existing paging envelopes and SQL cursor contracts
are unchanged.

Project detail, Project Workstreams, and Workflow catalog now support optional
ETag conditional reads. A stale sync-engine revalidation sends the last retained
revision; unchanged authorized content returns an empty `304`, and the typed
loader reuses the transport representation as a successful fresh read. Changed
content returns the existing JSON body. Authorization, current permissions, and
resource existence are checked before a Project conditional response.

The memory-only validator cache is separately bounded and fenced by session and
request generations. Logout and account changes clear it alongside server state;
it is never persisted. Missing ETags preserve compatibility with older servers.
No schema migration or client data-source signature change is required. The
optimization saves response bytes while keeping database reads unchanged; see
[conditional reads v1](../specifications/AX_CONDITIONAL_READS.md).


## Phase 22: remove coarse snapshot polling

The shell no longer owns the five-second Run snapshot refresh timer or schedules
another bootstrap read after receiving an active/running/waiting/paused Run.
Run, Task, Attempt, Assignment, Artifact, Finding, and Verification events never
call `_loadBootstrapState()`. Events carrying `workRequestId` and `workstreamId` enter
the shared Work realtime reconciler: complete payloads patch the cached request;
otherwise one `GET /work-requests/:id` supplies authoritative details. The existing
request deduplication, event sequencing, identity validation, and late-read fences
apply. No Work history list, Project list, Workspace list, or session read is
needed for those execution signals.

Progress-only execution bursts trigger no HTTP reads. Execution frames without a
Work Request identity remain notification/progress signals. They cannot authorize a broad read or invent a legacy Run endpoint.
The current Cloud read-model bootstrap does not expose a standalone Run-detail
read; its retained legacy Run projection is not a reason to reload application
state. `_loadBootstrapState()` remains only for authenticated bootstrap, a real
authentication transition, and explicit recovery UI retry.

The only execution safety reconciliation timer is the shared fifteen-second Work
fallback. It runs while realtime is unavailable/stale and a Workstream view is
subscribed, discovers active requests in those visible scopes, and refreshes
retained active/dirty entities by ID. It does not traverse immutable old history,
poll inactive cached Workstreams, or accumulate overlapping reads. Restored
realtime performs targeted recovery and cancels the timer; releasing the last
visible scope cancels it as well. The unrelated desktop authentication approval
status timer remains part of its explicit sign-in flow.

Shell regression tests advance an active Run beyond five seconds and a full
minute without another bootstrap/Project/Workspace/session request. Execution
frames produce exactly one detail request each without broad reads. Shared
realtime tests verify no healthy-socket polling, visible-only outage fallback,
no overlapping fallback reads, and cancellation after recovery/view disposal.
No HTTP, realtime schema, database, or persistent read-cache migration is needed.

## Phase 23: remove the obsolete server-state facade

`AxStore.snapshot`, `replaceSnapshot()` and `reload()` are removed. Bootstrap is
explicitly named `loadBootstrapState()` in both the store and data-source
interface. It initializes independent Project, Workspace and session stores;
Project rows discard nested Workstreams. Navigation, reconnect and realtime
continue to use scoped queries and never use bootstrap as their routine loader.
Earlier phase notes describing retained snapshot paths are superseded here.

`AxStore.execution` is a read-only legacy Run/execution projection, updated by
`replaceExecution()`. It excludes Projects, Workspaces and viewer state, and
copies its execution collections into immutable lists. Replacing it cannot write
collaboration caches or session state. Project archive/delete writes target the
Project query directly. Search and command-palette inputs are explicit Project,
Workspace and cached per-Project Workstream collections instead of a snapshot.
Search observes cached collections without fetching every Project.

The list-shaped `loadWorkstreamWorkRequests()` and `loadDiscussionMessages()`
data-source methods are removed; production consumers use cursor page methods.
Chat/Work history, catalog, Worker inventory, grants and lazy Project tabs remain
owned by their existing shared queries. No widget-owned canonical histories or
coarse snapshot polling are reintroduced.

Custom Dart data-source adapters must rename `loadReadModels` to
`loadBootstrapState` and implement page loaders; there are no HTTP contract or
schema changes. Tests cover bootstrap separation, immutable execution state,
collaboration writes without execution notifications, cached navigation/search,
pagination, realtime recovery and the absence of snapshot polling.

## Phase 24: regression and performance acceptance coverage

Acceptance tests run against the shared engine and real Flutter consumers with
controlled data-source reads. Completers deliberately hold responses pending:
first-frame assertions prove cached rendering does not depend on Cloud completion.
Request counts measure data-source invocations, not wall-clock Cloud latency.

| Acceptance behavior | Executable coverage |
| --- | --- |
| Expand A, select B, return A: both children remain; one list read per fresh Project | `ax_project_cache_test.dart`, full shell and ProjectTree sequences |
| Stale return: A rows visible on first frame, exactly one background A read, B untouched | `ax_project_cache_test.dart`, injected cache clock and navigation ensure |
| Five callers share one Project collection read; old slow generation cannot overwrite new fast result | `ax_project_cache_test.dart`; generic engine equivalents in `ax_sync_engine_test.dart` |
| Project route changes synchronously; cached back/forward makes no detail/list/bootstrap reads | `ax_project_navigation_test.dart` |
| W1 → W2 → W1 shows previous Chat/Work while synchronization is pending | `ax_discussion_cache_test.dart`, `ax_work_history_test.dart` |
| 5,000-row Chat and Work histories load 50 initially; next 50 only on demand, no cursor traversal | `ax_discussion_cache_test.dart`, `ax_work_history_test.dart` |
| Scrolling requests older pages once, deduplicates rows, preserves viewport and does not refetch exhausted history | Widget and engine cases in both history suites |
| Non-selected expanded A receives realtime changes while selected B remains untouched | `ax_project_cache_test.dart`, `ax_realtime_cache_router_test.dart` |
| Scoped reconnect keeps both cached collections visible during the pending read | `ax_project_cache_test.dart`; router, Discussion and Workspace recovery suites |
| Execution events and a minute of active Run time cause no application bootstrap reload | `ax_snapshot_polling_test.dart` |

Measured expectations are deterministic: fresh A/B list totals are 1/1, fresh
return adds 0, stale A return adds 1, five concurrent calls add 1, initial history
responses contain 50 rows and one explicit older request brings the cache to 100.
These are cache/consumer acceptance measurements; they do not claim production
network latency or a hardware-specific frame-time benchmark. Browser execution
also exercises native IndexedDB and lifecycle recovery alongside these tests.
No runtime, schema or public API changes are required for this test phase.

### Chat read failure presentation

A failed Discussion synchronization displays the request error with a Copy Chat
error icon and an inline Retry Chat sync link. Malformed envelopes identify the invalid fields
without including message bodies. It never labels a failed read as “No chat messages yet”; that empty state
is reserved for a successful empty result. Cached messages remain visible on
failure and retry clears the error after a successful response.

Invitation and membership invalidations addressed to a non-member use a durable
recipient `user` stream in addition to the normal Project stream. Adding a user
only to Project-event fanout is insufficient: the realtime gateway correctly
rejects that stream before invitation acceptance or after membership removal.
Recipient signals contain entity IDs only, retain existing event types, and
refresh the authenticated user's invitations and Project list. Project stream
membership checks remain enforced; no Project access is granted by an invitation
notification. Offline recipients recover through their user stream or initial
invitation loading. Existing pending invitation records need no migration.

Owned Workspace inventory uses the shared `ownedWorkspacesQuery` definition for
WorkspaceStore, the Project Connect Workspace picker and persisted-cache restore.
The `workspaces`
key has a single 30-second freshness policy and immutable list result shape.
Consumers may register in either order without conflicting query definitions;
they observe the same cached data and refresh updates. No API or schema change
is required.

Sidebar Projects are grouped from the authenticated user's role: `owner` entries
appear in Your projects, and other accessible roles in Shared with you. Each
group preserves the server's ordering and existing Workstream expansion state.
Owned-only expanded sidebars omit the group heading; shared groups remain labeled
and empty groups are hidden. The collapsed rail shows separate folder and shared
folder selectors only for populated groups, each containing its own Projects and
Workstreams. Groups derive from the reactive Project list, so invitation
acceptance and refresh update both views without a separate persisted category.
No server contract or data migration is required.

Project list and detail responses include the authenticated viewer's membership
`role`. Sidebar grouping must use that server attribution, including after a
Project detail refresh, rather than inferring ownership from a missing field.

Sidebar group labels use uppercase text. Shared Project pages omit the empty
instructions section while continuing to show configured instructions. The
Members tab retains cached rows and an inline loading-failure notice without a
Retry Members button; reopening the tab retries its stale query.
