# Realtime synchronization contract 1.1

Realtime events belong to the Human Product Protocol. Cloud owns persistent
collaboration state; events are small change signals for authenticated HTTP
reconciliation, not copies of entity histories. Workspace runtime transport and
provider execution are unchanged.

## Durable stream identity

The 1.1 envelope adds `stream: { kind, id }`, where kind is
`execution_workspace`, `space`, or `user`. A stream owns its monotonic sequence
and idempotency namespace independently of subscription scope. JSON tuples
`[kind, id]` identify browser/gateway cursor-map entries without separator or
cross-kind collisions.

Existing execution events continue to publish their 1.0 envelopes with the real
`workspaceId`. An absent stream infers `execution_workspace` with that ID.
Explicit execution streams must match `workspaceId`. Parsers accept both 1.0 and
1.1. Execution envelopes do not acquire a Space ID in the Workspace field.

Collaboration events publish 1.1 envelopes with an explicit Space stream and
`spaceId`; `workspaceId` is absent. The infrastructure also supports user
streams, whose identity and audience are the user ID. Space streams must match
`spaceId`. Stream identity, not the currently selected Space, governs
sequencing and synchronization.

## Collaboration signals

| Event | Envelope IDs | Payload IDs |
| --- | --- | --- |
| `space.created`, `space.updated`, `space.archived`, `space.deleted` | `spaceId` | `entityId` (Space) |
| `thread.created`, `thread.updated`, `thread.deleted` | `spaceId`, `threadId` | `entityId` (Thread), `threadId` |
| `discussion.created`, `discussion.updated` | `spaceId`, `threadId` | `entityId` (message), `threadId` |
| `space_workspace_grant.updated` | `spaceId` | `entityId` (Grant) |

These durable payloads accept identifiers only. Authored text, settings, histories,
credentials and complete entities are excluded. Archiving emits
`space.archived`; unarchiving emits `space.updated`. Grant creation, direct
editing and revocation emit `space_workspace_grant.updated`.

Space, Thread and Discussion mutation statements and their durable signal
are committed in one D1 batch. Validation precedes sequence allocation. Fanout
runs after persistence; a disconnected gateway cannot undo the committed write.
Grant routes publish after their validated existing write/audit path.

Space membership selects recipients. Deletion captures the authorized member
audience before transactional cleanup, then sends the ID-only tombstone after
commit. Current users are rechecked before WebSocket delivery. Deletion drops
invalid focused subscriptions while retaining the user scope. Live Space
signals recheck membership; grant signals additionally admit the contributing
Workspace owner. Grant owners receive the signal even without Space membership.
User streams route only to their named user's gateway.

## Browser reconciliation and reconnect

One authenticated browser socket subscribes to user scope even when there is no
execution Workspace. It sends both the legacy Workspace cursor map
`lastDurableSequences` and the new `lastDurableStreamSequences` on hello. The
legacy map remains execution-only. The gateway normalizes both maps, with the
new stream map taking precedence, and never regresses a cursor on older delivery.

Sequence gaps and queue overflow include explicit stream identity. Space gaps
carry a Space scope; execution gaps retain the legacy Workspace metadata.
There is no historical replay promise. Ready/user recovery refreshes observed
current-state queries and the Space catalog, including creations/deletions
missed while disconnected. Narrow Space gaps recover the Space entity and
its Thread list; Thread gaps recover forward Discussion cursors and
active Work Requests. Execution Workspace gaps recover Workspace state and
Worker inventory. Cached data remains visible, immutable older pages are not
refetched, and no reconnect frame loads a bootstrap AX snapshot. See
[AX server state](../architecture/AX_SERVER_STATE.md#phase-10-scoped-reconnect-recovery). Event rows/idempotency keys retain the existing 90-day
window; cursors survive retention cleanup.

AX routes Space/Thread signals to keyed caches. `discussion.created`
follows the newest known creation cursor without refetching older pages.
`discussion.updated` fetches only the changed message when it is already cached,
including messages in older pages. `GET /api/discussion-messages/:id` returns
`{ message }` after current Thread view authorization. Optimistic overlays
remain above the authoritative collection. Late responses cannot repopulate a
cleared session. Space deletion removes cached Space queries and fences
pending reads. Collaboration stream gaps do not enable execution Work polling.

Workspace Grant signals revalidate `space:<id>:workspace-grants` and the
Workspace aggregate list, without reloading the Space catalog. See the
[grant read model 1.1](WORKSPACE_SPACE_GRANTS.md) for cache and count semantics.

Custom AX data sources must implement `loadDiscussionMessage(messageId:)` for
single-message reconciliation. The browser `connect` Workspace argument is now
optional; existing calls with a Workspace ID remain valid.

## Persistence and rollout

The fresh v8 baseline now records `stream_kind`, `stream_id`, and optional real
`workspace_id`, plus optional `thread_id` on event rows. Unique indexes scope
sequences and idempotency to `(stream_kind, COALESCE(stream_id, workspace_id))`.
The fallback accepts existing execution rows with no explicit stream ID.

Existing hosted databases require the one-time
[schema alignment procedure](../deployment/CLOUDFLARE.md#durable-realtime-stream-alignment)
before deploying the stream-aware publisher. It preserves event IDs, payloads,
idempotency keys, runtime IDs, sequences and retained cursor counters. This is
not a v8 migration chain. No production schema or deployment is changed by
creating the alignment artifact.
